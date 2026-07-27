//! Per-aspect audit log.
//!
//! Every tool invocation appends a TSV line to
//! `~/.local/state/oligarchy-mcp/<aspect>/audit.log`. The path is
//! `OLIGARCHY_MCP_STATE_DIR/<aspect>/audit.log` if the env var is set, else
//! `$XDG_STATE_HOME/oligarchy-mcp/<aspect>/audit.log`, else
//! `~/.local/state/oligarchy-mcp/<aspect>/audit.log`.
//!
//! Rule: **auditing must never break a read-only query.** All IO errors are
//! swallowed; the logger never returns a `Result` and never panics.

use std::fs::OpenOptions;
use std::io::Write;
use std::path::PathBuf;
use time::format_description::well_known::Rfc3339;
use time::OffsetDateTime;

/// Returns the audit log path for `aspect`.
pub fn audit_path(aspect: &str) -> PathBuf {
    let base = std::env::var("OLIGARCHY_MCP_STATE_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|_| {
            let xdg = std::env::var("XDG_STATE_HOME").map(PathBuf::from).unwrap_or_else(|_| {
                let home = std::env::var("HOME").map(PathBuf::from).unwrap_or_else(|_| PathBuf::from("/tmp"));
                home.join(".local/state")
            });
            xdg.join("oligarchy-mcp")
        });
    base.join(aspect).join("audit.log")
}

/// Appends one audit line. `detail` is free-form; `cli` is the invoked
/// program path (when relevant). Never panics, never writes to stderr on
/// failure — silently drops the line if the log is unwritable.
pub fn log(aspect: &str, tool: &str, detail: &str, cli: &str) {
    let path = audit_path(aspect);
    if let Some(parent) = path.parent() {
        if std::fs::create_dir_all(parent).is_err() {
            return;
        }
    }
    let ts = OffsetDateTime::now_utc()
        .format(&Rfc3339)
        .unwrap_or_else(|_| "unknown".into());
    let uid = current_uid();
    let line = format!("{ts}\t{aspect}\t{tool}\t{detail}\t{cli}\t{uid}\n");
    if let Ok(mut fh) = OpenOptions::new().create(true).append(true).open(&path) {
        let _ = fh.write_all(line.as_bytes());
    }
}

/// Convenience: log a tool invocation with no associated CLI (e.g. for pure
/// read tools).
pub fn tool(aspect: &str, tool: &str, detail: &str) {
    log(aspect, tool, detail, "");
}

/// Returns the effective user id as a decimal string. Reads `/proc/self/status`
/// to avoid a libc dependency. Swallows errors and returns "?" — auditing
/// must never break a query.
fn current_uid() -> String {
    if let Ok(text) = std::fs::read_to_string("/proc/self/status") {
        for line in text.lines() {
            if let Some(rest) = line.strip_prefix("Uid:") {
                if let Some(eff) = rest.split_whitespace().nth(1) {
                    return eff.to_string();
                }
            }
        }
    }
    "?".into()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Mutex, MutexGuard};

    /// Both tests below drive `audit_path` by mutating OLIGARCHY_MCP_STATE_DIR,
    /// which is process-global — and cargo runs tests as threads in ONE
    /// process. Unserialized they race: the unwritable-path test can clobber
    /// the var (or clear it) in the window between the tempfile test's
    /// `set_var` and its `log()` call, so the line lands somewhere else, `log`
    /// silently swallows the failure exactly as designed, and the subsequent
    /// read blows up with NotFound.
    ///
    /// That is not hypothetical: it took down `nix build` of the system
    /// closure. It only shows up when thread scheduling cooperates, so it
    /// passed locally for a long time and failed inside the build sandbox.
    static ENV_LOCK: Mutex<()> = Mutex::new(());

    /// A panicking test would otherwise poison the lock and cascade into a
    /// second, misleading failure in the other test.
    fn lock_env() -> MutexGuard<'static, ()> {
        ENV_LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    #[test]
    fn log_never_panics_on_unwritable_path() {
        let _guard = lock_env();
        std::env::set_var("OLIGARCHY_MCP_STATE_DIR", "/proc/this/cannot/exist");
        log("system", "test_tool", "force-failure", "true");
        // No panic — passes by reaching this line.
        std::env::remove_var("OLIGARCHY_MCP_STATE_DIR");
    }

    #[test]
    fn log_writes_under_tempfile_state_dir() {
        let _guard = lock_env();
        let tmp = std::env::temp_dir().join("oligarchy-mcp-audit-test");
        let _ = std::fs::remove_dir_all(&tmp);
        std::env::set_var("OLIGARCHY_MCP_STATE_DIR", &tmp);
        log("system", "test_tool", "ok", "uname");
        let p = tmp.join("system").join("audit.log");
        let content = std::fs::read_to_string(&p).unwrap();
        assert!(content.starts_with('2')); // ISO-8601-ish year
        assert!(content.contains("\tsystem\ttest_tool\tok\tuname\t"));
        std::env::remove_var("OLIGARCHY_MCP_STATE_DIR");
        let _ = std::fs::remove_dir_all(&tmp);
    }
}