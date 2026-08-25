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
use std::path::Path;

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
                "landlock partially enforced; kernel is older than the policy"
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

    // Prove the filter took, once, in debug builds. A seccomp filter that
    // silently failed to install is the worst outcome in this whole file.
    #[cfg(debug_assertions)]
    if m.wx_enforced() {
        match seccomp::selftest_wx_denied() {
            Ok(true) => tracing::debug!(plugin = %m.id, "W^X selftest: mprotect denied, good"),
            Ok(false) => tracing::error!(
                plugin = %m.id,
                "W^X selftest FAILED: mprotect(PROT_EXEC) succeeded despite filter"
            ),
            Err(e) => tracing::warn!(plugin = %m.id, error = %e, "W^X selftest inconclusive"),
        }
    }

    Ok(())
}

fn no_new_privs() -> Result<()> {
    let rc = unsafe { libc::prctl(libc::PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) };
    anyhow::ensure!(rc == 0, "prctl failed: {}", std::io::Error::last_os_error());
    Ok(())
}

/// cgroup v2 limits. Applied by the parent to the child's unit, not by the
/// child to itself — a confined process cannot write its own cgroup limits,
/// which is the point.
pub fn cgroup_properties(m: &Manifest) -> Vec<String> {
    let mut props = Vec::new();
    if let Some(bytes) = m.caps.memory_max {
        props.push(format!("MemoryMax={bytes}"));
        props.push(format!("MemorySwapMax=0"));
    }
    if let Some(pct) = m.caps.cpu_quota {
        props.push(format!("CPUQuota={pct}%"));
    }
    props.push("TasksMax=64".into());
    props.push("IOWeight=50".into());
    props
}

/// Report the whole enforcement posture for `plugind doctor`.
pub fn doctor() -> String {
    let mut out = String::new();
    out.push_str(&landlock::probe());
    out.push('\n');
    out.push_str(&format!(
        "unprivileged_userns: {}\n",
        std::fs::read_to_string("/proc/sys/kernel/unprivileged_userns_clone")
            .map(|s| s.trim().to_string())
            .unwrap_or_else(|_| "unknown (not a Debian-patched kernel)".into())
    ));
    out.push_str(&format!(
        "bwrap: {}\n",
        which("bwrap").unwrap_or_else(|| "MISSING".into())
    ));
    out
}

fn which(bin: &str) -> Option<String> {
    std::env::var_os("PATH").and_then(|paths| {
        std::env::split_paths(&paths)
            .map(|p| p.join(bin))
            .find(|p| p.is_file())
            .map(|p| p.display().to_string())
    })
}
