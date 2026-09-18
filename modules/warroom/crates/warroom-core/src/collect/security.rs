//! PERIMETER collector — /run/oligarchy-security/status.json (file read only)
//!
//! OWNER: work stream S1.
//!
//! This collector forks **nothing**. `oligarchy-security status` runs `sshd -T`,
//! five `systemctl is-active` calls, an `nft list chain` and a `jq` — which is
//! precisely why `modules/security/security-cli.nix` ships a 5-minute timer
//! that caches the answer to a file. Re-forking that CLI from a 5-second UI
//! loop would reinstate the exact defect the War Room exists to remove.
//!
//! Because the data is a cache, its **age is itself a finding**: a status file
//! that stopped being refreshed shows a perfectly green perimeter forever. The
//! `cache age` row is therefore judged, not informational.

use crate::model::{Availability, Health, Panel};
use serde_json::Value;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

/// Written atomically (tmp + rename) by `oligarchy-security-status.timer`,
/// every 5 minutes. Already read directly by dcf-tray and the greeter.
pub const SECURITY_CACHE: &str = "/run/oligarchy-security/status.json";

/// The timer is `OnUnitActiveSec = 5m`. One missed run is tolerable (a
/// suspend/resume cycle does it); two means the timer is not running.
const CACHE_WARN: Duration = Duration::from_secs(11 * 60);
const CACHE_BAD: Duration = Duration::from_secs(21 * 60);

pub struct SecurityCollector {
    _priv: (),
}

impl SecurityCollector {
    pub fn new() -> Self {
        SecurityCollector { _priv: () }
    }
}

impl Default for SecurityCollector {
    fn default() -> Self {
        Self::new()
    }
}

/// Collapse a `systemctl is-active` value that came back multi-line.
///
/// Real output from this host: `"apparmor": "inactive\ninactive"`. The cause is
/// in `q_unit`: `systemctl is-active "$1" || echo "inactive"` — when the unit
/// name matches a template, `is-active` prints one line per instance AND still
/// exits non-zero, so the `||` fallback appends another. Rendering that raw
/// would put a newline inside a one-line pane row.
///
/// Distinct states are preserved (`active/failed`) because a partial failure
/// across instances is real information; identical ones collapse to one word.
fn normalize_unit_state(raw: &str) -> String {
    let mut seen: Vec<&str> = Vec::new();
    for line in raw.lines() {
        let l = line.trim();
        if l.is_empty() {
            continue;
        }
        if !seen.contains(&l) {
            seen.push(l);
        }
    }
    if seen.is_empty() {
        "--".to_string()
    } else {
        seen.join("/")
    }
}

/// `systemctl is-active` vocabulary. `inactive` is Warn on a *security* pane:
/// a disabled hardening unit is not an error but it is not protection either.
fn unit_health(state: &str) -> Health {
    match state {
        "active" => Health::Good,
        "failed" => Health::Bad,
        "inactive" | "deactivating" | "activating" | "reloading" => Health::Warn,
        _ => Health::Unknown,
    }
}

/// Spellings come from `q_egress_mode` in `modules/security/security-cli.nix`:
/// exactly `enforcing`, `dry-run/active`, or `off`.
fn egress_health(mode: &str) -> Health {
    match mode {
        "enforcing" => Health::Good,
        "dry-run/active" | "off" => Health::Warn,
        _ => Health::Unknown,
    }
}

/// `q_ssh_password` returns the effective `sshd -T` value, or the literal
/// `unknown` when sshd is not installed.
fn ssh_health(v: &str) -> Health {
    match v {
        "no" => Health::Good,
        "yes" => Health::Bad,
        _ => Health::Unknown,
    }
}

/// `q_blocklist` returns `"<n> entries"`, `"off"`, or `"unknown"`.
fn blocklist_health(v: &str) -> Health {
    if v == "off" {
        Health::Warn
    } else if v.ends_with("entries") {
        Health::Good
    } else {
        Health::Unknown
    }
}

