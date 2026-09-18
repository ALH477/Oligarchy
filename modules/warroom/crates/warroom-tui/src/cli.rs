//! Non-TUI subcommands.
//!
//! OWNER: work stream S5. Signatures frozen (main.rs dispatches into them);
//! bodies are stubs except `doctor`, which is useful immediately.
//!
//! `status --json` is the forward hook: a waybar module, the greeter, or a
//! future /run/oligarchy-warroom/status.json cache all consume it without
//! touching the TUI.

use anyhow::Result;
use std::time::Instant;
use warroom_core::collect;
use warroom_core::model::Availability;

/// One-shot sitrep. A drop-in for the bash `oligarchy-warroom` in scripts.
pub fn status(_json: bool) -> Result<()> {
    anyhow::bail!("`warroom status` not implemented (work stream S5)")
}

/// Dump the `oligarchy-ctl` catalog.
pub fn actions(_json: bool) -> Result<()> {
    anyhow::bail!("`warroom actions` not implemented (work stream S5)")
}

/// Per-collector availability, backing binary, and probe latency.
///
/// This exists because of CLAUDE.md's recorded lesson: a tool that returns
/// nothing looks like a healthy tool with nothing to say. `doctor` is how you
/// tell "this subsystem is off" from "this subsystem is broken" from "I am
/// being run without the privilege to see it".
pub fn doctor() -> Result<()> {
    println!("warroom doctor");
    println!("{:-<64}", "");
    for c in collect::all() {
        let t0 = Instant::now();
        let avail = c.probe();
        let probe_ms = t0.elapsed().as_secs_f64() * 1000.0;
        let (state, detail) = match avail {
            Availability::Present => ("PRESENT", String::new()),
            Availability::Missing(why) => ("MISSING", why.to_string()),
        };
        println!(
            "{:<10} {:<9} {:>7.1}ms  {:<8} {}",
            c.id(),
            state,
            probe_ms,
            format!("{}s", c.interval().as_secs()),
            detail
        );
    }
    Ok(())
}
