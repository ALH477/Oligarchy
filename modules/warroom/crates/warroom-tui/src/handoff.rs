//! Suspend the TUI, run a specialist tool on the same tty, restore.
//!
//! OWNER: work stream S4.
//!
//! The hub-not-monolith decision lives here: `dsp-ctl` and `forge-tui` already
//! do their jobs well, so the War Room launches them rather than reimplementing
//! them. That only works if returning from one leaves an intact screen — hence
//! the restore runs even when the child crashes.
//!
//! Three properties this file is responsible for, in the order they bite:
//!
//! 1. **Nothing is torn down until the child is known to be launchable.** A
//!    failed exec *after* teardown is a blank screen with no error text, and the
//!    error would be pushed to a TRAFFIC pane the operator can no longer see.
//! 2. **Teardown happens before the spawn, restore after it, unconditionally.**
//!    The restore is not `?`-chained: each step is attempted even if an earlier
//!    one failed, because "raw mode is back but we are not in the alternate
//!    screen" is a worse terminal than either failure alone.
//! 3. **The window where a signal can strand the terminal is the window where
//!    the terminal is already sane.** Between `LeaveAlternateScreen` and the
//!    child's exit this process is in cooked mode on the normal screen, so a
//!    `Ctrl-C` that reaches the whole foreground process group (a non-raw child
//!    like `git pull` leaves ISIG on) kills the War Room without leaving a
//!    wedged shell behind. That is why teardown is eager rather than lazy.
//!
//! Known limitation, deliberately not fixed here: the child is NOT put in its
//! own process group. Doing that correctly needs `tcsetpgrp` and a libc
//! dependency this crate does not carry, and doing it *incorrectly* — a new
//! group without transferring terminal ownership — makes any child that reads
//! the tty stop with SIGTTIN, which looks exactly like a hang.

use crate::app::Term;
use anyhow::{anyhow, Result};
use crossterm::execute;
use crossterm::terminal::{
    disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen,
};
use std::process::{Command, Stdio};

pub fn suspend_and_run(term: &mut Term, argv: &[String]) -> Result<()> {
    let (prog, args) = check_argv(argv)?;

    // Teardown. If either half fails we restore what we managed to undo and
    // report, rather than handing a half-suspended terminal to a child.
    if let Err(e) = disable_raw_mode() {
        let _ = restore(term);
        return Err(anyhow!("could not leave raw mode: {e}"));
    }
    if let Err(e) = execute!(term.backend_mut(), LeaveAlternateScreen) {
        let _ = restore(term);
        return Err(anyhow!("could not leave the alternate screen: {e}"));
    }
    // The TUI hides the cursor on every draw; a child that does not manage the
    // cursor itself (a plain `git pull`) would otherwise type into an invisible
    // one.
    let _ = term.show_cursor();

    // The child owns this tty completely: inherited stdin/stdout/stderr, no
    // pipes. An interactive TUI cannot be driven through a pipe, and a pipe is
    // also how a handoff silently turns into a deadlock.
    let status = Command::new(prog)
        .args(args)
        .stdin(Stdio::inherit())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit())
        .status();

    // Restore unconditionally: whatever the child did — exited non-zero, took a
    // signal, or never started — the TUI must come back. Note that `status` is
    // Ok for a child that segfaulted or was killed; only a failure to *spawn*
    // lands in the Err arm, and even that one restores first.
    let restored = restore(term);

    match status {
        Err(e) => Err(anyhow!("{prog}: {e}")),
        Ok(st) if !st.success() => {
            // Not an error for the caller to act on, but the operator should see
            // why the specialist tool bounced straight back.
            restored?;
            Err(anyhow!("{prog} exited with {}", describe(st)))
        }
        Ok(_) => restored,
    }
}

/// Everything that can refuse a handoff, in one place and before any terminal
/// state is touched. Split out so it is testable without a tty: these are the
/// checks that keep property (1) above true.
fn check_argv(argv: &[String]) -> Result<(&String, &[String])> {
    let (prog, args) = argv.split_first().ok_or_else(|| anyhow!("empty handoff argv"))?;
    if prog.is_empty() {
        return Err(anyhow!("empty handoff program name"));
    }
    // Refuse a program name that could be read as an option by anything we hand
    // it to.
    if prog.starts_with('-') {
        return Err(anyhow!("refusing handoff to {prog:?}"));
    }
    // A NUL anywhere makes `Command` fail at spawn time — i.e. after teardown.
    // Catch it while the screen is still ours.
    if argv.iter().any(|a| a.contains('\0')) {
        return Err(anyhow!("refusing handoff argv containing NUL"));
    }
    // Require the program to actually exist before tearing the UI down.
    if warroom_core::exec::which(prog).is_none() {
        return Err(anyhow!("{prog} not found on PATH"));
    }
    Ok((prog, args))
}

