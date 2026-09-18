//! PERIMETER pane — the hardening posture, and how old it is.
//!
//! OWNER: work stream S3.
//!
//! The payload behind this pane is `/run/oligarchy-security/status.json`,
//! written by `oligarchy-security-status.timer` every five minutes. So there
//! are TWO ages in play and they are not the same thing:
//!
//!   * the pane's `Freshness` — how long since the collector read the file;
//!   * the CACHE age — how long since the *timer* rewrote it.
//!
//! The second is the dangerous one. A collector reading a two-hour-old file
//! every five seconds is perfectly "Fresh" while reporting that fail2ban was
//! running two hours ago, which is not a claim anyone should make about a
//! firewall. So the cache age gets a banner of its own, amber past 10m and red
//! past 30m: a stale security cache is itself a security finding and has to
//! read as one.
//!
//! Shared helpers (`header`, `stat_line`, `no_collector`, ...) live in
//! `ui::dsp`; see that module's header for why.

use super::dsp::{header, is_stale, leftovers, no_collector, stat_line, take, window};
use super::widgets;
use super::Skin;
use crate::app::{Action, App};
use crossterm::event::{KeyCode, KeyEvent};
use ratatui::layout::{Constraint, Direction, Layout, Rect};
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;
use ratatui::Frame;
use std::time::Duration;
use warroom_core::model::{Freshness, Health, PanelState, Row};

/// Past this the cache is amber, past the second it is red. The timer runs
/// every five minutes, so ten is two missed runs — a timer that failed, not a
/// timer that was busy.
const CACHE_WARN: u64 = 600;
const CACHE_BAD: u64 = 1800;

/// Whatever the collector calls the cache-age row. Matched by substring
/// because the collector is a different work stream; if none of these hit, the
/// banner says UNKNOWN rather than quietly implying the data is current.
const CACHE_KEYS: &[&str] = &["cache age", "cache", "status age", "written", "as of"];

/// Left column: services that are either running or not.
const SERVICES: [(&str, &[&str]); 6] = [
    ("SSH PASSWORD AUTH", &["ssh"]),
    ("FAIL2BAN", &["fail2ban"]),
    ("CLAMAV", &["clamav", "clamd"]),
    ("APPARMOR", &["apparmor"]),
    ("AUDITD", &["auditd", "audit"]),
    ("USBGUARD", &["usbguard"]),
];

/// Right column: posture and counters.
const POSTURE: [(&str, &[&str]); 4] = [
    ("EGRESS", &["egress"]),
    ("DOCKER ROOTLESS", &["docker"]),
    ("MALWARE EVENTS", &["malware", "event"]),
    ("BLOCKLIST", &["blocklist", "blocked"]),
];

#[derive(Debug, Default)]
pub struct State {
    /// First posture row on screen, for a terminal too short to hold them all.
    /// Clamped in `render`, which is the only place that knows the viewport.
    pub scroll: u16,
}

pub fn render(f: &mut Frame, area: Rect, app: &mut App) {
    let rows = app
        .panel("security")
        .and_then(|s| s.panel.as_ref())
        .map(|p| p.rows.len())
        .unwrap_or(0);
    // Worst case the rows all land in one column; the banner and borders cost
    // the rest. Over-clamping would pin the list, under-clamping only means a
    // key press that does nothing.
    let viewport = area.height.saturating_sub(BANNER_H + 2);
    app.perimeter.scroll = app
        .perimeter
        .scroll
        .min((rows as u16).saturating_sub(viewport));
    let scroll = app.perimeter.scroll;
    draw(f, area, &app.skin, app.panel("security"), scroll);
}

/// Banner block height: border, the freshness header, the cache line, border.
const BANNER_H: u16 = 5;

