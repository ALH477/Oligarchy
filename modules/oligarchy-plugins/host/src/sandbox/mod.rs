//! Sandbox assembly.
//!
//! ORDER MATTERS and is easy to get wrong. The correct sequence inside the
//! child, after bwrap has set up the namespaces and before touching the
//! artifact:
//!
//!   1. prctl(PR_SET_NO_NEW_PRIVS)   - required by both seccomp and Landlock
//!   2. Landlock restrict_self()     - needs paths to still be openable
//!   3. seccomp apply_filter()       - last, because it may block the very
//!                                     syscalls steps 1-2 need
//!   4. dlopen / instantiate the plugin
//!
//! Doing seccomp before Landlock will make landlock_restrict_self fail with
//! EPERM under a strict filter, and the failure looks like a Landlock bug.

pub mod bwrap;
pub mod landlock;
pub mod seccomp;

use anyhow::{Context, Result};
use std::path::{Path, PathBuf};

use crate::manifest::{Manifest, Tier};

/// Everything the shim needs to confine itself. Constructed in the parent
/// (where we can still read config), passed to the child by fd/argv.
pub struct Confinement {
    pub fs: landlock::FsPolicy,
    pub bpf: seccompiler::BpfProgram,
}

pub fn prepare(m: &Manifest, state_dir: &Path, store_path: &Path) -> Result<Confinement> {
    let mut fs = landlock::FsPolicy::baseline(store_path);

    fs.allow_read_write(state_dir.join("state").join(&m.id));
    fs.allow_read(state_dir.join("config").join(&m.id));

    // The readiness socket, when there is one. The unit is Type=notify and the
    // shim reports ready *after* this ruleset is in force, so a socket missing
    // from it means the notification cannot be sent and the unit dies on
    // timeout with nothing useful in the journal. One socket, write access, and
    // only when systemd handed us a pathname one — an abstract socket cannot
    // cross the netns anyway, and bwrap::plan already refuses that case.
    if let Ok(sock) = std::env::var("NOTIFY_SOCKET") {
        if !sock.starts_with('@') {
            fs.allow_read_write(PathBuf::from(sock));
        }
    }

    for r in &m.caps.fs_read {
        fs.allow_read(m.expand(r, state_dir, store_path));
    }
    for w in &m.caps.fs_read_write {
        fs.allow_read_write(m.expand(w, state_dir, store_path));
    }

    fs.allow_all_tcp = m.caps.network && m.caps.tcp_connect.is_empty();
    fs.tcp_connect = m.caps.tcp_connect.clone();

    let bpf = seccomp::build(m).context("building seccomp policy")?;
    Ok(Confinement { fs, bpf })
}

/// Called in the child, inside the namespace. Irrevocable and ordered.
pub fn apply(c: &Confinement, m: &Manifest) -> Result<()> {
    no_new_privs().context("PR_SET_NO_NEW_PRIVS")?;

    let enforcement = landlock::restrict(&c.fs).context("applying landlock")?;
    match &enforcement {
        landlock::Enforcement::Full => {
            tracing::info!(plugin = %m.id, "landlock fully enforced");
        }
        landlock::Enforcement::Partial { net_enforced } => {
            tracing::warn!(
                plugin = %m.id,
                net_enforced,
                "landlock partially enforced: some requested access rights were \
                 dropped. Usually the kernel is older than TARGET_ABI, but a \
                 rule naming something the right cannot apply to does it too — \
                 `plugind doctor` reports the running ABI."
            );
            if !net_enforced && !m.caps.network {
                // We promised no network. The netns from --unshare-all is now
                // the only thing keeping that promise, so assert it.
                anyhow::ensure!(
                    matches!(m.tier, Tier::Native | Tier::Lua | Tier::Microvm),
                    "network denial requires landlock ABI>=4 or a netns; \
                     tier {:?} has neither",
                    m.tier
                );
            }
        }
        landlock::Enforcement::None => {
            anyhow::bail!(
                "landlock unavailable on this kernel; refusing to run plugin {} \
                 unconfined. Rebuild with a kernel >= 5.13 or route this plugin \
                 to tier=microvm.",
                m.id
            );
        }
    }

    seccomp::apply(&c.bpf).context("applying seccomp")?;

    Ok(())
}

