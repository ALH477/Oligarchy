//! SITREP — the one screen that answers "is my machine healthy".
//!
//! OWNER: work stream S2.
//!
//! Two bands. The top is the cockpit strip: the `system` panel rendered as
//! instruments rather than a list — load and memory as gauges, temperature and
//! identity as stat lines. The bottom is the rollup grid: every other
//! subsystem reduced to one tile.
//!
//! Layout is width-driven, not fixed. A 140-column window gets the 2x3 grid the
//! design asks for; 80 columns gets 3x2; anything narrower falls back to one
//! column and then to a borderless list. The rule is that a small terminal
//! draws *less*, never garbage.

use super::{widgets, Skin};
use crate::app::App;
use ratatui::layout::{Constraint, Direction, Layout, Rect};
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;
use ratatui::Frame;
use warroom_core::model::{Freshness, Health, Panel, PanelState};

/// Subsystems that get a rollup card, in grid order. The `&'static str` title
/// is carried alongside the id so a collector that never reported still gets a
/// correctly-named tile instead of a lowercase one.
const CARDS: [(&str, &str); 6] = [
    ("dsp", "DSP"),
    ("mesh", "MESH"),
    ("security", "PERIMETER"),
    ("net", "NET"),
    ("ai", "AI"),
    ("forge", "FORGE"),
];

/// Below this the cockpit strip loses its gauge column.
const WIDE_COCKPIT: u16 = 74;
/// Widest a gauge is allowed to get before it stops reading as an instrument.
const INSTRUMENT_W: u16 = 46;
/// Tallest a rollup tile is allowed to get.
const TILE_H: usize = 14;

pub fn render(f: &mut Frame, area: Rect, app: &mut App) {
    draw(f, area, &app.skin, &app.panels);
}

/// The whole screen, reachable without an `App` so the layout can be rendered
/// into a `TestBackend` at every size this thing claims to support.
pub(super) fn draw(f: &mut Frame, area: Rect, skin: &Skin, panels: &[PanelState]) {
    if area.height < 6 || area.width < 16 {
        return;
    }

    // The strip wants 9 rows (border + verdict + rule + four stats + slack).
    // On a short terminal it gives rows back to the grid before the grid has to
    // start dropping tiles.
    let strip = match area.height {
        0..=13 => 6,
        14..=17 => 7,
        18..=21 => 8,
        _ => 9,
    };

    let rows = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Length(strip), Constraint::Min(0)])
        .split(area);

    match find(panels, "system") {
        Some(st) => cockpit(f, rows[0], skin, st),
        None => cockpit(f, rows[0], skin, &PanelState::new("system", "SITREP")),
    }

    grid(f, rows[1], skin, panels);
}

fn find<'a>(panels: &'a [PanelState], id: &str) -> Option<&'a PanelState> {
    panels.iter().find(|p| p.id == id)
}

// ---------------------------------------------------------------------------
// the cockpit strip
// ---------------------------------------------------------------------------

/// Read a row out of the system panel by name, with the reading the collector
/// gave it. Missing rows render `--` rather than vanishing: an instrument that
/// disappears when its sensor does is how you stop noticing the sensor died.
fn read<'a>(p: Option<&'a Panel>, keys: &[&str]) -> (String, Health) {
    match p.and_then(|p| widgets::find_row(p, keys)) {
        Some(r) => (r.value.clone(), r.health),
        None => ("--".to_string(), Health::Unknown),
    }
}