pub(super) fn draw(f: &mut Frame, area: Rect, s: &Skin, st: Option<&PanelState>, scroll: u16) {
    let Some(st) = st else {
        return no_collector(f, area, s, "PERIMETER");
    };
    let Some(p) = st.panel.as_ref() else {
        return widgets::panel(f, area, s, st, true);
    };
    if area.width < 44 || area.height < 12 {
        return widgets::panel(f, area, s, st, true);
    }

    let stale = is_stale(&st.freshness);
    let mut used: Vec<usize> = Vec::new();
    // The cache row is claimed first so no column can render it as an ordinary
    // stat — it has earned the banner.
    let cache = take(p, &mut used, CACHE_KEYS);
    let services: Vec<(&str, Option<&Row>)> = SERVICES
        .iter()
        .map(|(l, k)| (*l, take(p, &mut used, k)))
        .collect();
    let posture: Vec<(&str, Option<&Row>)> = POSTURE
        .iter()
        .map(|(l, k)| (*l, take(p, &mut used, k)))
        .collect();
    let rest = leftovers(p, &used);

    let v = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Length(BANNER_H), Constraint::Min(3)])
        .split(area);

    // --- banner -----------------------------------------------------------
    let blk = widgets::block(s, "PERIMETER", true);
    let inner = blk.inner(v[0]);
    f.render_widget(blk, v[0]);
    let mut lines = header(s, st);
    lines.push(cache_line(s, cache, &st.freshness));
    f.render_widget(Paragraph::new(lines), inner);

    // --- the posture itself ------------------------------------------------
    let wide = area.width >= 92;
    let (left, right) = if wide {
        let c = Layout::default()
            .direction(Direction::Horizontal)
            .constraints([Constraint::Percentage(50), Constraint::Percentage(50)])
            .split(v[1]);
        (c[0], Some(c[1]))
    } else {
        (v[1], None)
    };

    let mut left_rows: Vec<(&str, Option<&Row>)> = services;
    let mut right_rows: Vec<(&str, Option<&Row>)> = posture;
    // Anything the collector sent that neither column named. Never dropped: a
    // new field in the security JSON is exactly the thing you want to see.
    let extra: Vec<(&str, Option<&Row>)> =
        rest.iter().map(|r| (r.label.as_str(), Some(*r))).collect();
    if wide {
        right_rows.extend(extra);
    } else {
        left_rows.extend(right_rows.drain(..));
        left_rows.extend(extra);
    }

    column(f, left, s, "SERVICES", &left_rows, stale, scroll);
    if let Some(right) = right {
        column(f, right, s, "POSTURE", &right_rows, stale, scroll);
    }
}

fn column(
    f: &mut Frame,
    area: Rect,
    s: &Skin,
    title: &str,
    rows: &[(&str, Option<&Row>)],
    stale: bool,
    scroll: u16,
) {
    let blk = widgets::block(s, title, false);
    let inner = blk.inner(area);
    f.render_widget(blk, area);
    let w = inner.width as usize;
    let lines: Vec<Line> = rows
        .iter()
        .map(|(label, row)| match row {
            // A control the collector said nothing about is `--`, never an
            // absent line: the shape of this pane is a checklist, and a
            // checklist with a row quietly removed reads as all-clear.
            Some(r) => stat_line(s, label, &r.value, r.health, w, stale),
            None => stat_line(s, label, "--", Health::Unknown, w, stale),
        })
        .collect();
    f.render_widget(
        Paragraph::new(window(s, lines, scroll as usize, inner.height as usize)),
        inner,
    );
}