fn no_new_privs() -> Result<()> {
    let rc = unsafe { libc::prctl(libc::PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) };
    anyhow::ensure!(rc == 0, "prctl failed: {}", std::io::Error::last_os_error());
    Ok(())
}

/// Report the whole enforcement posture for `plugind doctor`.
pub fn doctor() -> String {
    let mut out = String::new();
    out.push_str(&landlock::probe());
    out.push('\n');
    // Two knobs, because which one governs depends on the kernel.
    // `unprivileged_userns_clone` only exists on kernels carrying the Debian
    // patch (zen does); everywhere else `user.max_user_namespaces > 0` is what
    // decides whether bwrap can unshare, and tier 1 has nothing else to get its
    // namespaces from since bubblewrap dropped setuid mode.
    out.push_str(&format!(
        "unprivileged_userns_clone: {}\n",
        sysctl("kernel/unprivileged_userns_clone")
            .unwrap_or_else(|| "absent (kernel lacks the patch; see max_user_namespaces)".into())
    ));
    out.push_str(&format!(
        "max_user_namespaces: {}\n",
        sysctl("user/max_user_namespaces").unwrap_or_else(|| "unknown".into())
    ));
    out.push_str(&format!(
        "bwrap: {}\n",
        which("bwrap").unwrap_or_else(|| "MISSING".into())
    ));
    out
}

/// `plugind selftest`: what the W^X filter does on THIS kernel.
///
/// Reported per jit setting, because the whole design is that they differ.
/// Anything other than the expected column is a hard failure — a filter that
/// assembled correctly and was not honoured looks exactly like a working one
/// from inside the process that installed it.
#[cfg(target_os = "linux")]
pub fn selftest() -> Result<String> {
    use crate::manifest::{Caps, Jit, Trust};

    let synthetic = |jit: Jit, tier: Tier| Manifest {
        id: "selftest".into(),
        version: "0".into(),
        tier,
        jit,
        trust: Trust::FirstParty,
        entry: "x".into(),
        abi: crate::manifest::SUPPORTED_ABI.into(),
        caps: Caps::default(),
        meta: Default::default(),
    };

    let cases = [
        // (label, manifest, expect exec denied, expect memfd denied)
        ("native jit=none", synthetic(Jit::None, Tier::Native), true, true),
        ("native jit=self", synthetic(Jit::SelfJit, Tier::Native), false, false),
        // Tier 0 never reaches sandbox::apply — run_one loads wasm in-process
        // and only native/lua go through the shim — so this row is not testing
        // an enforcement path. It is here because the *rule* is three-way and a
        // human reading this output should see all three: the day someone
        // "hardens" tier 0 by giving it the filter, this row is what says no.
        ("wasm   jit=host", synthetic(Jit::Host, Tier::Wasm), false, false),
    ];

    let mut out = String::from("W^X selftest (forked child, filter applied, real syscalls)\n");
    let mut failures = Vec::new();
    for (label, m, want_exec, want_memfd) in cases {
        let got = seccomp::probe(&m)
            .with_context(|| format!("probing {label}"))?;
        let ok = got.exec_denied == want_exec && got.memfd_denied == want_memfd;
        out.push_str(&format!(
            "  {label}  wx_enforced={:<5} mprotect(PROT_EXEC)={:<8} memfd_create={:<8} {}\n",
            m.wx_enforced(),
            if got.exec_denied { "DENIED" } else { "allowed" },
            if got.memfd_denied { "DENIED" } else { "allowed" },
            if ok { "ok" } else { "MISMATCH" },
        ));
        if !ok {
            failures.push(label);
        }
    }
    if !failures.is_empty() {
        anyhow::bail!(
            "{out}\nW^X is NOT enforced as declared for: {}. Do not run tier 1 on \
             this kernel until this is understood — a plugin declaring jit=none \
             would get executable memory anyway.",
            failures.join(", ")
        );
    }
    out.push_str("all cases match Manifest::wx_enforced()\n");
    Ok(out)
}

fn sysctl(rel: &str) -> Option<String> {
    std::fs::read_to_string(format!("/proc/sys/{rel}"))
        .ok()
        .map(|s| s.trim().to_string())
}

fn which(bin: &str) -> Option<String> {
    std::env::var_os("PATH").and_then(|paths| {
        std::env::split_paths(&paths)
            .map(|p| p.join(bin))
            .find(|p| p.is_file())
            .map(|p| p.display().to_string())
    })
}
