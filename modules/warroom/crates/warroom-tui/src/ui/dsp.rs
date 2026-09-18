//! DSP pane — a summary of the realtime audio chain, not a control surface.
//!
//! OWNER: work stream S3.
//!
//! `D` (handled globally in `app.rs`) hands off to the real `dsp-ctl`; nothing
//! in this file mutates anything. The CPU gauge goes through `widgets::gauge`,
//! whose green<50 / yellow<80 / red>=80 thresholds are deliberately identical
//! to `modules/dsp-ctl/src/tui.rs`: two gauges in one distro that disagree
//! about what 70% means is worse than either choice.
//!
//! This file also hosts the handful of helpers the three hand-tuned panes
//! (dsp/mesh/security) share. They would belong in `widgets.rs`, but that file
//! is another work stream's to edit; hoist them across when the streams merge.

use super::widgets;
use super::Skin;
use crate::app::{Action, App};
use crossterm::event::{KeyCode, KeyEvent};
use ratatui::layout::{Constraint, Direction, Layout, Rect};
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Paragraph, Wrap};
use ratatui::Frame;
use warroom_core::model::{Freshness, Health, Panel, PanelState, Row};

// ---------------------------------------------------------------------------
// Shared helpers (S3-owned; see the module doc for why they live here).
// ---------------------------------------------------------------------------

/// True when the pane's payload must not be read as a live measurement.
///
/// Anything that is not `Fresh` is stale for rendering purposes, including
/// `Failed` — a pane that kept its last good payload and then lost contact is
/// showing history, and history must not look like telemetry.
pub(super) fn is_stale(f: &Freshness) -> bool {
    !matches!(f, Freshness::Fresh)
}

/// `widgets::stat` always paints the value at full brightness. A stale pane
/// must not: the entire point of `Freshness` is that an old number *looks*
/// old. Same geometry, dimmed value, health forced to `Unknown` so no stale
/// green dot ever reaches the screen.
pub(super) fn stat_line(
    s: &Skin,
    label: &str,
    value: &str,
    h: Health,
    width: usize,
    stale: bool,
) -> Line<'static> {
    if !stale {
        return widgets::stat(s, label, value, h, width);
    }
    let label = format!("{}:", label.to_uppercase());
    let tail = format!("{value} ");
    let pad = width.saturating_sub(label.chars().count() + tail.chars().count() + 4);
    Line::from(vec![
        Span::styled(label, Style::default().fg(s.text_dim())),
        Span::raw(" ".repeat(pad.max(1))),
        Span::styled(
            tail,
            Style::default().fg(s.text_dim()).add_modifier(Modifier::DIM),
        ),
        widgets::dot(s, Health::Unknown),
        Span::styled(
            format!(" {}", Health::Unknown.label()),
            Style::default().fg(s.health(Health::Unknown)),
        ),
    ])
}

/// The one to three lines that say how much of the rest of the pane can be
/// believed. Always rendered first, never omitted.
pub(super) fn header(s: &Skin, st: &PanelState) -> Vec<Line<'static>> {
    let stale = is_stale(&st.freshness);
    let remembered = st.health();
    // The pane's own verdict is a measurement like any other, so it decays the
    // same way: stale means Unknown, with the last verdict spelled out as
    // history rather than left sitting there in green.
    let h = if stale { Health::Unknown } else { remembered };
    let mut spans = vec![
        widgets::dot(s, h),
        Span::styled(
            format!(" {} ", h.label()),
            Style::default().fg(s.health(h)).add_modifier(Modifier::BOLD),
        ),
        Span::styled(
            st.summary(),
            Style::default().fg(if stale { s.text_dim() } else { s.text() }),
        ),
        Span::raw("  "),
        widgets::freshness_span(s, &st.freshness),
    ];
    if stale && remembered != Health::Unknown {
        spans.push(Span::styled(
            format!("  (last verdict {})", remembered.label()),
            Style::default().fg(s.text_dim()),
        ));
    }
    let mut out = vec![Line::from(spans)];
    match &st.freshness {
        Freshness::Failed(err) => out.push(Line::from(vec![
            Span::styled(
                "COLLECTOR FAILED ",
                Style::default().fg(s.error()).add_modifier(Modifier::BOLD),
            ),
            Span::styled(err.clone(), Style::default().fg(s.text_dim())),
        ])),
        Freshness::Stale(age) => out.push(Line::from(Span::styled(
            format!(
                "LAST CONTACT {} AGO — VALUES BELOW ARE NOT LIVE",
                widgets::human_age(*age)
            ),
            Style::default().fg(s.warning()),
        ))),
        _ => {}
    }
    out
}

