//! Subprocess execution with a hard timeout.
//!
//! No shell, ever: `Command::new(prog).args(args)`. A collector that hangs must
//! cost its own thread a timeout, never the UI a frame.

use anyhow::{anyhow, Result};
use std::io::Read;
use std::process::{Command, Stdio};
use std::time::Duration;
use wait_timeout::ChildExt;

/// Run `prog` with `args`, killing it after `timeout`.
///
/// Returns stdout on success. A non-zero exit returns an error carrying the
/// first line of stderr (or stdout when stderr is empty — several of the CLIs
/// here report failures on stdout).
pub fn run(prog: &str, args: &[&str], timeout: Duration) -> Result<String> {
    let mut child = Command::new(prog)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| anyhow!("{prog}: {e}"))?;

    let status = match child.wait_timeout(timeout)? {
        Some(status) => status,
        None => {
            let _ = child.kill();
            let _ = child.wait();
            return Err(anyhow!("{prog}: timed out after {:?}", timeout));
        }
    };

    let mut stdout = String::new();
    let mut stderr = String::new();
    if let Some(mut out) = child.stdout.take() {
        let _ = out.read_to_string(&mut stdout);
    }
    if let Some(mut err) = child.stderr.take() {
        let _ = err.read_to_string(&mut stderr);
    }

    if status.success() {
        return Ok(stdout);
    }

    let detail = first_line(&stderr)
        .or_else(|| first_line(&stdout))
        .unwrap_or_else(|| format!("exit {}", status.code().unwrap_or(-1)));
    Err(anyhow!("{prog}: {detail}"))
}

/// Is `prog` resolvable on PATH? Used by `Collector::probe`.
pub fn which(prog: &str) -> Option<std::path::PathBuf> {
    let path = std::env::var_os("PATH")?;
    std::env::split_paths(&path).find_map(|dir| {
        let candidate = dir.join(prog);
        candidate.is_file().then_some(candidate)
    })
}

fn first_line(s: &str) -> Option<String> {
    s.lines().map(str::trim).find(|l| !l.is_empty()).map(str::to_string)
}
