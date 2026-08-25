//! Tier 2: microVM. Where untrusted code that ships its own JIT goes to be
//! harmless.
//!
//! The premise: if a plugin needs writable-executable memory *and* we have no
//! basis to trust it, no host-side mitigation is honest. seccomp W^X is
//! bypassable by construction (that's the dual-mapping escape hatch this
//! whole system relies on elsewhere), and a JIT is by definition a
//! code-generation primitive. So the W+X pages get their own kernel.
//!
//! Cost, from Firecracker's own specification: <=125 ms from InstanceStart to
//! guest /sbin/init, and <=5 MiB of VMM memory overhead for a 1 vCPU / 128 MiB
//! guest, with compute-bound guest CPU above 95% of bare metal. That is the
//! price of the tier and it is why Tier 2 is not on the audio hot path:
//! `is_realtime_safe()` returns false and the graph runs these at block rate
//! through a ring buffer, or as control-plane-only plugins.
//!
//! The guest runs the same `plugind` binary in `shim` mode with tier
//! downgraded to native, so the code path inside the VM is the one we already
//! test. Transport is vsock; framing is length-prefixed postcard, which is
//! close enough to the Canonical ABI's shapes that a future move to
//! WASI 0.3 `stream<T>` over vsock is mechanical.

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::io::{BufRead, BufReader, BufWriter, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

use crate::manifest::Manifest;
use crate::plugin::{AudioConfig, ParamInfo, Plugin, Processor};

/// Wire protocol. Deliberately tiny and versioned; anything that needs to
/// grow becomes a new variant, never a changed one.
#[derive(Debug, Serialize, Deserialize)]
enum Req {
    Hello { abi: String },
    Init,
    CreateProcessor { sample_rate: u32, block_size: u32, channels: u8 },
    Process { handle: u32, samples: Vec<f32> },
    SetParam { handle: u32, id: u32, value: f32 },
    Reset { handle: u32 },
    GetParam { handle: u32, id: u32 },
    Params,
    Command { verb: String, args: Vec<String> },
    SaveState,
    LoadState { blob: Vec<u8> },
    Shutdown,
}

#[derive(Debug, Serialize, Deserialize)]
enum Resp {
    Hello { abi: String },
    Ok,
    Handle(u32),
    Samples(Vec<f32>),
    Float(f32),
    Params(Vec<(u32, String, f32, f32, f32)>),
    Text(String),
    Blob(Vec<u8>),
    Err(String),
}

pub struct MicrovmPlugin {
    manifest: Manifest,
    vm: Child,
    conn: Conn,
    runtime_dir: PathBuf,
}

struct Conn {
    r: BufReader<UnixStream>,
    w: BufWriter<UnixStream>,
}

impl Conn {
    fn call(&mut self, req: &Req) -> Result<Resp> {
        let bytes = postcard::to_stdvec(req).context("encoding request")?;
        self.w.write_all(&(bytes.len() as u32).to_le_bytes())?;
        self.w.write_all(&bytes)?;
        self.w.flush()?;

        let mut len = [0u8; 4];
        self.r.read_exact(&mut len).context("guest closed connection")?;
        let n = u32::from_le_bytes(len) as usize;
        anyhow::ensure!(n < (16 << 20), "guest sent an absurd frame length {n}");
        let mut buf = vec![0u8; n];
        self.r.read_exact(&mut buf)?;
        let resp: Resp = postcard::from_bytes(&buf).context("decoding response")?;
        match resp {
            Resp::Err(e) => anyhow::bail!("guest error: {e}"),
            other => Ok(other),
        }
    }
}

impl MicrovmPlugin {
    /// Boot the VM and handshake. `runner` is the wrapper script that
    /// microvm.nix generated for this plugin's declarative microVM, or the
    /// imperative `microvm -r <name>` path.
    pub fn boot(m: Manifest, runner: &Path, runtime_dir: &Path) -> Result<Self> {
        let sock = runtime_dir.join(format!("{}.vsock", m.id));
        let _ = std::fs::remove_file(&sock);

        let t0 = Instant::now();
        let vm = Command::new(runner)
            .arg("--vsock")
            .arg(&sock)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .with_context(|| format!("spawning microvm runner {}", runner.display()))?;

        // Firecracker's own number is <=125ms to init; the guest then has to
        // start plugind and open the socket. 5s is generous and still catches
        // a VM that failed to boot rather than hanging the whole daemon.
        let stream = wait_for_socket(&sock, Duration::from_secs(5))
            .context("guest never opened the vsock; check `journalctl -u microvm@`")?;
        vsock_connect(&stream, GUEST_PORT).context("vsock CONNECT handshake")?;

        tracing::info!(
            plugin = %m.id,
            boot_ms = t0.elapsed().as_millis(),
            "microvm up"
        );

        let mut conn = Conn {
            r: BufReader::new(stream.try_clone()?),
            w: BufWriter::new(stream),
        };

        match conn.call(&Req::Hello {
            abi: crate::manifest::SUPPORTED_ABI.into(),
        })? {
            Resp::Hello { abi } if abi == crate::manifest::SUPPORTED_ABI => {}
            Resp::Hello { abi } => anyhow::bail!(
                "guest speaks ABI {abi}, host speaks {}",
                crate::manifest::SUPPORTED_ABI
            ),
            other => anyhow::bail!("unexpected handshake response: {other:?}"),
        }

        Ok(Self {
            manifest: m,
            vm,
            conn,
            runtime_dir: runtime_dir.to_path_buf(),
        })
    }
}

/// Port the guest's plugind listens on inside the VM.
const GUEST_PORT: u32 = 5005;

/// Firecracker and cloud-hypervisor both multiplex guest vsock ports over one
/// host unix socket, and expect a textual handshake before the stream carries
/// payload: write "CONNECT <port>\n", read back "OK <assigned>\n". Skipping
/// this is the classic way to get a connection that opens fine and then
/// silently swallows the first frame.
fn vsock_connect(stream: &UnixStream, port: u32) -> Result<()> {
    let mut w = stream.try_clone()?;
    write!(w, "CONNECT {port}\n")?;
    w.flush()?;

    let mut r = BufReader::new(stream.try_clone()?);
    let mut line = String::new();
    r.read_line(&mut line).context("reading CONNECT reply")?;
    anyhow::ensure!(
        line.starts_with("OK "),
        "vsock CONNECT refused: {:?}",
        line.trim()
    );
    Ok(())
}

fn wait_for_socket(path: &Path, timeout: Duration) -> Result<UnixStream> {
    let deadline = Instant::now() + timeout;
    loop {
        match UnixStream::connect(path) {
            Ok(s) => return Ok(s),
            Err(_) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(10)),
            Err(e) => return Err(e).context("connecting to guest vsock"),
        }
    }
}

