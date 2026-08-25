//! bubblewrap invocation for Tier 1 (native / lua).
//!
//! bwrap handles the *view*: mount, pid, ipc, uts and cgroup namespaces plus a
//! minimal rootfs. Landlock handles the *rights*. They overlap deliberately —
//! bwrap can be defeated by a userns bug, Landlock can be absent on an old
//! kernel, and neither failure alone opens the box.
//!
//! Notable flags and why:
//!   --new-session      CVE-2017-5226: without it a sandboxed process can push
//!                      characters into the controlling terminal via TIOCSTI.
//!   --die-with-parent  plugind dying must not leave orphaned plugins holding
//!                      the audio device.
//!   --cap-drop ALL     belt and braces; the unit sets NoNewPrivileges too.
//!   no D-Bus socket    ever. A bus socket in a sandbox is a hole in it.
//!
//! The NOTIFY_SOCKET bind is not optional and is easy to miss: the unit is
//! Type=notify, and --unshare-all takes the net namespace with it. Pathname
//! unix sockets cross network namespaces fine, but *abstract* ones do not — so
//! if systemd hands us an abstract NOTIFY_SOCKET (a leading '@') the
//! notification can never arrive and the unit dies on timeout with a
//! completely unhelpful message. We bind the pathname socket when we get one
//! and refuse to pretend otherwise when we don't.

use anyhow::{bail, Result};
use std::ffi::OsString;
use std::path::{Path, PathBuf};

use crate::manifest::{Manifest, Tier};

pub struct BwrapPlan {
    pub bwrap: PathBuf,
    pub argv: Vec<OsString>,
    /// False when systemd gave us an abstract NOTIFY_SOCKET, which cannot
    /// cross the netns. The caller must then not wait for a readiness
    /// notification.
    pub notify_reachable: bool,
}

pub struct Paths<'a> {
    pub store_path: &'a Path,
    pub state_dir: &'a Path,
    /// policy.json. Bound read-only because the shim re-authorises inside the
    /// sandbox, and without it Policy::load falls back to the hardened
    /// defaults — which allow tier 0 only, so every tier 1 plugin would be
    /// refused by its own host with a confusing message.
    pub policy_file: &'a Path,
}

/// Small builder so we never hold two mutable borrows of the argv vector at
/// once — which the previous closure-pair version did, and which does not
/// compile.
struct Argv(Vec<OsString>);

impl Argv {
    fn new() -> Self {
        Argv(Vec::new())
    }
    fn flag(&mut self, s: &str) -> &mut Self {
        self.0.push(OsString::from(s));
        self
    }
    fn arg(&mut self, s: impl Into<OsString>) -> &mut Self {
        self.0.push(s.into());
        self
    }
    /// `--bind-ish SRC DST`
    fn bind(&mut self, flag: &str, src: &Path, dst: &str) -> &mut Self {
        self.0.push(OsString::from(flag));
        self.0.push(src.into());
        self.0.push(OsString::from(dst));
        self
    }
    /// `--bind-ish PATH PATH` (same location inside and out)
    fn bind_same(&mut self, flag: &str, path: &Path) -> &mut Self {
        self.0.push(OsString::from(flag));
        self.0.push(path.into());
        self.0.push(path.into());
        self
    }
}

pub fn plan(m: &Manifest, p: Paths<'_>, bwrap: PathBuf, plugind: &Path) -> Result<BwrapPlan> {
    if !matches!(m.tier, Tier::Native | Tier::Lua) {
        bail!("bwrap plan requested for tier {:?}", m.tier);
    }

    let mut a = Argv::new();

    a.flag("--unshare-all")
        .flag("--new-session")
        .flag("--die-with-parent")
        .flag("--cap-drop")
        .arg("ALL");

    // --unshare-all already unshares net. Only re-share if the manifest asked,
    // and even then Landlock still gates the ports.
    if m.caps.network {
        a.flag("--share-net");
    }

    a.bind_same("--ro-bind", Path::new("/nix/store"))
        .bind_same("--ro-bind", p.policy_file);

    // Bound at their REAL paths, not remapped to /state and /config.
    //
    // This is not cosmetic. The shim computes its Landlock ruleset and expands
    // `$STATE`/`$CONFIG` from the same manifest the host does, using host
    // paths — so if the sandbox showed them somewhere else, every PathFd::new
    // would fail with ENOENT and the ruleset would refuse to build. Keeping one
    // set of names means the manifest, the Landlock rules, the bind mounts and
    // anything a plugin logs all agree.
    let state = p.state_dir.join("state").join(&m.id);
    let config = p.state_dir.join("config").join(&m.id);
    a.bind_same("--bind", &state)
        .bind_same("--ro-bind-try", &config);

    a.flag("--proc").arg("/proc")
        .flag("--dev").arg("/dev")
        .flag("--tmpfs").arg("/tmp");

    // Readiness notification. See the module docs for why this is load-bearing.
    let notify_reachable = match std::env::var("NOTIFY_SOCKET") {
        Ok(s) if s.starts_with('@') => {
            tracing::warn!(
                plugin = %m.id,
                "NOTIFY_SOCKET is abstract ({s}); it cannot cross the network \
                 namespace created by --unshare-all, so readiness cannot be \
                 reported. The unit should use Type=exec for this plugin."
            );
            false
        }
        Ok(s) => {
            // --bind, not --ro-bind: connecting to a unix socket needs write
            // permission on it, and a read-only bind is the wrong side of that
            // question to be guessing about. It is one socket, in /run, that
            // systemd owns.
            a.bind_same("--bind-try", Path::new(&s));
            true
        }
        Err(_) => false,
    };

    // Devices: explicit allowlist only. --dev gives a minimal synthetic /dev
    // (null, zero, urandom, tty); anything else must be named.
    for dev in &m.caps.devices {
        let dp = Path::new(dev);
        if !dp.starts_with("/dev/") {
            bail!("device capability {:?} must be under /dev", dev);
        }
        a.bind_same("--dev-bind-try", dp);
    }

    // Manifest-declared extra reads. These are also in the Landlock ruleset:
    // bwrap makes them *visible*, Landlock makes them *permitted*.
    for r in &m.caps.fs_read {
        let path = m.expand(r, p.state_dir, p.store_path);
        a.bind_same("--ro-bind-try", &path);
    }

    // The shim gets its manifest from the store path on argv, NOT from the
    // registry: the registry is root-owned and deliberately not bound in here,
    // and a confined process has no business reading the list of every other
    // plugin on the machine. --store-path is the artifact it is already allowed
    // to see.
    a.flag("--")
        .arg(plugind)
        .flag("shim")
        .flag("--store-path")
        .arg(p.store_path)
        .arg(m.id.as_str());

    Ok(BwrapPlan {
        bwrap,
        argv: a.0,
        notify_reachable,
    })
}