fn cockpit(f: &mut Frame, area: Rect, s: &Skin, st: &PanelState) {
    let blk = widgets::block(s, st.title, true);
    let inner = blk.inner(area);
    f.render_widget(blk, area);
    if inner.width == 0 || inner.height == 0 {
        return;
    }

    let stale = !matches!(st.freshness, Freshness::Fresh);
    let p = st.panel.as_ref();

    // A dead system collector is the one case where the cockpit gives up its
    // instruments entirely — fake needles are worse than a blank panel.
    if p.is_none() {
        let (head, detail, bad) = match &st.freshness {
            Freshness::Unavailable(why) => ("SUBSYSTEM OFFLINE", (*why).to_string(), false),
            Freshness::Failed(e) => ("NO CONTACT", e.clone(), true),
            _ => ("NO CONTACT", "awaiting first report".into(), false),
        };
        let w = inner.width as usize;
        let mut lines = vec![
            widgets::status_line(s, widgets::shown_health(st), head, &st.freshness, w),
            widgets::rule(s, w),
            Line::from(Span::styled(
                widgets::fit(&detail, w),
                Style::default().fg(if bad { s.error() } else { s.text_dim() }),
            )),
        ];
        lines.truncate(inner.height as usize);
        return f.render_widget(Paragraph::new(lines), inner);
    }

    let w = inner.width as usize;

    // The headline spans the whole strip; the instruments sit under it. Letting
    // a `LABEL: ... value` line stretch across 130 columns is the single
    // ugliest thing a ratatui dashboard can do, so the columns below are
    // capped at a readable width and the slack is left as slack.
    let head = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Length(1), Constraint::Length(1), Constraint::Min(0)])
        .split(inner);
    f.render_widget(
        Paragraph::new(widgets::status_line(
            s,
            widgets::shown_health(st),
            &st.summary(),
            &st.freshness,
            w,
        )),
        head[0],
    );
    f.render_widget(Paragraph::new(widgets::rule(s, w)), head[1]);
    if head[2].height == 0 {
        return;
    }

    let wide = inner.width >= WIDE_COCKPIT;
    if !wide {
        return vitals(f, head[2], s, p, stale, false);
    }
    let vitals_w = (inner.width / 2).clamp(26, 40);
    let cols = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([
            Constraint::Length(vitals_w),
            Constraint::Length(2),
            Constraint::Min(0),
        ])
        .split(head[2]);
    vitals(f, cols[0], s, p, stale, true);
    instruments(f, cols[2], s, p, stale);
}

/// Left column: who this machine is and how long it has been up.
fn vitals(f: &mut Frame, area: Rect, s: &Skin, p: Option<&Panel>, stale: bool, wide: bool) {
    let w = area.width as usize;
    let h = area.height as usize;
    if w == 0 || h == 0 {
        return;
    }

    let mut lines: Vec<Line> = Vec::new();

    // Narrow cockpit: the instruments have nowhere else to go, so they come
    // back here as one-row bars — and they come FIRST, because when the strip
    // runs out of rows it is the kernel version that should fall off the
    // bottom, not the load average.
    if !wide {
        // Padded to a common label width so the two bars start in the same
        // column; ragged bars read as two unrelated numbers.
        for (label, keys) in [
            ("load  ", &["load"][..]),
            ("memory", &["memory", "mem", "ram"]),
        ] {
            let (raw, health) = read(p, keys);
            match widgets::pct_from(&raw) {
                Some(pct) if !stale => lines.push(widgets::bar_line(s, label, pct, w)),
                _ => lines.push(widgets::stat(
                    s,
                    label,
                    &raw,
                    if stale { Health::Unknown } else { health },
                    w,
                )),
            }
        }
        let (temp, temp_h) = read(p, &["temp", "thermal"]);
        lines.push(widgets::stat(
            s,
            "cpu temp",
            &temp,
            if stale { Health::Unknown } else { temp_h },
            w,
        ));
    }

    let mut push = |label: &str, keys: &[&str]| {
        let (v, _) = read(p, keys);
        lines.push(widgets::kv(s, label, &v, w));
    };
    push("uptime", &["uptime"]);
    push("persona", &["persona"]);
    push("kernel", &["kernel"]);
    push("power", &["power", "profile", "governor"]);

    lines.truncate(h);
    let tint = if stale { s.text_dim() } else { s.text() };
    f.render_widget(Paragraph::new(lines).style(Style::default().fg(tint)), area);
}

