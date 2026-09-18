//! Non-TUI subcommands.
//!
//! OWNER: work stream S5. Signatures frozen (main.rs dispatches into them).
//!
//! `status --json` is the forward hook: a waybar module, the greeter, or a
//! future /run/oligarchy-warroom/status.json cache all consume it without
//! touching the TUI. That is why the JSON is the `warroom_core::model::Snapshot`
//! type verbatim rather than an ad-hoc shape assembled here — the contract lives
//! in the data layer, next to the collectors that fill it.
//!
//! Everything here must TERMINATE. `collect::spawn` is the TUI's path: one
//! thread per collector, each looping on its own interval, which never returns.
//! These subcommands walk `collect::all()` once, in order, and exit.

use anyhow::Result;
use std::io::IsTerminal;
use std::time::{Instant, SystemTime, UNIX_EPOCH};
use warroom_core::actions;
use warroom_core::collect;
use warroom_core::model::{Availability, Health, Snapshot, SnapshotPanel};

/// One-shot sitrep. A drop-in for the bash `oligarchy-warroom` in scripts.
pub fn status(json: bool) -> Result<()> {
    let snap = snapshot();

    if json {
        println!("{}", serde_json::to_string_pretty(&snap)?);
        return Ok(());
    }

    let c = Colors::detect();
    let overall = Health::worst(snap.panels.iter().map(|p| p.health));

    println!(
        "{}WAR ROOM SITREP{}  {}  {}  [{}]",
        c.bold,
        c.reset,
        snap.host,
        snap.ts,
        c.paint_health(overall)
    );
    println!("{:-<72}", "");

    for p in &snap.panels {
        // The state marker is text, never color alone — a dashboard that
        // signals only in color signals nothing to half its readers.
        let marker = match p.state {
            "fresh" => "  ",
            "failed" => "! ",
            _ => "~ ",
        };
        println!(
            "{}{}{:<10}{} {:<6} {}",
            marker,
            c.bold,
            p.title,
            c.reset,
            c.paint_health(p.health),
            p.summary
        );
        for r in &p.rows {
            println!(
                "      {:<22} {:<6} {}",
                r.label,
                c.paint_health(r.health),
                r.value
            );
        }
        if let Some(t) = &p.table {
            if !t.rows.is_empty() {
                println!("      {}{}{}", c.dim, t.headers.join(" | "), c.reset);
                for row in &t.rows {
                    println!("      {}", row.join(" | "));
                }
            }
        }
    }

    Ok(())
}

/// Dump the `oligarchy-ctl` catalog.
///
/// `actions::catalog()` is another work stream's file; while it is still a stub
/// it returns an error, and propagating that unchanged is the correct behavior —
/// a hand-rolled fallback here would fork the dispatcher this tool exists to
/// drive.
pub fn actions(json: bool) -> Result<()> {
    let catalog = actions::catalog()?;

    if json {
        println!("{}", serde_json::to_string_pretty(&catalog)?);
        return Ok(());
    }

    let c = Colors::detect();
    let total: usize = catalog.cats.iter().map(|k| k.items.len()).sum();
    println!(
        "{}ORDNANCE{}  {} categories, {} actions  (via {})",
        c.bold,
        c.reset,
        catalog.cats.len(),
        total,
        actions::CTL
    );
    println!("{:-<72}", "");

    for cat in &catalog.cats {
        println!("{}{}{}  [{}]", c.bold, cat.title, c.reset, cat.id);
        for item in &cat.items {
            // Destructive is marked in the dump too: anything scripting this
            // list should be able to see the confirm-gate without re-deriving
            // it from the id.
            let flag = if actions::is_destructive(&item.id) {
                format!(" {}!DESTRUCTIVE{}", c.red, c.reset)
            } else {
                String::new()
            };
            println!("  {:<24} {}{}", item.id, item.title, flag);
        }
    }

    Ok(())
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

// ─────────────────────────────────────────────────────────────────────────────
// Collection
// ─────────────────────────────────────────────────────────────────────────────

/// One collection pass over every collector, in SITREP display order.
///
/// Sequential on purpose: each `collect()` already carries its own subprocess
/// timeout (`warroom_core::exec::run`), so the worst case is bounded without a
/// thread pool, and the output order is the same every run — which is what makes
/// the human form diffable and the JSON form stable.
fn snapshot() -> Snapshot {
    let mut panels = Vec::new();

    for mut c in collect::all() {
        let id = c.id().to_string();
        let title = c.title().to_string();

        // `state` mirrors the Freshness variants the TUI renders, minus
        // `stale`: a one-shot pass has nothing older than itself.
        let sp = match c.probe() {
            Availability::Missing(why) => SnapshotPanel {
                id,
                title,
                state: "unavailable",
                health: Health::Unknown,
                summary: why.to_string(),
                rows: Vec::new(),
                table: None,
            },
            Availability::Present => match c.collect() {
                Ok(p) => SnapshotPanel {
                    id,
                    title,
                    state: "fresh",
                    health: p.health,
                    summary: p.summary,
                    rows: p.rows,
                    table: p.table,
                },
                Err(e) => SnapshotPanel {
                    id,
                    title,
                    state: "failed",
                    health: Health::Bad,
                    summary: e.to_string(),
                    rows: Vec::new(),
                    table: None,
                },
            },
        };
        panels.push(sp);
    }

    Snapshot { ts: iso8601_utc(SystemTime::now()), host: hostname(), panels }
}

fn hostname() -> String {
    std::fs::read_to_string("/proc/sys/kernel/hostname")
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .or_else(|| std::env::var("HOSTNAME").ok())
        .unwrap_or_else(|| "unknown".to_string())
}

/// RFC3339 UTC, hand-rolled.
///
/// Deliberately no `chrono`/`time` dependency: a timestamp string is the only
/// thing that would be needed from either, and the workspace's dependency set is
/// small on purpose. Howard Hinnant's civil-from-days.
fn iso8601_utc(t: SystemTime) -> String {
    let secs = t.duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0) as i64;
    let days = secs.div_euclid(86_400);
    let tod = secs.rem_euclid(86_400);
    let (hh, mm, ss) = (tod / 3600, (tod % 3600) / 60, tod % 60);

    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };

    format!("{y:04}-{m:02}-{d:02}T{hh:02}:{mm:02}:{ss:02}Z")
}