/// Put the terminal back the way the TUI needs it.
///
/// Every step is attempted regardless of the ones before it; the first error is
/// what gets reported. A child is free to have left raw mode enabled, so the
/// sequence starts by disabling it — `enable_raw_mode` on an already-raw
/// terminal would otherwise cache the child's termios as "the original".
fn restore(term: &mut Term) -> Result<()> {
    let mut first: Option<anyhow::Error> = None;
    let mut note = |r: std::io::Result<()>, what: &str| {
        if let Err(e) = r {
            if first.is_none() {
                first = Some(anyhow!("{what}: {e}"));
            }
        }
    };

    note(disable_raw_mode(), "reset raw mode");
    note(enable_raw_mode(), "re-enter raw mode");
    note(execute!(term.backend_mut(), EnterAlternateScreen), "re-enter alternate screen");
    note(term.hide_cursor(), "hide cursor");

    // Re-establish the viewport from the terminal's CURRENT size. This does two
    // jobs at once: it picks up a resize that happened while the child owned the
    // screen, and `resize()` clears the viewport and resets ratatui's back
    // buffer, so the next frame is a full repaint over whatever the child drew.
    //
    // NOT `Terminal::clear()`, which looks like the obvious call and is a trap:
    // in ratatui 0.30 it snapshots the cursor with `get_cursor_position()` — a
    // DSR query that WRITES to the tty and then BLOCKS reading the reply. Here
    // that read lands exactly where a just-exited child may have left unread
    // input, so it either swallows a keystroke as a cursor report or waits out
    // crossterm's timeout and fails with "the cursor position could not be read
    // within a normal duration" — a handoff that worked, reported as a failure.
    // Observed, not theorised: it is what this path did before. `resize()` on a
    // fullscreen viewport issues no query at all.
    match term.size() {
        Ok(size) => note(term.resize(size.into()), "resize"),
        Err(e) => note(Err(e), "read terminal size"),
    }

    match first {
        Some(e) => Err(e),
        None => Ok(()),
    }
}

/// Exit status in a form worth putting in the TRAFFIC pane. A signal death
/// reports no code at all, which is exactly the case worth naming.
fn describe(st: std::process::ExitStatus) -> String {
    match st.code() {
        Some(c) => format!("exit {c}"),
        None => format!("a signal ({st})"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn argv(parts: &[&str]) -> Vec<String> {
        parts.iter().map(|s| s.to_string()).collect()
    }

    /// Every refusal must happen before any terminal state is touched. A `Term`
    /// cannot be constructed without a tty, so this is also the only part of
    /// the handoff reachable from a unit test at all.
    #[test]
    fn refuses_before_teardown() {
        for bad in [
            argv(&[]),
            argv(&[""]),
            argv(&["-rf"]),
            argv(&["--version"]),
            argv(&["sh", "x\0y"]),
            argv(&["definitely-not-on-path-8f3a2b"]),
        ] {
            assert!(check_argv(&bad).is_err(), "{bad:?} would have reached teardown");
        }
    }

    /// `sh` is the one program that is on PATH everywhere this ever builds.
    #[test]
    fn accepts_a_real_program_and_keeps_its_arguments() {
        let ok = argv(&["sh", "-c", "true"]);
        let (prog, args) = check_argv(&ok).expect("sh should be on PATH");
        assert_eq!(prog, "sh");
        assert_eq!(args, ["-c", "true"]);
    }

    /// A child that dies on a signal reports no exit code, and that is exactly
    /// the case the operator needs named rather than shown as "exit -1".
    #[cfg(unix)]
    #[test]
    fn a_signal_death_is_named_as_one() {
        use std::os::unix::process::ExitStatusExt;
        // Low byte = terminating signal; 9 is SIGKILL.
        assert!(describe(std::process::ExitStatus::from_raw(9)).contains("signal"));
        // High byte = exit code.
        assert_eq!(describe(std::process::ExitStatus::from_raw(2 << 8)), "exit 2");
    }
}