/// `app.panel(id)` found nothing at all — the collector is not registered.
/// Distinct from `NO CONTACT`, which means a registered collector has not
/// reported yet; conflating the two would hide a wiring mistake.
pub(super) fn no_collector(f: &mut Frame, area: Rect, s: &Skin, title: &str) {
    let blk = widgets::block(s, title, true);
    let inner = blk.inner(area);
    f.render_widget(blk, area);
    f.render_widget(
        Paragraph::new(vec![
            Line::from(Span::styled(
                "NO COLLECTOR",
                Style::default().fg(s.error()).add_modifier(Modifier::BOLD),
            )),
            Line::from(Span::styled(
                "nothing is registered to feed this pane",
                Style::default().fg(s.text_dim()),
            )),
        ])
        .wrap(Wrap { trim: true }),
        inner,
    );
}

/// Claim the first not-yet-claimed row whose label contains any of `keys`
/// (case-insensitive), so a pane can lay rows out in its own order without
/// ever rendering one twice — and so whatever is left over can still be shown.
///
/// Deliberately forgiving about spelling: the collectors are a separate work
/// stream, and a pane that blanks itself over a renamed label is worse than
/// one that falls back to `--`.
pub(super) fn take<'a>(p: &'a Panel, used: &mut Vec<usize>, keys: &[&str]) -> Option<&'a Row> {
    let i = p.rows.iter().enumerate().position(|(i, r)| {
        if used.contains(&i) {
            return false;
        }
        let l = r.label.to_ascii_lowercase();
        keys.iter().any(|k| l.contains(k))
    })?;
    used.push(i);
    Some(&p.rows[i])
}

/// Every row no section claimed. Rendered rather than dropped: a purpose-built
/// view that silently discards a field the collector sent is a way to not
/// notice a subsystem reporting something new.
pub(super) fn leftovers<'a>(p: &'a Panel, used: &[usize]) -> Vec<&'a Row> {
    p.rows
        .iter()
        .enumerate()
        .filter(|(i, _)| !used.contains(i))
        .map(|(_, r)| r)
        .collect()
}

/// Clip a list of lines to the height it was given, keeping a marker when
/// anything was cut.
///
/// A block that simply stops at its bottom border looks complete, which is the
/// same failure as hiding a row: on an 80x24 terminal the DSP detail rows and
/// the back half of the perimeter checklist both fall off the end, and nothing
/// on screen would say so.
pub(super) fn window(
    s: &Skin,
    lines: Vec<Line<'static>>,
    scroll: usize,
    height: usize,
) -> Vec<Line<'static>> {
    if lines.len() <= height {
        return lines;
    }
    let total = lines.len();
    let keep = height.saturating_sub(1).max(1);
    let first = scroll.min(total.saturating_sub(keep));
    let mut out: Vec<Line> = lines.into_iter().skip(first).take(keep).collect();
    let hidden = total - first - out.len();
    out.push(Line::from(Span::styled(
        if first == 0 {
            format!("… {hidden} more below  j/k scroll")
        } else if hidden == 0 {
            format!("… {first} above  j/k scroll")
        } else {
            format!("… {first} above, {hidden} below  j/k scroll")
        },
        Style::default().fg(s.accent_dim()),
    )));
    out
}

/// First number in a string: `"37.2%"` -> 37.2, `"1.42 ms"` -> 1.42.
pub(super) fn first_number(v: &str) -> Option<f32> {
    let b = v.as_bytes();
    let start = b.iter().position(|c| c.is_ascii_digit())?;
    let mut end = start;
    while end < b.len() && (b[end].is_ascii_digit() || b[end] == b'.') {
        end += 1;
    }
    v[start..end].trim_end_matches('.').parse().ok()
}

/// Render a gauge, or an honest dim line where a gauge would lie.
///
/// A bar is the least honest widget there is when the number behind it is old
/// or absent: a half-full green gauge reads as a live measurement no matter
/// what the pane header says.
pub(super) fn gauge_or_note(
    f: &mut Frame,
    area: Rect,
    s: &Skin,
    label: &str,
    pct: Option<u16>,
    stale: bool,
    raw: &str,
) {
    if let (Some(pct), false) = (pct, stale) {
        return f.render_widget(widgets::gauge(s, label, pct), area);
    }
    let note = match (pct, stale) {
        (Some(v), _) => format!("{v}%  (not live)"),
        (None, _) if raw.is_empty() => "-- no reading".to_string(),
        (None, _) => format!("{raw}  (unreadable)"),
    };
    f.render_widget(
        Paragraph::new(vec![
            Line::from(Span::styled(
                label.to_string(),
                Style::default().fg(s.text_dim()),
            )),
            Line::from(Span::styled(note, Style::default().fg(s.text_dim()))),
        ]),
        area,
    );
}