/// Right half: the two gauges plus the temperature readout. `gauge()`'s
/// thresholds are dsp-ctl's, and `meter_health` derives the dot from the same
/// numbers so the bar and the verdict can never disagree.
fn instruments(f: &mut Frame, area: Rect, s: &Skin, p: Option<&Panel>, stale: bool) {
    if area.width < 8 || area.height == 0 {
        return;
    }
    // A gauge 90 cells wide is not more informative than one 44 cells wide, it
    // is just harder to read at a glance. Cap it and let the slack be slack.
    let area = Rect { width: area.width.min(INSTRUMENT_W), ..area };
    let w = area.width as usize;

    let (load_raw, load_h) = read(p, &["load"]);
    let (mem_raw, mem_h) = read(p, &["memory", "mem", "ram"]);
    let (temp, temp_h) = read(p, &["temp", "thermal"]);

    let rows = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(2),
            Constraint::Length(2),
            Constraint::Length(1),
            Constraint::Min(0),
        ])
        .split(area);

    let mut meter = |slot: Rect, label: &str, raw: &str, declared: Health| {
        if slot.height == 0 {
            return;
        }
        // A stale gauge reads exactly like a live one — there is no dimmed
        // version of a filled bar that anybody notices. Stale readings are
        // demoted to a number carrying an explicit `--` verdict.
        if stale {
            let l = widgets::stat(s, label, raw, Health::Unknown, w);
            return f.render_widget(Paragraph::new(l), slot);
        }
        match widgets::pct_from(raw) {
            Some(pct) if slot.height >= 2 => f.render_widget(widgets::gauge(s, label, pct), slot),
            Some(pct) => f.render_widget(Paragraph::new(widgets::bar_line(s, label, pct, w)), slot),
            None => f.render_widget(Paragraph::new(widgets::stat(s, label, raw, declared, w)), slot),
        }
    };
    meter(rows[0], "load", &load_raw, load_h);
    meter(rows[1], "memory", &mem_raw, mem_h);

    if rows[2].height > 0 {
        f.render_widget(
            Paragraph::new(widgets::stat(
                s,
                "cpu temp",
                &temp,
                if stale { Health::Unknown } else { temp_h },
                w,
            )),
            rows[2],
        );
    }
}

// ---------------------------------------------------------------------------
// the rollup grid
// ---------------------------------------------------------------------------

fn grid(f: &mut Frame, area: Rect, skin: &Skin, panels: &[PanelState]) {
    if area.height == 0 || area.width == 0 {
        return;
    }

    // Each tile needs a border plus at least a verdict line to be worth
    // drawing; below that the grid becomes a list with no borders at all.
    let cols: usize = if area.width >= 108 {
        3
    } else if area.width >= 66 {
        2
    } else {
        1
    };
    let grid_rows = CARDS.len().div_ceil(cols);
    // Two rows of border plus a verdict plus a headline: a tile with less than
    // that is a box with a dot in it, and the list reads better.
    if (area.height as usize) < grid_rows * 4 {
        return compact(f, area, skin, panels);
    }

    // Tiles are capped rather than stretched: a rollup card holding four lines
    // of text inside a sixteen-row border reads as a bug, and the empty strip
    // underneath reads as headroom.
    let band_h = ((area.height as usize) / grid_rows).min(TILE_H) as u16;
    let mut vconstraints: Vec<Constraint> =
        (0..grid_rows).map(|_| Constraint::Length(band_h)).collect();
    vconstraints.push(Constraint::Min(0));
    let bands = Layout::default()
        .direction(Direction::Vertical)
        .constraints(vconstraints)
        .split(area);
    let bands = &bands[..grid_rows];

    let col_pct = (100 / cols) as u16;
    for (row, band) in bands.iter().enumerate() {
        let hconstraints: Vec<Constraint> =
            (0..cols).map(|_| Constraint::Percentage(col_pct)).collect();
        let cells = Layout::default()
            .direction(Direction::Horizontal)
            .constraints(hconstraints)
            .split(*band);
        for (col, cell) in cells.iter().enumerate() {
            let Some(&(id, title)) = CARDS.get(row * cols + col) else { continue };
            match find(panels, id) {
                Some(st) => widgets::card(f, *cell, skin, st),
                None => widgets::card(f, *cell, skin, &PanelState::new(id, title)),
            }
        }
    }
}