/// Parse the `ts` field — `date -Is` output, e.g. `2026-09-17T23:21:41-07:00`
/// (or `...Z`). Returns seconds since the Unix epoch.
///
/// Hand-rolled because `warroom-core` has no date dependency and adding one to
/// read a single timestamp is not worth the closure. Strict: anything that does
/// not match the shape returns `None`, so a malformed `ts` becomes "unknown
/// age" rather than a wildly wrong one.
fn parse_rfc3339(s: &str) -> Option<i64> {
    let s = s.trim();
    let b = s.as_bytes();
    if b.len() < 19 || b[4] != b'-' || b[7] != b'-' || (b[10] != b'T' && b[10] != b't') {
        return None;
    }
    let num = |from: usize, to: usize| -> Option<i64> { s.get(from..to)?.parse::<i64>().ok() };
    let year = num(0, 4)?;
    let month = num(5, 7)?;
    let day = num(8, 10)?;
    let hour = num(11, 13)?;
    let min = num(14, 16)?;
    let sec = num(17, 19)?;
    if !(1..=12).contains(&month) || !(1..=31).contains(&day) || hour > 23 || min > 59 || sec > 60 {
        return None;
    }

    // Offset: `Z`, `+HH:MM` or `-HH:MM`, possibly after a fractional second.
    let rest = &s[19..];
    let rest = match rest.find(['Z', 'z', '+']) {
        Some(_) => rest,
        None => rest,
    };
    let offset_secs: i64 = if let Some(p) = rest.find(['Z', 'z']) {
        let _ = p;
        0
    } else if let Some(p) = rest.rfind(['+', '-']) {
        let tz = &rest[p..];
        let sign = if tz.starts_with('-') { -1 } else { 1 };
        let body = &tz[1..];
        let (hh, mm) = match body.split_once(':') {
            Some((h, m)) => (h, m),
            None if body.len() == 4 => (&body[..2], &body[2..]),
            None => return None,
        };
        sign * (hh.parse::<i64>().ok()? * 3600 + mm.parse::<i64>().ok()? * 60)
    } else {
        // No offset at all: `date -Is` always emits one, so refuse rather than
        // silently assuming UTC and reporting a cache hours out of date.
        return None;
    };

    Some(days_from_civil(year, month, day) * 86_400 + hour * 3600 + min * 60 + sec - offset_secs)
}

/// Howard Hinnant's `days_from_civil`. Exact for the whole proleptic Gregorian
/// calendar, no lookup tables, no leap-year special cases at the call site.
fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let mp = (m + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

fn fmt_ago(d: Duration) -> String {
    let s = d.as_secs();
    if s < 90 {
        format!("{s}s")
    } else if s < 5_400 {
        format!("{}m", s / 60)
    } else if s < 172_800 {
        format!("{}h", s / 3600)
    } else {
        format!("{}d", s / 86_400)
    }
}

/// String field, normalized. Missing means the writer did not emit it.
fn field<'a>(v: &'a Value, key: &str) -> Option<String> {
    v.get(key).and_then(Value::as_str).map(normalize_unit_state)
}

