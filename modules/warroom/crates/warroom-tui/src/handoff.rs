//! Suspend the TUI, run a specialist tool on the same tty, restore.
//!
//! OWNER: work stream S4. This body is real (it is small and everything else
//! depends on it not corrupting the terminal); S4 hardens it.
//!
//! The hub-not-monolith decision lives here: `dsp-ctl` and `forge-tui` already
//! do their jobs well, so the War Room launches them rather than reimplementing
//! them. That only works if returning from one leaves an intact screen — hence
//! the restore runs even when the child crashes.

use anyhow::{anyhow, Result};
use crossterm::execute;
use crossterm::terminal::{
    disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen,
};
use crate::app::Term;
use std::process::Command;

pub fn suspend_and_run(term: &mut Term, argv: &[String]) -> Result<()> {
    let (prog, args) = argv.split_first().ok_or_else(|| anyhow!("empty handoff argv"))?;

    // Refuse a program name that could be read as an option by anything we
    // hand it to, and require it to actually exist before tearing the UI down —
    // a failed exec after teardown is a blank screen with no explanation.
    if prog.starts_with('-') {
        return Err(anyhow!("refusing handoff to {prog:?}"));
    }
    if warroom_core::exec::which(prog).is_none() {
        return Err(anyhow!("{prog} not found on PATH"));
    }

    disable_raw_mode()?;
    execute!(term.backend_mut(), LeaveAlternateScreen)?;

    let status = Command::new(prog).args(args).status();

    // Restore unconditionally: whatever the child did, the TUI must come back.
    let restore = (|| -> Result<()> {
        enable_raw_mode()?;
        execute!(term.backend_mut(), EnterAlternateScreen)?;
        term.clear()?;
        Ok(())
    })();

    status.map_err(|e| anyhow!("{prog}: {e}"))?;
    restore
}