// ---------------------------------------------------------------------------
// DSP pane proper
// ---------------------------------------------------------------------------

/// The chain, in signal order. Each entry is always drawn — a missing state
/// renders as `--`, not as an absent line, because this pane is a checklist
/// and a checklist with a row quietly removed reads as all-clear.
const CHAIN: [(&str, &[&str]); 4] = [
    ("DSP VM", &["dsp vm", "vm"]),
    ("NETJACK", &["netjack"]),
    ("DEMOD-RT", &["demod-rt", "demod_rt", "demodrt"]),
    ("JACK", &["jack"]),
];

const LATENCY: [(&str, &[&str]); 3] = [
    ("INPUT", &["input"]),
    ("OUTPUT", &["output"]),
    ("ROUND-TRIP", &["round"]),
];

const ENGINE: [(&str, &[&str]); 2] = [("XRUNS", &["xrun"]), ("CALLBACKS", &["callback"])];

/// Narrow on purpose. `isolcpus` contains "cpu", and a loose key would let the
/// isolated-core list drive the load gauge — `0-1` parses as 0, so the pane
/// would report a serenely idle DSP on a host with no DSP running at all.
const CPU_KEYS: &[&str] = &["cpu load", "cpu usage", "dsp cpu"];

/// `dsp-ctl status` prints the whole budget on one line, so the collector sends
/// one row rather than three. Split it here.
const LATENCY_COMBINED: &[&str] = &["latency"];

/// What the round-trip gauge is measured against. `dsp-ctl` prints the number;
/// this pane also shows how much of the budget it eats. 10 ms is roughly where
/// a player starts hearing their own attack twice.
const RT_BUDGET_MS: f32 = 10.0;

#[derive(Debug, Default)]
pub struct State {
    /// Scroll offset, for panes whose content outgrows the viewport.
    pub scroll: u16,
}

pub fn render(f: &mut Frame, area: Rect, app: &mut App) {
    // Read what the clamp needs and let the borrow end before touching
    // `app.dsp`, which is a mutable field of the same struct.
    let rows = app
        .panel("dsp")
        .and_then(|s| s.panel.as_ref())
        .map(|p| p.rows.len())
        .unwrap_or(0);
    // Chrome around the detail rows: borders, the header, two rules. Erring
    // long only means a key press that does nothing.
    let viewport = area.height.saturating_sub(14);
    app.dsp.scroll = app.dsp.scroll.min((rows as u16).saturating_sub(viewport));
    let scroll = app.dsp.scroll;
    draw(f, area, &app.skin, app.panel("dsp"), scroll);
}