impl Plugin for MicrovmPlugin {
    fn manifest(&self) -> &Manifest {
        &self.manifest
    }

    fn init(&mut self) -> Result<()> {
        self.conn.call(&Req::Init)?;
        Ok(())
    }

    fn create_processor(&mut self, cfg: AudioConfig) -> Result<Box<dyn Processor>> {
        let handle = match self.conn.call(&Req::CreateProcessor {
            sample_rate: cfg.sample_rate,
            block_size: cfg.block_size,
            channels: cfg.channels,
        })? {
            Resp::Handle(h) => h,
            other => anyhow::bail!("expected handle, got {other:?}"),
        };
        Ok(Box::new(MicrovmProcessor {
            handle,
            owner: self as *mut MicrovmPlugin,
        }))
    }

    fn params(&mut self) -> Result<Vec<ParamInfo>> {
        match self.conn.call(&Req::Params)? {
            Resp::Params(v) => Ok(v
                .into_iter()
                .map(|(id, name, min, max, default)| ParamInfo {
                    id,
                    name,
                    min,
                    max,
                    default,
                })
                .collect()),
            other => anyhow::bail!("expected params, got {other:?}"),
        }
    }

    fn handle_command(&mut self, verb: &str, args: &[String]) -> Result<String> {
        match self.conn.call(&Req::Command {
            verb: verb.into(),
            args: args.to_vec(),
        })? {
            Resp::Text(t) => Ok(t),
            other => anyhow::bail!("expected text, got {other:?}"),
        }
    }

    fn save_state(&mut self) -> Result<Vec<u8>> {
        match self.conn.call(&Req::SaveState)? {
            Resp::Blob(b) => Ok(b),
            other => anyhow::bail!("expected blob, got {other:?}"),
        }
    }

    fn load_state(&mut self, blob: &[u8]) -> Result<()> {
        self.conn.call(&Req::LoadState { blob: blob.to_vec() })?;
        Ok(())
    }

    fn shutdown(&mut self) {
        let _ = self.conn.call(&Req::Shutdown);
        // Give the guest a moment to halt cleanly, then take the hammer.
        // Unlike Tier 1, we do not have to be gentle: nothing in the VM is
        // ours and nothing in it persists.
        std::thread::sleep(Duration::from_millis(200));
        let _ = self.vm.kill();
        let _ = self.vm.wait();
        let _ = std::fs::remove_file(self.runtime_dir.join(format!("{}.vsock", self.manifest.id)));
    }
}

impl Drop for MicrovmPlugin {
    fn drop(&mut self) {
        let _ = self.vm.kill();
        let _ = self.vm.wait();
    }
}

struct MicrovmProcessor {
    handle: u32,
    owner: *mut MicrovmPlugin,
}

unsafe impl Send for MicrovmProcessor {}

impl Processor for MicrovmProcessor {
    fn process(&mut self, input: &[f32], output: &mut [f32]) -> Result<()> {
        let p = unsafe { &mut *self.owner };
        match p.conn.call(&Req::Process {
            handle: self.handle,
            samples: input.to_vec(),
        })? {
            Resp::Samples(s) => {
                anyhow::ensure!(s.len() == output.len(), "length mismatch from guest");
                output.copy_from_slice(&s);
                Ok(())
            }
            other => anyhow::bail!("expected samples, got {other:?}"),
        }
    }

    fn set_param(&mut self, id: u32, value: f32) {
        let p = unsafe { &mut *self.owner };
        let _ = p.conn.call(&Req::SetParam {
            handle: self.handle,
            id,
            value,
        });
    }

    fn get_param(&mut self, id: u32) -> f32 {
        let p = unsafe { &mut *self.owner };
        match p.conn.call(&Req::GetParam {
            handle: self.handle,
            id,
        }) {
            Ok(Resp::Float(f)) => f,
            _ => 0.0,
        }
    }

    fn reset(&mut self) {
        let p = unsafe { &mut *self.owner };
        let _ = p.conn.call(&Req::Reset { handle: self.handle });
    }

    /// A vsock round trip per block. Never put this in a realtime path.
    fn is_realtime_safe(&self) -> bool {
        false
    }
}
