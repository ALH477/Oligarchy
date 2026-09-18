//! DSP collector — `dsp-ctl status`
//!
//! OWNER: work stream S1.
//!
//! `dsp-ctl status` has **no JSON mode**. `modules/dsp-ctl/src/main.rs` declares
//! a bare `Status` subcommand with no flags, and `cli::print_status_table`
//! renders a box-drawing table with `println!`. So this is a scraper, and it is
//! written to be tolerant of the two things most likely to change about that
//! table: the column padding (which is already visibly inconsistent upstream —
//! several rows overflow their own border) and the addition of new rows.
//!
//! The parse therefore keys off `label: value` inside the box frame and ignores
//! any row it does not recognise, rather than matching positions.

use crate::model::{Availability, Health, Panel};
use std::collections::BTreeMap;
use std::time::Duration;

const TIMEOUT: Duration = Duration::from_millis(1500);

pub struct DspCollector {
    _priv: (),
}

impl DspCollector {
    pub fn new() -> Self {
        DspCollector { _priv: () }
    }
}

impl Default for DspCollector {
    fn default() -> Self {
        Self::new()
    }
}

/// Strip the box frame and split each content line into `label` -> `value`.
///
/// Splitting on the *first* colon would break `VFIO c7:00.3:` (a PCI address in
/// the label); splitting on the last would break any value that ever grows a
/// colon. So: split at the first colon that is followed by whitespace or end of
/// line, which is how the table actually delimits its columns.
fn parse_status(out: &str) -> BTreeMap<String, String> {
    let mut map = BTreeMap::new();
    for line in out.lines() {
        // Drop the frame characters; `trim_matches` handles both the leading
        // and trailing `║` and the pure-rule lines (which become empty).
        let inner = line.trim().trim_matches(|c| c == '║' || c == '╔' || c == '╗' || c == '╠' || c == '╣' || c == '╚' || c == '╝');
        let inner = inner.trim();
        if inner.is_empty() || inner.chars().all(|c| c == '═' || c == '─') {
            continue;
        }
        let Some((label, value)) = split_label(inner) else {
            continue;
        };
        if label.is_empty() || value.is_empty() {
            continue;
        }
        map.insert(label.to_ascii_lowercase(), value.to_string());
    }
    map
}

fn split_label(s: &str) -> Option<(&str, &str)> {
    let bytes = s.as_bytes();
    for (i, b) in bytes.iter().enumerate() {
        if *b != b':' {
            continue;
        }
        let next = bytes.get(i + 1);
        match next {
            None => return Some((s[..i].trim(), "")),
            Some(c) if c.is_ascii_whitespace() => {
                return Some((s[..i].trim(), s[i + 1..].trim()))
            }
            _ => continue,
        }
    }
    None
}

/// `● ACTIVE` / `○ INACTIVE` / `● RUNNING` / `○ STOPPED`.
///
/// Keyed off the word, not the bullet: the bullet is a rendering choice and
/// could be dropped for a no-unicode terminal without changing the meaning.
/// An unrecognised word is `None`, never "not active".
fn state_is_up(value: &str) -> Option<bool> {
    let v = value.to_ascii_uppercase();
    if v.contains("ACTIVE") && !v.contains("INACTIVE") {
        Some(true)
    } else if v.contains("INACTIVE") {
        Some(false)
    } else if v.contains("RUNNING") {
        Some(true)
    } else if v.contains("STOPPED") {
        Some(false)
    } else if v.contains("BOUND") {
        Some(true)
    } else if v.contains("HOST") {
        Some(false)
    } else {
        None
    }
}

/// First run of digits (with an optional decimal point) in a string.
/// `"   32 samples (0.33ms period)"` -> `32`.
fn leading_number(value: &str) -> Option<f64> {
    let mut seen = String::new();
    for c in value.chars() {
        if c.is_ascii_digit() || (c == '.' && !seen.is_empty() && !seen.contains('.')) {
            seen.push(c);
        } else if !seen.is_empty() {
            break;
        }
    }
    seen.parse().ok()
}

fn xrun_health(n: f64) -> Health {
    if n == 0.0 {
        Health::Good
    } else if n < 10.0 {
        Health::Warn
    } else {
        Health::Bad
    }
}