pub(super) fn draw(f: &mut Frame, area: Rect, s: &Skin, st: Option<&PanelState>, scroll: u16) {
    let Some(st) = st else {
        return no_collector(f, area, s, "DSP");
    };
    // No payload at all: `widgets::panel` already renders offline / no-contact /
    // failed honestly, and re-implementing those three states here would be
    // three more places for them to drift.
    let Some(p) = st.panel.as_ref() else {
        return widgets::panel(f, area, s, st, true);
    };
    // Too small to split into blocks without truncating every value. The
    // generic renderer is compact and just as honest.
    if area.width < 56 || area.height < 14 {
        return widgets::panel(f, area, s, st, true);
    }

    let stale = is_stale(&st.freshness);
    let mut used: Vec<usize> = Vec::new();
    let chain: Vec<(&str, Option<&Row>)> = CHAIN
        .iter()
        .map(|(l, k)| (*l, take(p, &mut used, k)))
        .collect();
    let latency: Vec<(&str, Option<&Row>)> = LATENCY
        .iter()
        .map(|(l, k)| (*l, take(p, &mut used, k)))
        .collect();
    // One row for the whole budget is what `dsp-ctl status` actually prints.
    // Claimed even when the three specific rows exist, so it can never appear
    // twice, and rendered raw underneath them when it cannot be split.
    let combined = take(p, &mut used, LATENCY_COMBINED);
    let cpu = take(p, &mut used, CPU_KEYS);
    let engine: Vec<(&str, Option<&Row>)> = ENGINE
        .iter()
        .map(|(l, k)| (*l, take(p, &mut used, k)))
        .collect();
    let rest = leftovers(p, &used);

    let outer = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Min(6), Constraint::Length(8)])
        .split(area);
    let wide = area.width >= 100;
    let (chain_area, lat_area) = if wide {
        let c = Layout::default()
            .direction(Direction::Horizontal)
            .constraints([Constraint::Percentage(52), Constraint::Percentage(48)])
            .split(outer[0]);
        (c[0], Some(c[1]))
    } else {
        (outer[0], None)
    };

    // --- signal chain -----------------------------------------------------
    let blk = widgets::block(s, "SIGNAL CHAIN", true);
    let inner = blk.inner(chain_area);
    f.render_widget(blk, chain_area);
    let w = inner.width as usize;
    let mut lines = header(s, st);
    lines.push(widgets::rule(s, w));
    for (label, row) in &chain {
        lines.push(chain_line(s, label, *row, w, stale));
    }
    if lat_area.is_none() {
        lines.push(widgets::rule(s, w));
        lines.extend(latency_lines(s, &latency, combined, w, stale));
    }
    if !rest.is_empty() {
        lines.push(widgets::rule(s, w));
        for r in &rest {
            lines.push(stat_line(s, &r.label, &r.value, r.health, w, stale));
        }
    }
    f.render_widget(
        Paragraph::new(window(s, lines, scroll as usize, inner.height as usize)),
        inner,
    );

    // --- latency budget ---------------------------------------------------
    if let Some(lat_area) = lat_area {
        let blk = widgets::block(s, "LATENCY BUDGET", false);
        let inner = blk.inner(lat_area);
        f.render_widget(blk, lat_area);
        let w = inner.width as usize;
        let split = Layout::default()
            .direction(Direction::Vertical)
            .constraints([Constraint::Min(0), Constraint::Length(2)])
            .split(inner);
        f.render_widget(
            Paragraph::new(latency_lines(s, &latency, combined, w, stale)),
            split[0],
        );
        let ms = round_trip_ms(&latency, combined);
        gauge_or_note(
            f,
            split[1],
            s,
            &format!("ROUND-TRIP vs {RT_BUDGET_MS:.0} ms BUDGET"),
            ms.map(|ms| ((ms / RT_BUDGET_MS) * 100.0).clamp(0.0, 100.0) as u16),
            stale,
            combined.map(|r| r.value.as_str()).unwrap_or(""),
        );
    }

    // --- engine -----------------------------------------------------------
    let blk = widgets::block(s, "ENGINE", false);
    let inner = blk.inner(outer[1]);
    f.render_widget(blk, outer[1]);
    let w = inner.width as usize;
    let split = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Length(2), Constraint::Min(0)])
        .split(inner);
    gauge_or_note(
        f,
        split[0],
        s,
        "DSP CPU LOAD",
        cpu.and_then(|r| cpu_percent(&r.value)),
        stale,
        cpu.map(|r| r.value.as_str()).unwrap_or(""),
    );
    let lines: Vec<Line> = engine
        .iter()
        .map(|(label, row)| chain_line(s, label, *row, w, stale))
        .collect();
    f.render_widget(Paragraph::new(lines), split[1]);
}

/// The three legs of the budget, from whichever shape the collector sent.
///
/// Preference order is per-leg rows, then the one-line form `dsp-ctl status`
/// prints, then the raw string. The raw string is kept even when the split
/// worked, on the same principle as `leftovers`: this pane paraphrases, and a
/// paraphrase should be checkable against the thing it paraphrases.
fn latency_lines(
    s: &Skin,
    legs: &[(&str, Option<&Row>)],
    combined: Option<&Row>,
    w: usize,
    stale: bool,
) -> Vec<Line<'static>> {
    let split = combined.and_then(|r| split_budget(&r.value));
    let mut out: Vec<Line> = legs
        .iter()
        .enumerate()
        .map(|(i, (label, row))| match (row, &split) {
            (Some(r), _) => stat_line(s, label, &r.value, r.health, w, stale),
            (None, Some(ms)) => stat_line(
                s,
                label,
                &format!("{:.3} ms", ms[i]),
                combined.map(|r| r.health).unwrap_or(Health::Unknown),
                w,
                stale,
            ),
            (None, None) => stat_line(s, label, "--", Health::Unknown, w, stale),
        })
        .collect();
    if let Some(r) = combined {
        out.push(Line::from(Span::styled(
            r.value.clone(),
            Style::default().fg(s.text_dim()),
        )));
    }
    out
}

