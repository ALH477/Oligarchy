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

/// Runs `prog` with `args` after checking it is allowed for `aspect`.
/// Returns combined stdout+stderr as a string. Programs not on PATH return
/// `Error::Unavailable`; timeouts return `Error::Timeout`.
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
        None => return Err(Error::Unavailable(prog.to_string())),
    };
    audit::log(aspect, "exec", &args.join(" "), prog);

    let mut cmd = Command::new(&cmd_path);
    cmd.args(args);
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

/// Tiny `which` — uses `PATH` lookups via `std::env::split_paths`.
fn which(prog: &str) -> Option<std::path::PathBuf> {
    if prog.contains('/') {
        return Some(std::path::PathBuf::from(prog));
    }
    let path = std::env::var_os("PATH")?;
    for dir in std::env::split_paths(&path) {
        let candidate = dir.join(prog);
        if candidate.is_file() {
            return Some(candidate);
        }
    }
    None
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
}