/// Render for the journal and `plugind explain <id>`. Being able to paste the
/// exact sandbox invocation into a shell is worth the twenty lines.
pub fn render(plan: &BwrapPlan) -> String {
    let mut out = plan.bwrap.display().to_string();
    for arg in &plan.argv {
        out.push(' ');
        let s = arg.to_string_lossy();
        if s.starts_with("--") {
            out.push_str(&s);
        } else {
            out.push_str(&format!("{s:?}"));
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::manifest::{Caps, Jit, Trust};

    fn m(tier: Tier) -> Manifest {
        Manifest {
            id: "t".into(),
            version: "1".into(),
            tier,
            jit: Jit::None,
            trust: Trust::FirstParty,
            entry: "lib/x.so".into(),
            abi: crate::manifest::SUPPORTED_ABI.into(),
            caps: Caps::default(),
            meta: Default::default(),
        }
    }

    fn paths() -> (PathBuf, PathBuf, PathBuf) {
        (
            PathBuf::from("/nix/store/xxx-p"),
            PathBuf::from("/var/lib/oligarchy/plugins"),
            PathBuf::from("/etc/oligarchy/plugins/policy.json"),
        )
    }

    #[test]
    fn refuses_wrong_tier() {
        let (s, st, pol) = paths();
        let r = plan(
            &m(Tier::Wasm),
            Paths { store_path: &s, state_dir: &st, policy_file: &pol },
            "bwrap".into(),
            Path::new("/bin/plugind"),
        );
        assert!(r.is_err());
    }

    #[test]
    fn no_network_by_default() {
        let (s, st, pol) = paths();
        let p = plan(
            &m(Tier::Native),
            Paths { store_path: &s, state_dir: &st, policy_file: &pol },
            "bwrap".into(),
            Path::new("/bin/plugind"),
        )
        .unwrap();
        let rendered = render(&p);
        assert!(rendered.contains("--unshare-all"));
        assert!(!rendered.contains("--share-net"));
        assert!(rendered.contains("--new-session"));
    }

    #[test]
    fn state_and_policy_are_bound_at_their_real_paths() {
        // Remapping these to /state and /config is what broke tier 1: the shim
        // builds its Landlock ruleset from host paths, so they have to exist
        // under those names inside the sandbox too.
        let (s, st, pol) = paths();
        let p = plan(
            &m(Tier::Native),
            Paths { store_path: &s, state_dir: &st, policy_file: &pol },
            "bwrap".into(),
            Path::new("/bin/plugind"),
        )
        .unwrap();
        let r = render(&p);
        assert!(r.contains("/var/lib/oligarchy/plugins/state/t"), "{r}");
        assert!(!r.contains("\"/state\""), "{r}");
        assert!(r.contains("policy.json"), "{r}");
        // The store path reaches the shim, so it never opens the registry.
        assert!(r.contains("--store-path"), "{r}");
        assert!(r.contains("/nix/store/xxx-p"), "{r}");
    }

    #[test]
    fn device_must_be_under_dev() {
        let (s, st, pol) = paths();
        let mut man = m(Tier::Native);
        man.caps.devices.push("/etc/shadow".into());
        assert!(plan(
            &man,
            Paths { store_path: &s, state_dir: &st, policy_file: &pol },
            "bwrap".into(),
            Path::new("/bin/plugind"),
        )
        .is_err());
    }
}