impl super::Collector for SecurityCollector {
    fn id(&self) -> &'static str {
        "security"
    }

    fn title(&self) -> &'static str {
        "PERIMETER"
    }

    fn interval(&self) -> Duration {
        Duration::from_secs(5)
    }

    fn probe(&self) -> Availability {
        // The cache, not the CLI: re-forking `oligarchy-security status` would
        // defeat the entire reason the timer writes this file.
        if std::path::Path::new(SECURITY_CACHE).is_file() {
            Availability::Present
        } else {
            Availability::Missing(
                "no security status cache — enable custom.hardening",
            )
        }
    }

    fn collect(&mut self) -> anyhow::Result<Panel> {
        let raw = std::fs::read_to_string(SECURITY_CACHE)
            .map_err(|e| anyhow::anyhow!("{SECURITY_CACHE}: {e}"))?;
        // The file is written tmp+rename, so a torn read is not expected — but
        // an empty file after a failed `build_status` is, and it must not read
        // as "nothing wrong".
        if raw.trim().is_empty() {
            anyhow::bail!("{SECURITY_CACHE} is empty");
        }
        let v: Value = serde_json::from_str(&raw)
            .map_err(|e| anyhow::anyhow!("{SECURITY_CACHE}: {e}"))?;

        let mut panel = Panel::new(Health::Unknown, String::new());
        let mut judged = Vec::new();

        // ── cache age ───────────────────────────────────────────────────────
        // First, and judged: every row below is only as true as this is.
        let ts = v.get("ts").and_then(Value::as_str).and_then(parse_rfc3339);
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs() as i64)
            .unwrap_or(0);
        let (age_value, age_health) = match ts {
            Some(t) if t <= now => {
                let age = Duration::from_secs((now - t) as u64);
                let h = if age >= CACHE_BAD {
                    Health::Bad
                } else if age >= CACHE_WARN {
                    Health::Warn
                } else {
                    Health::Good
                };
                (format!("{} ago", fmt_ago(age)), h)
            }
            // A timestamp in the future means the clock moved or the file was
            // written by something else. Either way we cannot age it.
            Some(_) => ("in the future".to_string(), Health::Unknown),
            None => ("--".to_string(), Health::Unknown),
        };
        judged.push(age_health);
        panel = panel.row("cache age", age_value, age_health);

        // ── judged posture fields ───────────────────────────────────────────
        let ssh = field(&v, "ssh_password_auth");
        let ssh_h = ssh.as_deref().map(ssh_health).unwrap_or(Health::Unknown);
        judged.push(ssh_h);
        panel = panel.row(
            "ssh password auth",
            ssh.clone().unwrap_or_else(|| "--".into()),
            ssh_h,
        );

        let egress = field(&v, "egress");
        let egress_h = egress.as_deref().map(egress_health).unwrap_or(Health::Unknown);
        judged.push(egress_h);
        panel = panel.row(
            "strict egress",
            egress.clone().unwrap_or_else(|| "--".into()),
            egress_h,
        );

        for (key, label) in [
            ("fail2ban", "fail2ban"),
            ("clamav", "clamav"),
            ("apparmor", "apparmor"),
            ("auditd", "auditd"),
            ("usbguard", "usbguard"),
        ] {
            let val = field(&v, key);
            let h = val.as_deref().map(unit_health).unwrap_or(Health::Unknown);
            judged.push(h);
            panel = panel.row(label, val.unwrap_or_else(|| "--".into()), h);
        }

        let blocklist = field(&v, "blocklist");
        let bl_h = blocklist.as_deref().map(blocklist_health).unwrap_or(Health::Unknown);
        judged.push(bl_h);
        panel = panel.row(
            "ip blocklists",
            blocklist.unwrap_or_else(|| "--".into()),
            bl_h,
        );

        // `malware_events` is a line count of the shield's event log. It only
        // ever grows, so a non-zero value is history, not an incident in
        // progress — Warn, never Bad.
        let events = v.get("malware_events").and_then(Value::as_i64);
        let ev_h = match events {
            Some(0) => Health::Good,
            Some(_) => Health::Warn,
            None => Health::Unknown,
        };
        judged.push(ev_h);
        panel = panel.row(
            "malware events",
            events.map(|e| e.to_string()).unwrap_or_else(|| "--".into()),
            ev_h,
        );

        // Informational: this host deliberately does NOT grant the docker
        // group (root-equivalent), so "no" here is a configuration fact and
        // not a finding. It carries no health and does not roll up.
        panel = panel.plain(
            "docker rootless",
            field(&v, "docker_rootless").unwrap_or_else(|| "--".into()),
        );

        panel.health = Health::worst(judged);
        panel.summary = format!(
            "egress {} · ssh pw {} · events {} · cache {}",
            v.get("egress").and_then(Value::as_str).unwrap_or("?"),
            v.get("ssh_password_auth").and_then(Value::as_str).unwrap_or("?"),
            events.map(|e| e.to_string()).unwrap_or_else(|| "?".into()),
            match ts {
                Some(t) if t <= now => fmt_ago(Duration::from_secs((now - t) as u64)),
                _ => "?".to_string(),
            }
        );

        Ok(panel)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Verbatim `/run/oligarchy-security/status.json` from this host, including
    /// the real multi-line `is-active` values.
    const FIXTURE: &str = r#"{
  "ts": "2026-09-17T23:21:41-07:00",
  "ssh_password_auth": "no",
  "fail2ban": "active",
  "egress": "dry-run/active",
  "clamav": "active",
  "apparmor": "inactive\ninactive",
  "auditd": "inactive\ninactive",
  "usbguard": "inactive\ninactive",
  "docker_rootless": "no",
  "malware_events": 599,
  "blocklist": "48545 entries"
}"#;

    #[test]
    fn multiline_unit_states_collapse_to_one_line() {
        let v: Value = serde_json::from_str(FIXTURE).unwrap();
        assert_eq!(field(&v, "apparmor").as_deref(), Some("inactive"));
        assert_eq!(field(&v, "fail2ban").as_deref(), Some("active"));
        // Genuinely differing instance states are preserved, not collapsed.
        assert_eq!(normalize_unit_state("active\nfailed"), "active/failed");
        assert_eq!(normalize_unit_state(""), "--");
        assert_eq!(normalize_unit_state("\n\n"), "--");
    }

    #[test]
    fn unit_vocabulary_maps_honestly() {
        assert_eq!(unit_health("active"), Health::Good);
        assert_eq!(unit_health("failed"), Health::Bad);
        assert_eq!(unit_health("inactive"), Health::Warn);
        // Anything the CLI could newly emit is Unknown, never Good.
        assert_eq!(unit_health("active/failed"), Health::Unknown);
        assert_eq!(unit_health(""), Health::Unknown);
        assert_eq!(unit_health("--"), Health::Unknown);
    }

    #[test]
    fn egress_and_ssh_spellings_match_the_nix_source() {
        assert_eq!(egress_health("enforcing"), Health::Good);
        assert_eq!(egress_health("dry-run/active"), Health::Warn);
        assert_eq!(egress_health("off"), Health::Warn);
        assert_eq!(egress_health("anything-else"), Health::Unknown);

        assert_eq!(ssh_health("no"), Health::Good);
        assert_eq!(ssh_health("yes"), Health::Bad);
        assert_eq!(ssh_health("unknown"), Health::Unknown);
    }

    #[test]
    fn blocklist_counts_are_good_and_off_is_not() {
        assert_eq!(blocklist_health("48545 entries"), Health::Good);
        assert_eq!(blocklist_health("off"), Health::Warn);
        assert_eq!(blocklist_health("unknown"), Health::Unknown);
    }

    #[test]
    fn rfc3339_with_a_negative_offset() {
        // 2026-09-17T23:21:41-07:00 == 2026-09-18T06:21:41Z
        let a = parse_rfc3339("2026-09-17T23:21:41-07:00").expect("parses");
        let b = parse_rfc3339("2026-09-18T06:21:41Z").expect("parses");
        assert_eq!(a, b);
    }

    #[test]
    fn rfc3339_epoch_and_leap_day_anchors() {
        assert_eq!(parse_rfc3339("1970-01-01T00:00:00Z"), Some(0));
        assert_eq!(parse_rfc3339("2000-02-29T00:00:00Z"), Some(951_782_400));
        assert_eq!(parse_rfc3339("2024-02-29T12:00:00+00:00"), Some(1_709_208_000));
    }

    #[test]
    fn a_malformed_timestamp_is_no_age_rather_than_a_wrong_one() {
        assert_eq!(parse_rfc3339(""), None);
        assert_eq!(parse_rfc3339("not a date"), None);
        assert_eq!(parse_rfc3339("2026-13-01T00:00:00Z"), None);
        assert_eq!(parse_rfc3339("2026-09-17T25:00:00Z"), None);
        // No offset: `date -Is` always writes one, so this is not our format.
        assert_eq!(parse_rfc3339("2026-09-17T23:21:41"), None);
    }

    #[test]
    fn ages_format_compactly() {
        assert_eq!(fmt_ago(Duration::from_secs(30)), "30s");
        assert_eq!(fmt_ago(Duration::from_secs(300)), "5m");
        assert_eq!(fmt_ago(Duration::from_secs(7200)), "2h");
        assert_eq!(fmt_ago(Duration::from_secs(300_000)), "3d");
    }

    #[test]
    fn the_whole_fixture_rolls_up_to_warn_not_good() {
        // apparmor/auditd/usbguard inactive + dry-run egress + 599 events.
        // If this ever returns Good, a health mapping has gone dishonest.
        let v: Value = serde_json::from_str(FIXTURE).unwrap();
        let judged = vec![
            ssh_health(&field(&v, "ssh_password_auth").unwrap()),
            egress_health(&field(&v, "egress").unwrap()),
            unit_health(&field(&v, "apparmor").unwrap()),
        ];
        assert_eq!(Health::worst(judged), Health::Warn);
    }
}