/// `CACHE  4m12s  ● OK   (timer rewrites this every 5m)`
///
/// Takes the pane's own `Freshness` as well as the row, because the two ages
/// compound: an age that was 10s true when the collector last read the file is
/// 100s true if that read was 90s ago. Reporting the row verbatim would let a
/// stalled collector hold the cache age at a reassuring number forever.
fn cache_line(s: &Skin, row: Option<&Row>, fr: &Freshness) -> Line<'static> {
    let reported = row.and_then(|r| parse_age(&r.value));
    let raw = row.map(|r| r.value.clone()).unwrap_or_default();
    let (age, offset) = match (reported, fr) {
        (Some(a), Freshness::Fresh) => (Some(a), None),
        (Some(a), Freshness::Stale(d)) => (Some(a + *d), Some(*d)),
        // Failed / Unavailable: no idea how long ago the read was, so no
        // arithmetic is defensible and none is attempted.
        _ => (None, None),
    };
    let mut h = age.map(cache_health).unwrap_or(Health::Unknown);
    // Never Good while the pane itself is not live: nothing on this screen was
    // verified just now, whatever the arithmetic says.
    if !matches!(fr, Freshness::Fresh) && h == Health::Good {
        h = Health::Warn;
    }
    let text = match (age, reported, offset) {
        // Only re-render the number when we actually changed it. The collector
        // rounds ("14m"), and reprinting that as "14m00s" would invent two
        // digits of precision on the one figure this pane exists to report.
        (Some(a), _, Some(_)) => widgets::human_age(a),
        (Some(_), Some(_), None) => raw.trim_end_matches("ago").trim().to_string(),
        (Some(a), None, None) => widgets::human_age(a),
        (None, Some(r), _) => format!("{}+ at last contact", widgets::human_age(r)),
        // No parseable age is not "probably fine". The whole pane is a claim
        // about a moment in time; without that moment it is a claim about
        // nothing, and it says so.
        (None, None, _) if raw.is_empty() => "UNKNOWN".to_string(),
        (None, None, _) => raw.clone(),
    };
    let tail = match (offset, age, reported) {
        (Some(d), _, _) => format!("  (incl. {} since the collector last read it)", widgets::human_age(d)),
        (None, Some(a), _) => match cache_health(a) {
            Health::Good => "  (timer rewrites this every 5m)".to_string(),
            Health::Warn => "  STALE — the status timer has missed a run".to_string(),
            _ => "  STALE — treat every value below as historical".to_string(),
        },
        (None, None, Some(_)) => "  age unverifiable — the collector is not reporting".to_string(),
        (None, None, None) if raw.is_empty() => "  the collector reported no cache age".to_string(),
        // The collector's own "no timestamp" marker, which is a finding rather
        // than a parse failure: the file it read carries no `ts` at all.
        (None, None, None) if raw.trim() == "--" => {
            "  the status file carries no timestamp".to_string()
        }
        _ => "  (unrecognised age format)".to_string(),
    };
    Line::from(vec![
        Span::styled(
            "CACHE ",
            Style::default().fg(s.text_dim()).add_modifier(Modifier::BOLD),
        ),
        Span::styled(
            format!("{text}  "),
            Style::default().fg(s.health(h)).add_modifier(Modifier::BOLD),
        ),
        widgets::dot(s, h),
        Span::styled(
            format!(" {}", h.label()),
            Style::default().fg(s.health(h)),
        ),
        Span::styled(tail, Style::default().fg(s.text_dim())),
    ])
}

fn cache_health(d: Duration) -> Health {
    match d.as_secs() {
        s if s < CACHE_WARN => Health::Good,
        s if s < CACHE_BAD => Health::Warn,
        _ => Health::Bad,
    }
}

/// Read an age the collector rendered as text: `4m12s`, `1h02m`, `252s`, `252`
/// (bare = seconds). Anything with a character that is not a digit, a unit or
/// a space — a timestamp, a word, an error — is refused rather than coerced
/// into a small number, because a small number here means "recently verified".
pub(super) fn parse_age(v: &str) -> Option<Duration> {
    let v = v.trim().trim_end_matches("ago").trim();
    if v.is_empty() {
        return None;
    }
    let mut secs = 0.0f64;
    let mut num = String::new();
    let mut any = false;
    for ch in v.chars() {
        match ch {
            '0'..='9' | '.' => num.push(ch),
            'd' | 'h' | 'm' | 's' | 'D' | 'H' | 'M' | 'S' => {
                let n: f64 = num.parse().ok()?;
                num.clear();
                secs += n * match ch.to_ascii_lowercase() {
                    'd' => 86400.0,
                    'h' => 3600.0,
                    'm' => 60.0,
                    _ => 1.0,
                };
                any = true;
            }
            ' ' => {}
            _ => return None,
        }
    }
    if !num.is_empty() {
        secs += num.parse::<f64>().ok()?;
        any = true;
    }
    if !any || !secs.is_finite() || secs < 0.0 {
        return None;
    }
    Some(Duration::from_secs_f64(secs))
}

