//! Subprocess runner with allowlist enforcement and timeouts.
//!
//! Every `run` call is checked against [`crate::allowlist::is_allowed`] — a
//! program not in the aspect's allowlist returns
//! [`Error::Unavailable`] without spawning anything. This is the runtime
//! backstop that complements the compile-time source-scan tests.

use std::process::Command;
use std::time::Duration;

use crate::allowlist;
use crate::audit;
use crate::error::{Error, Result};

/// Default timeout for "quick" status calls (seconds).
pub const QUICK_TIMEOUT: Duration = Duration::from_secs(20);

/// Default timeout for "heavy" calls like `nixos-rebuild dry-build`.
pub const HEAVY_TIMEOUT: Duration = Duration::from_secs(900);

/// Directories searched for allowlisted programs, in order. STRICTEST
/// posture: only the system generation's bin directory. The MCP server
/// runs as the user's session with an ambient `PATH` that includes
/// `~/.local/bin`, `~/.cargo/bin`, etc. — an attacker (or a prompt
/// injection) that writes a file to an earlier PATH directory gets
/// arbitrary execution under the aspect's identity. Pinning to the
/// system path closes that: a program not in the pinned directory is
/// refused, even if it is on `PATH`.
const PINNED_BIN_DIRS: &[&str] = &["/run/current-system/sw/bin"];

/// Runs `prog` with `args` after checking it is allowed for `aspect`.
/// Returns combined stdout+stderr as a string. Programs not on the
/// allowlist return `Error::Unavailable`; programs not in the pinned
/// system path return `Error::NotInPinnedPath`; timeouts return
/// `Error::Timeout`.
pub fn run(aspect: &str, prog: &str, args: &[&str], timeout: Duration) -> Result<String> {
    if !allowlist::is_allowed(aspect, prog) {
        // Log the rejection so capability drift is visible in the audit trail.
        audit::log(aspect, "REJECTED", &format!("disallowed CLI: {prog}"), prog);
        return Err(Error::Unavailable(format!(
            "{prog} is not on the {aspect} allowlist"
        )));
    }
    let cmd_path = match which(prog) {
        Some(p) => p,
        None => {
            audit::log(aspect, "REJECTED", &format!("not in pinned path: {prog}"), prog);
            return Err(Error::NotInPinnedPath(format!(
                "{prog} is not in the pinned system path ({})",
                PINNED_BIN_DIRS.join(", ")
            )));
        }
    };
    audit::log(aspect, "exec", &format!("{} {}", cmd_path.display(), args.join(" ")), prog);

    let mut cmd = Command::new(&cmd_path);
    cmd.args(args);
    // These CLIs run with the MCP client's environment, and a few of them
    // silently reach the network based on it: `docker inspect` follows a
    // remote DOCKER_HOST, breaking the stdio-only posture from a variable
    // nobody sees. Strip the known remoting knobs rather than scrub env
    // wholesale (tools legitimately need PATH/HOME/XDG).
    for var in [
        "DOCKER_HOST",
        "DOCKER_CONTEXT",
        "PODMAN_HOST",
        "CONTAINER_HOST",
        "KUBECONFIG",
    ] {
        cmd.env_remove(var);
    }
    let output = wait_with_timeout(cmd, prog, args, timeout)?;
    let mut combined = String::new();
    if !output.stdout.is_empty() {
        combined.push_str(&String::from_utf8_lossy(&output.stdout));
    }
    if !output.stderr.is_empty() {
        combined.push_str(&String::from_utf8_lossy(&output.stderr));
    }
    let combined = combined.trim().to_string();
    if combined.is_empty() {
        Err(Error::Exit {
            code: output.status.code().unwrap_or(-1),
            stderr: "(no output)".into(),
        })
    } else {
        Ok(combined)
    }
}

/// Pinned `which` — resolves `prog` ONLY against [`PINNED_BIN_DIRS`].
/// The resolved path is canonicalized and verified to live under
/// `/nix/store` or `/run/current-system`, so a symlink swap or a
/// store-path impostor cannot redirect execution. The ambient `PATH`
/// is deliberately NOT consulted: that is the attack surface this
/// function exists to close.
fn which(prog: &str) -> Option<std::path::PathBuf> {
    if prog.contains('/') {
        // An explicit path: canonicalize and verify it is under the
        // store or current-system. Anything else is refused.
        let p = std::path::PathBuf::from(prog);
        let canon = p.canonicalize().ok()?;
        return if is_trusted_path(&canon) { Some(canon) } else { None };
    }
    for dir in PINNED_BIN_DIRS {
        let candidate = std::path::Path::new(dir).join(prog);
        if candidate.is_file() {
            // Canonicalize to resolve the /run/current-system symlink
            // into the actual /nix/store path, then verify.
            let canon = candidate.canonicalize().ok()?;
            if is_trusted_path(&canon) {
                return Some(canon);
            }
        }
    }
    None
}