// ─────────────────────────────────────────────────────────────────────────────
// Color
// ─────────────────────────────────────────────────────────────────────────────

/// Raw SGR escapes rather than a crate: three subcommands' worth of output does
/// not justify a dependency, and the TUI's real palette lives in
/// `warroom_core::theme`, which is not reachable from a plain pipe anyway.
struct Colors {
    bold: &'static str,
    dim: &'static str,
    red: &'static str,
    reset: &'static str,
    on: bool,
}

impl Colors {
    /// Off when piped, and off under NO_COLOR — a status line captured into a
    /// log or parsed by a script must not carry escapes.
    fn detect() -> Self {
        let on = std::io::stdout().is_terminal() && std::env::var_os("NO_COLOR").is_none();
        if on {
            Colors { bold: "\x1b[1m", dim: "\x1b[2m", red: "\x1b[31m", reset: "\x1b[0m", on }
        } else {
            Colors { bold: "", dim: "", red: "", reset: "", on }
        }
    }

    /// The health label, colored when we can. The label is always printed —
    /// color is decoration on top of text, never the signal itself.
    fn paint_health(&self, h: Health) -> String {
        let label = h.label();
        if !self.on {
            return label.to_string();
        }
        let code = match h {
            Health::Good => "32",
            Health::Warn => "33",
            Health::Bad => "31",
            Health::Unknown => "90",
        };
        format!("\x1b[{code}m{label}\x1b[0m")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn iso8601_matches_known_epochs() {
        assert_eq!(iso8601_utc(UNIX_EPOCH), "1970-01-01T00:00:00Z");
        assert_eq!(
            iso8601_utc(UNIX_EPOCH + std::time::Duration::from_secs(1_700_000_000)),
            "2023-11-14T22:13:20Z"
        );
        // A leap day, which is where a hand-rolled calendar goes wrong.
        assert_eq!(
            iso8601_utc(UNIX_EPOCH + std::time::Duration::from_secs(1_709_164_800)),
            "2024-02-29T00:00:00Z"
        );
    }

    #[test]
    fn snapshot_terminates_and_covers_every_collector() {
        let snap = snapshot();
        assert_eq!(snap.panels.len(), collect::all().len());
        assert!(!snap.ts.is_empty());
        for p in &snap.panels {
            assert!(matches!(p.state, "fresh" | "failed" | "unavailable"));
        }
    }

    #[test]
    fn snapshot_serializes_to_the_documented_shape() {
        let snap = snapshot();
        let v: serde_json::Value = serde_json::to_value(&snap).unwrap();
        assert!(v.get("ts").is_some());
        assert!(v.get("host").is_some());
        assert!(v["panels"].is_array());
        let p = &v["panels"][0];
        for key in ["id", "title", "state", "health", "summary", "rows"] {
            assert!(p.get(key).is_some(), "missing {key}");
        }
    }
}