/// The last-resort layout: one borderless line per subsystem. Still carries the
/// verdict text and the freshness stamp, because those are the two things the
/// screen exists for.
fn compact(f: &mut Frame, area: Rect, s: &Skin, panels: &[PanelState]) {
    let w = area.width as usize;
    let name_w = CARDS.iter().map(|(_, t)| t.chars().count()).max().unwrap_or(8);

    let mut lines: Vec<Line> = vec![widgets::section(s, "rollup")];
    for &(id, title) in CARDS.iter() {
        let owned;
        let st = match find(panels, id) {
            Some(st) => st,
            None => {
                owned = PanelState::new(id, title);
                &owned
            }
        };
        let h = widgets::shown_health(st);
        let head = format!("{title:<name_w$}");
        let mut spans = vec![
            Span::styled(head, Style::default().fg(s.accent_dim()).add_modifier(Modifier::BOLD)),
            Span::raw(" "),
        ];
        spans.extend(widgets::verdict(s, h));
        // `● WARN` and `● --` are different widths; pad so the summaries start
        // in one column.
        spans.push(Span::raw(" ".repeat(8usize.saturating_sub(2 + h.label().len()))));
        // The freshness stamp is not optional here either: this layout exists
        // because the terminal is small, not because the reader cares less.
        let fs = widgets::freshness_span(s, &st.freshness);
        let fw = fs.content.chars().count();
        let used: usize = spans.iter().map(|sp| sp.content.chars().count()).sum();
        let body = w.saturating_sub(used + fw + 2);
        let summary = widgets::fit(&st.summary(), body);
        let pad = w.saturating_sub(used + summary.chars().count() + fw).max(1);
        spans.push(Span::styled(summary, Style::default().fg(s.text_dim())));
        spans.push(Span::raw(" ".repeat(pad)));
        spans.push(fs);
        lines.push(Line::from(spans));
    }
    lines.truncate(area.height as usize);
    f.render_widget(Paragraph::new(lines), area);
}

#[cfg(test)]
mod tests {
    use super::*;
    use ratatui::backend::TestBackend;
    use ratatui::Terminal;
    use std::time::Duration;
    use warroom_core::model::Freshness;

    fn skin() -> Skin {
        Skin::new(warroom_core::theme::DEMOD)
    }

    fn st(id: &'static str, title: &'static str, p: Option<Panel>, fr: Freshness) -> PanelState {
        let mut s = PanelState::new(id, title);
        s.panel = p;
        s.freshness = fr;
        s
    }