/// A resolved path is trusted if its canonical target lives under
/// `/nix/store` (immutable, content-addressed) or `/run/current-system`
/// (the current generation symlink tree). Anything else — a user-writable
/// directory, a tmpfs, a FUSE mount — is refused.
fn is_trusted_path(p: &std::path::Path) -> bool {
    p.starts_with("/nix/store") || p.starts_with("/run/current-system")
}

/// Public presence probe (does NOT enforce the allowlist). Convenient for
/// tools that want to report whether a binary is installed without trying
/// to invoke it.
pub fn which_detected(prog: &str) -> bool {
    which(prog).is_some()
}

/// Spawns `cmd`, polls with a deadline, and returns the Output. Kills the
/// child on timeout.
fn wait_with_timeout(
    mut cmd: Command,
    prog: &str,
    args: &[&str],
    timeout: Duration,
) -> Result<std::process::Output> {
    cmd.stdout(std::process::Stdio::piped());
    cmd.stderr(std::process::Stdio::piped());
    let mut child = cmd.spawn().map_err(|e| {
        Error::Io(std::io::Error::new(
            e.kind(),
            format!("spawning {prog}: {e}"),
        ))
    })?;
    let deadline = std::time::Instant::now() + timeout;
    loop {
        match child.try_wait()? {
            Some(_) => {
                let out = child.wait_with_output()?;
                return Ok(out);
            }
            None => {
                if std::time::Instant::now() >= deadline {
                    let _ = child.kill();
                    let cmd = format!("{prog} {}", args.join(" "));
                    return Err(Error::Timeout { cmd, timeout: timeout.as_secs() });
                }
                std::thread::sleep(Duration::from_millis(20));
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_disallowed_cli() {
        // `ls` is not on any allowlist.
        let res = run("system", "ls", &[], QUICK_TIMEOUT);
        assert!(matches!(res, Err(Error::Unavailable(_))));
    }

    #[test]
    fn rejects_not_in_pinned_path() {
        // `age` is on the secrets allowlist but is NOT in the pinned
        // system path on a stock system. It must be refused even if
        // it were on the ambient PATH.
        let res = run("secrets", "age", &["--version"], QUICK_TIMEOUT);
        // Either the program is genuinely absent (NotInPinnedPath) or
        // the allowlist check rejects first (Unavailable). Either way it
        // must NOT execute.
        assert!(matches!(
            res,
            Err(Error::NotInPinnedPath(_)) | Err(Error::Unavailable(_))
        ));
    }

    #[test]
    fn resolves_systemctl_from_pinned_path() {
        // `systemctl` is on the system allowlist and IS in the pinned
        // path on a NixOS system. It must resolve to a canonical path
        // under /nix/store.
        let p = which("systemctl");
        if let Some(path) = p {
            assert!(
                path.starts_with("/nix/store") || path.starts_with("/run/current-system"),
                "systemctl resolved to untrusted path: {}",
                path.display()
            );
        }
        // If the test runs on a non-NixOS host (CI), which() returns None
        // — that is acceptable; the test is a no-op there.
    }

    #[test]
    fn path_shadowing_does_not_redirect() {
        // Plant a fake `systemctl` in a temp dir and prepend it to PATH.
        // The pinned resolver must NOT pick it up — it only searches
        // PINNED_BIN_DIRS, ignoring the ambient PATH entirely.
        let tmp = tempfile::tempdir().unwrap();
        let fake = tmp.path().join("systemctl");
        std::fs::write(&fake, "#!/bin/sh\necho PWNED\n").unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mut perms = std::fs::metadata(&fake).unwrap().permissions();
            perms.set_mode(0o755);
            std::fs::set_permissions(&fake, perms).unwrap();
        }

        // Poison the ambient PATH — the resolver must ignore it.
        let old_path = std::env::var_os("PATH");
        let mut new_path = std::ffi::OsString::from(tmp.path().as_os_str());
        if let Some(ref p) = old_path {
            new_path.push(":");
            new_path.push(p);
        }
        std::env::set_var("PATH", &new_path);

        let result = which("systemctl");

        // Restore PATH so other tests are not affected.
        match old_path {
            Some(p) => std::env::set_var("PATH", p),
            None => std::env::remove_var("PATH"),
        }

        // The resolved path must NOT be the fake one.
        if let Some(path) = result {
            assert_ne!(
                path.canonicalize().unwrap(),
                fake.canonicalize().unwrap(),
                "PATH shadowing redirected resolution to a user-writable path"
            );
            assert!(
                path.starts_with("/nix/store") || path.starts_with("/run/current-system"),
                "resolved path is not under /nix/store or /run/current-system: {}",
                path.display()
            );
        }
        // None is also acceptable (systemctl not installed in the test env).
    }

    #[test]
    fn explicit_path_must_be_trusted() {
        // An explicit path outside the store (e.g. /tmp/evil) must be
        // refused even if the file exists.
        let tmp = tempfile::tempdir().unwrap();
        let evil = tmp.path().join("evil");
        std::fs::write(&evil, "#!/bin/sh\necho PWNED\n").unwrap();
        let result = which(evil.to_str().unwrap());
        assert!(result.is_none(), "untrusted explicit path was not refused");
    }
}