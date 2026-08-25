//! Tier 2, guest side: the half that runs *inside* the microVM.
//!
//! This did not exist. `tiers/microvm.rs` was written against a peer that was
//! never implemented — nothing in the tree bound an AF_VSOCK socket, and nothing
//! deserialised a `Req`. The host would boot a guest, wait five seconds for a
//! socket nobody was going to open, and fail. So tier 2 was a host-side proxy
//! talking to itself.
//!
//! WHY THE PLUGIN LOADS AS `native` HERE. The manifest says `tier = "microvm"`,
//! but inside the guest that would mean "boot a microVM", which is the recursion
//! it exists to avoid. The guest deliberately loads the artifact through
//! `NativePlugin` — the same code path tier 1 exercises on the host, so there is
//! no second implementation of the C vtable to keep in sync. The tier is not
//! being *downgraded*: routing to a microVM was the decision, and this is the
//! inside of it.
//!
//! WHAT CONFINES THE PLUGIN HERE. Not W^X — this is the one place a self-JIT
//! plugin is supposed to have writable-executable memory, which is the entire
//! reason tier 2 exists. The boundary is the guest kernel. In-guest hardening is
//! about containing a *buggy* plugin, not a hostile one, so the guest still
//! applies Landlock and the (permissive, for jit=self) seccomp filter: it costs
//! nothing and a hostile plugin that has not yet found a hypervisor bug is
//! confined by it too.

#[cfg_attr(feature = "native-tier", allow(unused_imports))]
use anyhow::{bail, Context, Result};
use std::io::{BufReader, BufWriter, Read, Write};
use std::os::unix::io::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::net::UnixStream;
use std::path::Path;

use crate::manifest::{Manifest, Tier};
use crate::plugin::{AudioConfig, Plugin, Processor};
use crate::policy::Policy;
use crate::tiers::microvm::{Req, Resp};

/// Must match GUEST_PORT in tiers/microvm.rs. Asserted at compile time below so
/// the two cannot drift into a five-second timeout with no explanation.
pub const GUEST_PORT: u32 = 5005;
const _: () = assert!(GUEST_PORT == crate::tiers::microvm::GUEST_PORT);

/// Serve one plugin over vsock until the host hangs up. Never returns normally.
pub fn run(store_path: &Path, id: &str, policy_path: &Path) -> Result<()> {
    let manifest = Manifest::load(&store_path.join("plugin.toml"))?;
    anyhow::ensure!(
        manifest.id == id,
        "guest asked for {id} but {} contains {}",
        store_path.display(),
        manifest.id
    );
    anyhow::ensure!(
        manifest.tier == Tier::Microvm,
        "plugin {id} is tier {:?}; only tier=microvm plugins are run in a guest",
        manifest.tier
    );

    // The guest's own policy, written declaratively by modules/guest.nix. It is
    // NOT the host's policy file: this one has to permit `native`, because that
    // is how the artifact is loaded in here. Everything else it carries —
    // min_trust, forbidden_paths, the memory and CPU ceilings — is the host's,
    // so a manifest that the host would have refused for any reason other than
    // its tier is refused here too.
    let policy = Policy::load(policy_path)?;

    // Load as native. `tiers::load` would dispatch on tier=microvm and try to
    // boot a nested VM, so this is the one place the router is bypassed —
    // explicitly, in five lines, rather than by rewriting the manifest.
    let mut as_native = manifest.clone();
    as_native.tier = Tier::Native;
    policy
        .authorize(&as_native)
        .with_context(|| format!("guest policy refused plugin {id}"))?;

    let state_dir = Path::new(crate::DEFAULT_STATE);
    let confinement = crate::sandbox::prepare(&as_native, state_dir, store_path)?;
    crate::sandbox::apply(&confinement, &as_native)?;

    #[cfg(feature = "native-tier")]
    let mut plugin: Box<dyn Plugin> = Box::new(crate::tiers::native::NativePlugin::load(
        as_native,
        store_path,
        crate::registry::config_for(state_dir, id),
    )?);
    #[cfg(not(feature = "native-tier"))]
    {
        let _ = as_native;
        bail!(
            "this plugind was built without the native tier, so it cannot host a \
             tier 2 guest — the guest loads the artifact through NativePlugin"
        );
    }

    #[cfg(feature = "native-tier")]
    {
        let listener = listen(GUEST_PORT)?;
        tracing::info!(plugin = %id, port = GUEST_PORT, "guest listening on vsock");

        // One connection at a time, and one connection is all there ever is: the
        // host holds it for the plugin's whole life. Looping rather than serving
        // once means a host that reconnects after a restart finds us still here
        // instead of a dead VM.
        loop {
            let stream = accept(&listener).context("accepting a vsock connection")?;
            tracing::info!(plugin = %id, "host connected");
            if let Err(e) = serve(stream, plugin.as_mut()) {
                tracing::warn!(plugin = %id, error = %format!("{e:#}"), "host session ended");
            }
        }
    }
}

// ── vsock ─────────────────────────────────────────────────────────────────

fn listen(port: u32) -> Result<OwnedFd> {
    use nix::sys::socket::{bind, listen as sys_listen, socket, Backlog};
    use nix::sys::socket::{AddressFamily, SockFlag, SockType, VsockAddr};

    let fd = socket(
        AddressFamily::Vsock,
        SockType::Stream,
        SockFlag::empty(),
        None,
    )
    .context("socket(AF_VSOCK) — is the guest kernel built with vsock?")?;
    // VMADDR_CID_ANY: the guest does not know or care what cid the host gave it,
    // and hardcoding one would break the moment two plugins run at once.
    bind(fd.as_raw_fd(), &VsockAddr::new(libc::VMADDR_CID_ANY, port))
        .with_context(|| format!("bind(vsock:{port})"))?;
    sys_listen(&fd, Backlog::new(1).unwrap()).context("listen(vsock)")?;
    Ok(fd)
}