    /// Stands in for S1's collectors.
    fn fleet() -> Vec<PanelState> {
        vec![
            st(
                "system",
                "SITREP",
                Some(
                    Panel::new(Health::Good, "nominal — 6 of 7 subsystems reporting")
                        .row("Load", "3.21 / 16", Health::Good)
                        .row("Memory", "18.9G / 30.6G", Health::Warn)
                        .row("CPU temp", "61 °C", Health::Good)
                        .plain("Uptime", "4d 02h 17m")
                        .plain("Persona", "workstation")
                        .plain("Kernel", "6.12.82-zen1")
                        .plain("Power profile", "balanced"),
                ),
                Freshness::Fresh,
            ),
            st(
                "dsp",
                "DSP",
                Some(
                    Panel::new(Health::Warn, "netjack up, 3 xruns")
                        .row("Round-trip", "5.892 ms", Health::Warn)
                        .row("DSP VM", "active", Health::Good),
                ),
                Freshness::Fresh,
            ),
            st(
                "mesh",
                "MESH",
                Some(Panel::new(Health::Good, "4 peers, 2 routes").row("Peers", "4", Health::Good)),
                Freshness::Stale(Duration::from_secs(92)),
            ),
            st(
                "security",
                "PERIMETER",
                Some(
                    Panel::new(Health::Bad, "egress ruleset not loaded")
                        .row("Egress", "inactive", Health::Bad),
                ),
                Freshness::Fresh,
            ),
            st("net", "NET", None, Freshness::Failed("nft exit 1".into())),
            st("ai", "AI", None, Freshness::Stale(Duration::ZERO)),
            st(
                "forge",
                "FORGE",
                None,
                Freshness::Unavailable("oligarchy-forge not installed"),
            ),
        ]
    }

    fn text(w: u16, h: u16, panels: &[PanelState]) -> String {
        let mut term = Terminal::new(TestBackend::new(w, h)).unwrap();
        term.draw(|f| draw(f, f.area(), &skin(), panels)).unwrap();
        let buf = term.backend().buffer().clone();
        let mut out = String::new();
        for y in 0..h {
            for x in 0..w {
                out.push_str(buf[(x, y)].symbol());
            }
            out.push('\n');
        }
        out
    }

    #[test]
    fn show() {
        if std::env::var_os("WARROOM_SHOW").is_some() {
            for (w, h) in [(140u16, 43u16), (100, 30), (80, 22), (66, 18), (48, 14)] {
                println!("\n===== SITREP {w}x{h} =====");
                print!("{}", text(w, h, &fleet()));
            }
        }
    }

    #[test]
    fn every_subsystem_gets_a_tile_at_every_size() {
        for (w, h) in [(220u16, 60u16), (140, 43), (100, 30), (80, 22), (66, 18), (48, 14)] {
            let out = text(w, h, &fleet());
            for (_, title) in CARDS.iter() {
                assert!(out.contains(title), "{title} vanished at {w}x{h}");
            }
        }
    }

    #[test]
    fn a_stale_rollup_never_shows_a_healthy_dot() {
        // Every collector holds its last-known verdict, and every one of them
        // is 92 seconds old. Nothing on the screen may say OK, at any size,
        // including the borderless list — a stale green dot is the one failure
        // this whole screen exists to prevent.
        let stale: Vec<PanelState> = fleet()
            .into_iter()
            .map(|mut p| {
                p.freshness = Freshness::Stale(Duration::from_secs(92));
                p
            })
            .collect();
        for (w, h) in [(140u16, 43u16), (100, 30), (80, 22), (66, 18), (48, 14)] {
            let out = text(w, h, &stale);
            assert!(out.contains("STALE 1m32s"), "no age stamp at {w}x{h}");
            assert!(!out.contains("● OK"), "stale verdict survived at {w}x{h}");
            assert!(!out.contains("● WARN"), "stale verdict survived at {w}x{h}");
            assert!(!out.contains("● FAIL"), "stale verdict survived at {w}x{h}");
        }
    }

    #[test]
    fn dead_collectors_say_so_in_words() {
        let out = text(140, 43, &fleet());
        assert!(out.contains("SUBSYSTEM OFFLINE"));
        assert!(out.contains("not installed"));
        assert!(out.contains("NO CONTACT"));
        assert!(out.contains("nft exit 1"));
    }

    #[test]
    fn renders_at_every_size_without_panicking() {
        let empty: Vec<PanelState> = Vec::new();
        for w in [8u16, 16, 24, 40, 48, 66, 80, 100, 140, 240] {
            for h in [2u16, 4, 6, 9, 12, 14, 18, 22, 30, 43, 60] {
                text(w, h, &fleet());
                text(w, h, &empty);
            }
        }
    }
}