impl super::Collector for DspCollector {
    fn id(&self) -> &'static str {
        "dsp"
    }

    fn title(&self) -> &'static str {
        "DSP"
    }

    fn interval(&self) -> Duration {
        Duration::from_secs(2)
    }

    fn probe(&self) -> Availability {
        match crate::exec::which("dsp-ctl") {
            Some(_) => Availability::Present,
            None => Availability::Missing("dsp-ctl not installed — enable custom.dsp"),
        }
    }

    fn collect(&mut self) -> anyhow::Result<Panel> {
        let out = crate::exec::run("dsp-ctl", &["status"], TIMEOUT)?;
        let map = parse_status(&out);

        // An empty parse is the unprivileged-silence failure mode this repo
        // keeps relearning: exit 0, nothing on stdout, and a pane that looks
        // like a healthy subsystem with nothing to say. It is an error.
        if map.is_empty() {
            anyhow::bail!("dsp-ctl status produced no parseable rows");
        }

        let mut panel = Panel::new(Health::Unknown, String::new());
        let mut judged: Vec<Health> = Vec::new();

        // The four lifecycle states. `None` (unparseable) is Unknown, never
        // "down" — a scraper that silently invents a state is worse than one
        // that admits it did not understand the line.
        let mut up_count = 0usize;
        let mut known_count = 0usize;
        for (key, label) in [
            ("dsp vm", "vm"),
            ("netjack", "netjack"),
            ("demod-rt", "demod-rt"),
            ("jack", "jack"),
        ] {
            match map.get(key).map(String::as_str).and_then(state_is_up) {
                Some(true) => {
                    known_count += 1;
                    up_count += 1;
                    panel = panel.row(label, "active", Health::Good);
                }
                Some(false) => {
                    known_count += 1;
                    // Health decided below, once we know whether the *whole*
                    // stack is down (a normal idle laptop) or only part of it
                    // (genuinely inconsistent).
                    panel = panel.row(label, "inactive", Health::Unknown);
                }
                None => panel = panel.row(label, "--", Health::Unknown),
            }
        }

        // A fully-down DSP stack is a legitimate, extremely common state on a
        // laptop that is not currently playing guitar. Flagging it Warn would
        // paint the SITREP card yellow forever and teach the operator to
        // ignore the colour. Partially-up is the state that deserves a warning.
        let stack_health = if known_count == 0 {
            Health::Unknown
        } else if up_count == 0 {
            Health::Unknown // offline, not unhealthy
        } else if up_count == known_count {
            Health::Good
        } else {
            Health::Warn
        };
        if up_count > 0 && up_count < known_count {
            for row in panel.rows.iter_mut() {
                if row.value == "inactive" {
                    row.health = Health::Warn;
                }
            }
        }
        judged.push(stack_health);

        if let Some(v) = map.get("sample rate") {
            panel = panel.plain("sample rate", v.clone());
        }
        if let Some(v) = map.get("buffer size") {
            panel = panel.plain("buffer", v.clone());
        }

        match map.get("xruns").and_then(|v| leading_number(v)) {
            Some(n) => {
                let h = xrun_health(n);
                judged.push(h);
                panel = panel.row("xruns", format!("{n:.0}"), h);
            }
            None => panel = panel.row("xruns", "--", Health::Unknown),
        }

        if let Some(v) = map.get("cpu load") {
            panel = panel.plain("dsp cpu load", v.clone());
        }
        if let Some(v) = map.get("cpu isolated") {
            panel = panel.plain("isolcpus", v.clone());
        }
        if let Some(v) = map.get("hugepages") {
            panel = panel.plain("hugepages", v.clone());
        }

        // "VFIO c7:00.3" — the label carries the PCI address and is allowed to
        // change with the hardware, so find it by prefix.
        if let Some((k, v)) = map.iter().find(|(k, _)| k.starts_with("vfio")) {
            let value = match state_is_up(v) {
                Some(true) => "bound".to_string(),
                Some(false) => "host".to_string(),
                None => v.clone(),
            };
            panel = panel.plain(k.clone(), value);
        }

        let latency = map.get("latency").cloned();
        if let Some(l) = &latency {
            panel = panel.plain("latency", l.clone());
        }
        if let Some(v) = map.get("jack ports") {
            panel = panel.plain("jack ports", v.clone());
        }
        if let Some(v) = map.get("transport") {
            panel = panel.plain("transport", v.clone());
        }

        panel.health = Health::worst(judged);
        panel.summary = if up_count == 0 {
            "offline — DSP stack not running".to_string()
        } else {
            let lat = latency
                .as_deref()
                .and_then(|l| l.split('=').nth(1))
                .map(str::trim)
                .unwrap_or("--");
            format!(
                "{up_count}/{known_count} up · {} · xruns {}",
                lat,
                map.get("xruns").map(String::as_str).unwrap_or("--"),
            )
        };

        Ok(panel)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Verbatim from a real `dsp-ctl status` on the Framework 16, padding
    /// inconsistencies and all.
    const FIXTURE: &str = "\
╔══════════════════════════════════════════════════════════════╗
║           DSP Coprocessor Status                              ║
╠══════════════════════════════════════════════════════════════╣
║  Transport:     local                                       ║
║                                                              ║
║  DSP VM:        ○ INACTIVE                                      ║
║  NETJACK:       ○ INACTIVE                                      ║
║  demod-rt:      ○ INACTIVE                                      ║
║  JACK:           ○ STOPPED                                      ║
╠══════════════════════════════════════════════════════════════╣
║  Sample Rate:    96000 Hz                                    ║
║  Buffer Size:       32 samples (0.33ms period)               ║
║  Xruns:              0                                       ║
║  CPU Load:        0.0%                                      ║
║  Callbacks:          0                                       ║
╠══════════════════════════════════════════════════════════════╣
║  CPU Isolated:  0-1                                         ║
║  Hugepages:          0                                       ║
║  VFIO c7:00.3:      ○ HOST                                      ║
║  JACK Ports:      0 visible                                 ║
╠══════════════════════════════════════════════════════════════╣
║  Latency:       input 0.458ms → output 0.667ms = 1.125ms RT   ║
╚══════════════════════════════════════════════════════════════╝
";

    #[test]
    fn frame_and_rules_are_stripped() {
        let m = parse_status(FIXTURE);
        assert_eq!(m.get("transport").map(String::as_str), Some("local"));
        assert_eq!(m.get("sample rate").map(String::as_str), Some("96000 Hz"));
        assert_eq!(m.get("cpu isolated").map(String::as_str), Some("0-1"));
        // The title line has no colon and must not become a row.
        assert!(!m.contains_key("dsp coprocessor status"));
    }

    #[test]
    fn a_pci_address_in_the_label_does_not_split_early() {
        let m = parse_status(FIXTURE);
        // Splitting on the FIRST colon would give label "vfio c7".
        assert_eq!(m.get("vfio c7:00.3").map(String::as_str), Some("○ HOST"));
    }

    #[test]
    fn latency_line_keeps_its_whole_value() {
        let m = parse_status(FIXTURE);
        assert_eq!(
            m.get("latency").map(String::as_str),
            Some("input 0.458ms → output 0.667ms = 1.125ms RT")
        );
    }

    #[test]
    fn states_key_off_the_word_not_the_bullet() {
        assert_eq!(state_is_up("○ INACTIVE"), Some(false));
        assert_eq!(state_is_up("● ACTIVE"), Some(true));
        assert_eq!(state_is_up("ACTIVE"), Some(true));
        assert_eq!(state_is_up("○ STOPPED"), Some(false));
        assert_eq!(state_is_up("● RUNNING"), Some(true));
        assert_eq!(state_is_up("○ HOST"), Some(false));
        assert_eq!(state_is_up("● BOUND"), Some(true));
        // INACTIVE must not match the ACTIVE arm.
        assert_eq!(state_is_up("inactive"), Some(false));
        // Anything else is an admission of ignorance, not a "down".
        assert_eq!(state_is_up("???"), None);
        assert_eq!(state_is_up(""), None);
    }

    #[test]
    fn numbers_are_read_off_the_head_of_the_value() {
        assert_eq!(leading_number("      32 samples (0.33ms period)"), Some(32.0));
        assert_eq!(leading_number("   0"), Some(0.0));
        assert_eq!(leading_number("0.0%"), Some(0.0));
        assert_eq!(leading_number("none"), None);
        assert_eq!(leading_number(""), None);
    }

    #[test]
    fn empty_output_is_not_parsed_as_healthy() {
        assert!(parse_status("").is_empty());
        assert!(parse_status("\n\n").is_empty());
    }

    #[test]
    fn xruns_thresholds() {
        assert_eq!(xrun_health(0.0), Health::Good);
        assert_eq!(xrun_health(3.0), Health::Warn);
        assert_eq!(xrun_health(500.0), Health::Bad);
    }
}