fn round_trip_ms(legs: &[(&str, Option<&Row>)], combined: Option<&Row>) -> Option<f32> {
    legs.iter()
        .find(|(l, _)| *l == "ROUND-TRIP")
        .and_then(|(_, r)| *r)
        .and_then(|r| first_number(&r.value))
        .or_else(|| combined.and_then(|r| split_budget(&r.value)).map(|ms| ms[2]))
}

/// `input 0.458ms → output 0.667ms = 1.125ms RT` -> `[0.458, 0.667, 1.125]`.
/// Refuses anything it does not fully understand rather than half-filling the
/// block with numbers pulled out of the wrong clause.
fn split_budget(v: &str) -> Option<[f32; 3]> {
    let v = v.replace("->", "→");
    let (input, rest) = v.split_once('→')?;
    let (output, rt) = rest.split_once('=')?;
    Some([first_number(input)?, first_number(output)?, first_number(rt)?])
}

/// One checklist line: the collector's value and verdict when it sent one, an
/// explicit `--`/`Unknown` when it did not.
fn chain_line(s: &Skin, label: &str, row: Option<&Row>, w: usize, stale: bool) -> Line<'static> {
    match row {
        Some(r) => stat_line(s, label, &r.value, r.health, w, stale),
        None => stat_line(s, label, "--", Health::Unknown, w, stale),
    }
}

/// `dsp-ctl`'s `GetHealth` reports `cpu_load` as a 0..1 fraction; a collector
/// that has already scaled it sends a `%`. Both are accepted and nothing
/// further is guessed at: a bare number at or below 1.0 is a fraction.
fn cpu_percent(v: &str) -> Option<u16> {
    let n = first_number(v)?;
    let pct = if v.contains('%') || n > 1.0 { n } else { n * 100.0 };
    Some(pct.clamp(0.0, 100.0) as u16)
}