fn accept(listener: &OwnedFd) -> Result<UnixStream> {
    let fd = nix::sys::socket::accept(listener.as_raw_fd()).context("accept(vsock)")?;
    // A UnixStream over an AF_VSOCK fd. Deliberate, and safe: UnixStream is a
    // thin wrapper over a stream socket and we only ever read, write and close.
    // The alternative is a vsock crate for two syscalls, or hand-rolling Read
    // and Write so BufReader can be used at all.
    //
    // SAFETY: `fd` is a fresh, owned, connected SOCK_STREAM descriptor from
    // accept(2), and ownership moves into the UnixStream.
    Ok(unsafe { UnixStream::from_raw_fd(fd) })
}

// ── the protocol ──────────────────────────────────────────────────────────

fn serve(stream: UnixStream, plugin: &mut dyn Plugin) -> Result<()> {
    let mut r = BufReader::new(stream.try_clone()?);
    let mut w = BufWriter::new(stream);

    // Handles are indices into this. The host is the only client and asks for at
    // most one processor, but numbering them means a stale handle after a
    // reconnect is an error rather than a silent wrong answer.
    let mut processors: Vec<Box<dyn Processor>> = Vec::new();

    loop {
        let req = match read_frame(&mut r)? {
            Some(req) => req,
            // Clean EOF: the host went away. Not an error.
            None => return Ok(()),
        };
        let resp = dispatch(req, plugin, &mut processors);
        write_frame(&mut w, &resp)?;
    }
}

fn dispatch(req: Req, plugin: &mut dyn Plugin, processors: &mut Vec<Box<dyn Processor>>) -> Resp {
    // Every arm returns a Resp, including for failure: a guest that dropped the
    // connection on a bad request would look to the host exactly like a VM that
    // crashed, and the difference matters when you are reading a journal.
    let handle = |processors: &mut Vec<Box<dyn Processor>>, h: u32| -> Result<usize> {
        let i = h as usize;
        anyhow::ensure!(i < processors.len(), "no processor with handle {h}");
        Ok(i)
    };

    let result: Result<Resp> = (|| match req {
        Req::Hello { abi } => {
            anyhow::ensure!(
                abi == crate::manifest::SUPPORTED_ABI,
                "host speaks ABI {abi}, guest speaks {}",
                crate::manifest::SUPPORTED_ABI
            );
            Ok(Resp::Hello {
                abi: crate::manifest::SUPPORTED_ABI.into(),
            })
        }
        Req::Init => {
            plugin.init()?;
            Ok(Resp::Ok)
        }
        Req::CreateProcessor {
            sample_rate,
            block_size,
            channels,
        } => {
            let p = plugin.create_processor(AudioConfig {
                sample_rate,
                block_size,
                channels,
            })?;
            processors.push(p);
            Ok(Resp::Handle((processors.len() - 1) as u32))
        }
        Req::Process { handle: h, samples } => {
            let i = handle(processors, h)?;
            let mut out = vec![0.0f32; samples.len()];
            processors[i].process(&samples, &mut out)?;
            Ok(Resp::Samples(out))
        }
        Req::SetParam { handle: h, id, value } => {
            let i = handle(processors, h)?;
            processors[i].set_param(id, value);
            Ok(Resp::Ok)
        }
        Req::GetParam { handle: h, id } => {
            let i = handle(processors, h)?;
            Ok(Resp::Float(processors[i].get_param(id)))
        }
        Req::Reset { handle: h } => {
            let i = handle(processors, h)?;
            processors[i].reset();
            Ok(Resp::Ok)
        }
        Req::Params => Ok(Resp::Params(
            plugin
                .params()?
                .into_iter()
                .map(|p| (p.id, p.name, p.min, p.max, p.default))
                .collect(),
        )),
        Req::Command { verb, args } => Ok(Resp::Text(plugin.handle_command(&verb, &args)?)),
        Req::SaveState => Ok(Resp::Blob(plugin.save_state()?)),
        Req::LoadState { blob } => {
            plugin.load_state(&blob)?;
            Ok(Resp::Ok)
        }
        Req::Shutdown => {
            plugin.shutdown();
            Ok(Resp::Ok)
        }
    })();

    result.unwrap_or_else(|e| Resp::Err(format!("{e:#}")))
}

/// Read one length-prefixed postcard frame. `None` on clean EOF.
fn read_frame(r: &mut impl Read) -> Result<Option<Req>> {
    let mut len = [0u8; 4];
    match r.read_exact(&mut len) {
        Ok(()) => {}
        Err(e) if e.kind() == std::io::ErrorKind::UnexpectedEof => return Ok(None),
        Err(e) => return Err(e).context("reading frame length"),
    }
    let n = u32::from_le_bytes(len) as usize;
    // Same ceiling as the host applies to us. The host is the only peer, but a
    // length field is a length field.
    anyhow::ensure!(n < (16 << 20), "host sent an absurd frame length {n}");
    let mut buf = vec![0u8; n];
    r.read_exact(&mut buf).context("reading frame body")?;
    Ok(Some(
        postcard::from_bytes(&buf).context("decoding request")?,
    ))
}

fn write_frame(w: &mut impl Write, resp: &Resp) -> Result<()> {
    let bytes = postcard::to_stdvec(resp).context("encoding response")?;
    w.write_all(&(bytes.len() as u32).to_le_bytes())?;
    w.write_all(&bytes)?;
    w.flush()?;
    Ok(())
}