pub fn on_key(st: &mut State, k: KeyEvent) -> Option<Action> {
    match k.code {
        KeyCode::Char('j') | KeyCode::Down => st.scroll = st.scroll.saturating_add(1),
        KeyCode::Char('k') | KeyCode::Up => st.scroll = st.scroll.saturating_sub(1),
        KeyCode::Char('g') | KeyCode::Home => st.scroll = 0,
        _ => {}
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use crossterm::event::KeyModifiers;
    use ratatui::backend::TestBackend;
    use ratatui::Terminal;
    use warroom_core::model::{Freshness, Panel};

    fn skin() -> Skin {
        Skin::new(warroom_core::theme::DEMOD)
    }

    /// Stands in for work stream S1's collector, which does not exist yet.
    /// Mirrors the real /run/oligarchy-security/status.json field for field.
    fn demo(cache: Option<&str>) -> Panel {
        let mut p = Panel::new(Health::Warn, "ssh keys only, 599 malware events");
        if let Some(c) = cache {
            p = p.plain("Cache age", c);
        }
        p.row("SSH password auth", "no", Health::Good)
            .row("fail2ban", "active", Health::Good)
            .row("egress", "dry-run/active", Health::Warn)
            .row("ClamAV", "active", Health::Good)
            .row("AppArmor", "inactive", Health::Warn)
            .row("auditd", "inactive", Health::Warn)
            .row("USBGuard", "inactive", Health::Warn)
            .row("docker rootless", "no", Health::Good)
            .row("malware events", "599", Health::Warn)
            .plain("blocklist", "48545 entries")
    }

    fn state(panel: Option<Panel>, f: Freshness) -> PanelState {
        let mut st = PanelState::new("security", "PERIMETER");
        st.panel = panel;
        st.freshness = f;
        st
    }

    fn draw_at(w: u16, h: u16, st: Option<&PanelState>, scroll: u16) -> String {
        let mut term = Terminal::new(TestBackend::new(w, h)).unwrap();
        term.draw(|f| draw(f, f.area(), &skin(), st, scroll)).unwrap();
        term.backend()
            .buffer()
            .content()
            .iter()
            .map(|c| c.symbol())
            .collect()
    }

    #[test]
    fn renders_every_shape_without_panicking() {
        let states = [
            state(Some(demo(Some("4m12s"))), Freshness::Fresh),
            state(Some(demo(Some("42m"))), Freshness::Fresh),
            state(Some(demo(None)), Freshness::Fresh),
            state(
                Some(demo(Some("4m12s"))),
                Freshness::Stale(Duration::from_secs(90)),
            ),
            state(Some(demo(Some("4m12s"))), Freshness::Failed("read: EACCES".into())),
            state(None, Freshness::Failed("read: EACCES".into())),
            state(None, Freshness::Unavailable("no security status cache")),
            state(Some(Panel::new(Health::Unknown, "")), Freshness::Fresh),
        ];
        for st in &states {
            for (w, h) in [(140, 45), (92, 24), (80, 24), (44, 12), (30, 9), (5, 2)] {
                for scroll in [0, 6, u16::MAX] {
                    draw_at(w, h, Some(st), scroll);
                }
            }
        }
        draw_at(140, 45, None, 0);
    }

    #[test]
    fn the_cache_age_is_prominent_and_graded() {
        let fresh = state(Some(demo(Some("4m12s"))), Freshness::Fresh);
        let out = draw_at(140, 45, Some(&fresh), 0);
        assert!(out.contains("CACHE 4m12s"), "cache banner missing: {out:?}");
        assert!(out.contains("every 5m"), "healthy cache note missing");

        // Past 10m the cache is a finding in its own right.
        let amber = state(Some(demo(Some("14m"))), Freshness::Fresh);
        let out = draw_at(140, 45, Some(&amber), 0);
        assert!(out.contains("CACHE 14m "), "collector rounding was reprinted with invented precision");
        assert!(out.contains("missed a run"), "amber cache not called out");

        let red = state(Some(demo(Some("2h05m"))), Freshness::Fresh);
        let out = draw_at(140, 45, Some(&red), 0);
        assert!(out.contains("historical"), "red cache not called out");
    }

    #[test]
    fn a_missing_cache_age_is_never_read_as_current() {
        let st = state(Some(demo(None)), Freshness::Fresh);
        let out = draw_at(140, 45, Some(&st), 0);
        assert!(out.contains("CACHE UNKNOWN"), "missing age not surfaced");
        assert!(out.contains("no cache age"));
    }

    #[test]
    fn every_control_has_a_row_even_when_unreported() {
        let st = state(Some(Panel::new(Health::Unknown, "empty")), Freshness::Fresh);
        let out = draw_at(140, 45, Some(&st), 0);
        for label in [
            "SSH PASSWORD AUTH",
            "FAIL2BAN",
            "CLAMAV",
            "APPARMOR",
            "AUDITD",
            "USBGUARD",
            "EGRESS",
            "DOCKER ROOTLESS",
            "MALWARE EVENTS",
            "BLOCKLIST",
        ] {
            assert!(out.contains(label), "control {label} vanished from the pane");
        }
    }

    #[test]
    fn an_unrecognised_field_is_shown_not_dropped() {
        let p = demo(Some("10s")).plain("Secure Boot", "enrolled");
        let st = state(Some(p), Freshness::Fresh);
        assert!(draw_at(140, 45, Some(&st), 0).contains("SECURE BOOT"));
    }

    #[test]
    fn stale_collection_dims_every_verdict() {
        let st = state(
            Some(demo(Some("10s"))),
            Freshness::Stale(Duration::from_secs(90)),
        );
        let out = draw_at(140, 45, Some(&st), 0);
        assert!(out.contains("NOT LIVE"));
        assert!(!out.contains("● OK"), "stale pane still shows a healthy dot");
    }

    #[test]
    fn parse_age_reads_the_formats_a_collector_might_send() {
        assert_eq!(parse_age("4m12s"), Some(Duration::from_secs(252)));
        assert_eq!(parse_age("1h02m"), Some(Duration::from_secs(3720)));
        assert_eq!(parse_age("252s"), Some(Duration::from_secs(252)));
        assert_eq!(parse_age("252"), Some(Duration::from_secs(252)));
        assert_eq!(parse_age("90s ago"), Some(Duration::from_secs(90)));
        // Refused rather than coerced: a small number here reads as "verified
        // moments ago", which is the one thing this pane must never invent.
        assert_eq!(parse_age("2026-09-17T23:21:41-07:00"), None);
        assert_eq!(parse_age("unknown"), None);
        assert_eq!(parse_age(""), None);
        assert_eq!(parse_age("4ms"), None);
    }

    #[test]
    fn cache_thresholds_are_ten_and_thirty_minutes() {
        assert_eq!(cache_health(Duration::from_secs(599)), Health::Good);
        assert_eq!(cache_health(Duration::from_secs(600)), Health::Warn);
        assert_eq!(cache_health(Duration::from_secs(1799)), Health::Warn);
        assert_eq!(cache_health(Duration::from_secs(1800)), Health::Bad);
    }

    #[test]
    fn keys_move_the_offset() {
        let mut st = State::default();
        let key = |c| KeyEvent::new(c, KeyModifiers::NONE);
        on_key(&mut st, key(KeyCode::Char('j')));
        on_key(&mut st, key(KeyCode::Char('j')));
        assert_eq!(st.scroll, 2);
        on_key(&mut st, key(KeyCode::Char('k')));
        assert_eq!(st.scroll, 1);
        on_key(&mut st, key(KeyCode::Char('g')));
        assert_eq!(st.scroll, 0);
        on_key(&mut st, key(KeyCode::Char('k')));
        assert_eq!(st.scroll, 0, "scroll must not wrap under zero");
    }
}