/// Read-only pane: `D` (global) hands off to `dsp-ctl` for anything that acts.
/// The only keys here move the viewport over the detail rows, which do not all
/// fit on an 80x24 terminal.
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
    use ratatui::backend::TestBackend;
    use ratatui::Terminal;
    use std::time::Duration;
    use warroom_core::model::Panel;

    fn skin() -> Skin {
        Skin::new(warroom_core::theme::DEMOD)
    }

    /// Stands in for work stream S1's collector, which does not exist yet.
    fn demo() -> Panel {
        Panel::new(Health::Warn, "netjack up, 3 xruns")
            .row("DSP VM", "active", Health::Good)
            .row("NETJACK", "active", Health::Good)
            .row("demod-rt", "inactive", Health::Bad)
            .row("JACK", "running 48000/128", Health::Good)
            .row("Input latency", "2.792 ms", Health::Good)
            .row("Output latency", "3.100 ms", Health::Good)
            .row("Round-trip", "5.892 ms", Health::Warn)
            .row("CPU load", "0.37", Health::Good)
            .row("Xruns", "3", Health::Warn)
            .plain("Callbacks", "1049233")
            .plain("Transport", "local")
            .plain("Isolated CPUs", "0")
    }

    fn state(panel: Option<Panel>, f: Freshness) -> PanelState {
        let mut st = PanelState::new("dsp", "DSP");
        st.panel = panel;
        st.freshness = f;
        st
    }

    fn text(w: u16, h: u16, mut render: impl FnMut(&mut Frame, Rect)) -> String {
        let mut term = Terminal::new(TestBackend::new(w, h)).unwrap();
        term.draw(|f| render(f, f.area())).unwrap();
        term.backend()
            .buffer()
            .content()
            .iter()
            .map(|c| c.symbol())
            .collect()
    }

    fn draw_at(w: u16, h: u16, st: Option<&PanelState>) -> String {
        text(w, h, |f, a| draw(f, a, &skin(), st, 0))
    }

    #[test]
    fn renders_every_freshness_without_panicking() {
        let states = [
            state(Some(demo()), Freshness::Fresh),
            state(Some(demo()), Freshness::Stale(Duration::from_secs(92))),
            state(Some(demo()), Freshness::Failed("dsp-ctl exit 1".into())),
            state(None, Freshness::Failed("dsp-ctl exit 1".into())),
            state(None, Freshness::Unavailable("dsp-ctl not installed")),
            state(Some(Panel::new(Health::Unknown, "")), Freshness::Fresh),
        ];
        for st in &states {
            for (w, h) in [(140, 45), (100, 20), (80, 24), (56, 14), (40, 10), (8, 3)] {
                draw_at(w, h, Some(st));
            }
        }
        // No collector registered at all.
        draw_at(140, 45, None);
    }

    #[test]
    fn chain_shows_a_missing_state_rather_than_hiding_the_row() {
        let p = Panel::new(Health::Unknown, "nothing running");
        let st = state(Some(p), Freshness::Fresh);
        let out = draw_at(140, 45, Some(&st));
        for label in ["DSP VM", "NETJACK", "DEMOD-RT", "JACK"] {
            assert!(out.contains(label), "checklist row {label} vanished");
        }
    }

    #[test]
    fn unclaimed_rows_are_still_rendered() {
        let p = Panel::new(Health::Good, "ok").plain("Brand New Field", "42");
        let st = state(Some(p), Freshness::Fresh);
        assert!(draw_at(140, 45, Some(&st)).contains("BRAND NEW FIELD"));
    }

    #[test]
    fn stale_suppresses_the_gauge_and_says_so() {
        let st = state(Some(demo()), Freshness::Stale(Duration::from_secs(92)));
        let out = draw_at(140, 45, Some(&st));
        assert!(out.contains("NOT LIVE"), "stale banner missing");
        assert!(out.contains("not live"), "gauge still reads as a measurement");
        // The point of the whole exercise: no stale green dot anywhere.
        assert!(!out.contains("● OK"), "stale pane still shows a healthy dot");
        assert!(out.contains("● --"), "stale rows lost their Unknown verdict");
    }

    #[test]
    fn the_one_line_budget_is_split_into_its_three_legs() {
        // Exactly what `dsp-ctl status` prints, via the mesh collector's
        // `latency` row — the pane must not show three `--` beside it.
        let p = Panel::new(Health::Good, "up")
            .plain("latency", "input 0.458ms → output 0.667ms = 1.125ms RT");
        let st = state(Some(p), Freshness::Fresh);
        let out = draw_at(140, 45, Some(&st));
        assert!(out.contains("0.458 ms"), "input leg missing: {out:?}");
        assert!(out.contains("0.667 ms"), "output leg missing");
        assert!(out.contains("1.125 ms"), "round-trip leg missing");
        assert_eq!(
            split_budget("input 0.458ms -> output 0.667ms = 1.125ms RT"),
            Some([0.458, 0.667, 1.125])
        );
        // Partially understood is not understood.
        assert_eq!(split_budget("input 0.458ms"), None);
        assert_eq!(split_budget("unavailable"), None);
    }

    #[test]
    fn isolcpus_can_never_drive_the_load_gauge() {
        // `0-1` parses as 0, so a loose "cpu" key would paint a serene 0% load
        // on a host where nothing is running at all.
        let p = Panel::new(Health::Unknown, "offline").plain("isolcpus", "0-1");
        let st = state(Some(p), Freshness::Fresh);
        let out = draw_at(140, 45, Some(&st));
        assert!(out.contains("ISOLCPUS"), "isolcpus row was swallowed");
        assert!(
            out.contains("no reading"),
            "isolcpus was read as a CPU load: {out:?}"
        );
    }

    #[test]
    fn cpu_percent_takes_a_fraction_or_a_percentage() {
        assert_eq!(cpu_percent("0.37"), Some(37));
        assert_eq!(cpu_percent("37.2%"), Some(37));
        assert_eq!(cpu_percent("91"), Some(91));
        assert_eq!(cpu_percent("n/a"), None);
    }

    #[test]
    fn first_number_reads_the_leading_value() {
        assert_eq!(first_number("5.892 ms"), Some(5.892));
        assert_eq!(first_number("48545 entries"), Some(48545.0));
        assert_eq!(first_number("inactive"), None);
    }

    #[test]
    fn take_claims_each_row_once_and_in_order() {
        let p = Panel::new(Health::Good, "x")
            .plain("NETJACK", "a")
            .plain("JACK", "b");
        let mut used = Vec::new();
        assert_eq!(take(&p, &mut used, &["netjack"]).unwrap().value, "a");
        assert_eq!(take(&p, &mut used, &["jack"]).unwrap().value, "b");
        assert!(take(&p, &mut used, &["jack"]).is_none());
        assert!(leftovers(&p, &used).is_empty());
    }
}
