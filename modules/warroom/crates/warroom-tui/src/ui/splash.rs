//! The one ASCII moment.
//!
//! OWNER: work stream S2.
//!
//! The splash earns its place by doing real work: it IS the first collection
//! pass (see `app::SPLASH_MIN`), and the roster below fills in live as each
//! collector reports. Without the roster this would be a load screen with a
//! logo on it, which is exactly the thing the rest of this TUI refuses to be.
//!
//! The wordmark is ANSI Shadow — the house FIGlet face, same as
//! `modules/greeting`. Color is a per-*column* interpolation of
//! `gradient_start` → `gradient_end` (turquoise → violet), computed from the
//! column's position across the whole 70-cell wordmark rather than per letter,
//! so the sweep is continuous through the glyphs. Runs of identical color
//! collapse into one `Span`, which matters in `Ansi16` mode where seventy
//! columns quantize down to two or three distinct colors.

use super::widgets;
use super::Skin;
use crate::app::App;
use ratatui::layout::{Alignment, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;
use ratatui::Frame;
use warroom_core::model::{Freshness, PanelState};

/// ANSI Shadow `OLIGARCHY`, 70 columns by 6 rows. Every row is exactly the same
/// width — `wordmark_rows_are_rectangular` proves it, because a ragged row
/// silently skews the gradient of every row below it.
const WORDMARK: [&str; 6] = [
    " ██████╗ ██╗     ██╗ ██████╗  █████╗ ██████╗  ██████╗██╗  ██╗██╗   ██╗",
    "██╔═══██╗██║     ██║██╔════╝ ██╔══██╗██╔══██╗██╔════╝██║  ██║╚██╗ ██╔╝",
    "██║   ██║██║     ██║██║  ███╗███████║██████╔╝██║     ███████║ ╚████╔╝ ",
    "██║   ██║██║     ██║██║   ██║██╔══██║██╔══██╗██║     ██╔══██║  ╚██╔╝  ",
    "╚██████╔╝███████╗██║╚██████╔╝██║  ██║██║  ██║╚██████╗██║  ██║   ██║   ",
    " ╚═════╝ ╚══════╝╚═╝ ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝   ╚═╝   ",
];

const WORDMARK_W: usize = 70;
const SUBTITLE: &str = "// THE WAR MACHINE — WAR ROOM";

pub fn render(f: &mut Frame, area: Rect, app: &App) {
    draw(f, area, &app.skin, &app.panels);
}

/// Reachable without an `App` so the splash can be rendered into a
/// `TestBackend` at 80x24 and at the sizes where it has to degrade.
pub(super) fn draw(f: &mut Frame, area: Rect, s: &Skin, panels: &[PanelState]) {
    if area.width == 0 || area.height == 0 {
        return;
    }

    // Below the block-letter wordmark's footprint we drop to the plain
    // spaced-out wordmark rather than clipping glyphs into nonsense.
    let big = area.width as usize >= WORDMARK_W + 4 && area.height >= 20;

    let mut lines: Vec<Line> = Vec::new();
    if big {
        for art in WORDMARK.iter() {
            lines.push(gradient_line(s, art));
        }
    } else {
        lines.push(plain_wordmark(s));
    }

    lines.push(Line::from(""));
    lines.push(Line::from(Span::styled(
        SUBTITLE,
        Style::default().fg(s.text_dim()).add_modifier(Modifier::BOLD),
    )));

    // The roster. Every line is padded to one common width so that centering
    // each of them independently still yields a flush left edge.
    let reported = panels
        .iter()
        .filter(|p| p.panel.is_some() || !matches!(p.freshness, Freshness::Stale(_)))
        .count();
    let roster = roster(s, panels, area.width as usize);

    if area.height as usize > lines.len() + roster.len() + 3 {
        lines.push(Line::from(""));
        lines.push(Line::from(vec![
            Span::styled("▎", Style::default().fg(s.accent())),
            Span::styled(
                "BOOT ROSTER  ",
                Style::default().fg(s.accent()).add_modifier(Modifier::BOLD),
            ),
            Span::styled(
                format!("{reported}/{}", panels.len()),
                Style::default().fg(s.text_dim()),
            ),
        ]));
    }
    lines.extend(roster);

    if area.height as usize > lines.len() + 2 {
        lines.push(Line::from(""));
        lines.push(Line::from(Span::styled(
            "standby — any key to skip",
            Style::default().fg(widgets::chrome(s)),
        )));
    }

    lines.truncate(area.height as usize);

    // Vertically centered, biased slightly high: a block that sits dead-center
    // in a tall terminal reads as floating.
    let top = (area.height as usize)
        .saturating_sub(lines.len())
        .saturating_mul(2)
        / 5;
    let rect = Rect {
        x: area.x,
        y: area.y + top as u16,
        width: area.width,
        height: area.height - top as u16,
    };
    f.render_widget(Paragraph::new(lines).alignment(Alignment::Center), rect);
}

/// One wordmark row, colored per column across the full width of the mark.
fn gradient_line(s: &Skin, art: &str) -> Line<'static> {
    let chars: Vec<char> = art.chars().collect();
    let n = chars.len().max(1);

    // Runs are merged on the *resolved* color, not the interpolated RGB: in
    // `Ansi16` the seventy steps quantize down to a handful, and emitting
    // seventy identical single-cell spans per row six times a frame is waste
    // for a screen that exists to look effortless.
    let mut spans: Vec<Span<'static>> = Vec::new();
    let mut run = String::new();
    let mut run_color: Option<Color> = None;

    for (i, ch) in chars.iter().enumerate() {
        let t = i as f32 / (n - 1).max(1) as f32;
        let color = s.c(s.p.gradient_start.lerp(s.p.gradient_end, t));
        if run_color != Some(color) {
            if let Some(prev) = run_color {
                spans.push(Span::styled(
                    std::mem::take(&mut run),
                    Style::default().fg(prev).add_modifier(Modifier::BOLD),
                ));
            }
            run_color = Some(color);
        }
        run.push(*ch);
    }
    if let Some(prev) = run_color {
        spans.push(Span::styled(
            run,
            Style::default().fg(prev).add_modifier(Modifier::BOLD),
        ));
    }
    Line::from(spans)
}

/// The degraded wordmark for a terminal too small for the block letters. Same
/// gradient, one span per letter.
fn plain_wordmark(s: &Skin) -> Line<'static> {
    let text = "O L I G A R C H Y";
    let n = text.chars().count().max(1);
    let spans = text
        .chars()
        .enumerate()
        .map(|(i, ch)| {
            let t = i as f32 / (n - 1).max(1) as f32;
            let rgb = s.p.gradient_start.lerp(s.p.gradient_end, t);
            Span::styled(
                ch.to_string(),
                Style::default().fg(s.c(rgb)).add_modifier(Modifier::BOLD),
            )
        })
        .collect::<Vec<_>>();
    Line::from(spans)
}

/// `[ OK ] system`, `[ ·· ] mesh`, `[ -- ] forge  (not installed)`.
///
/// The mark is two characters of *text*, not a colored glyph: this is the first
/// thing the machine shows on a bare TTY, and on that TTY the colors are four
/// approximations of each other.
fn roster(s: &Skin, panels: &[PanelState], width: usize) -> Vec<Line<'static>> {
    let name_w = panels.iter().map(|p| p.id.chars().count()).max().unwrap_or(8);

    // Every roster line is padded to the same total width so that per-line
    // centering produces a left-aligned block.
    let detail_w = panels
        .iter()
        .map(|p| detail(p).chars().count())
        .max()
        .unwrap_or(0)
        .min(width.saturating_sub(name_w + 10));
    let total = 7 + name_w + if detail_w > 0 { detail_w + 2 } else { 0 };

    panels
        .iter()
        .map(|p| {
            let (mark, color) = match (&p.freshness, &p.panel) {
                (Freshness::Unavailable(_), _) => ("--", s.text_dim()),
                (Freshness::Failed(_), _) => ("!!", s.error()),
                (_, Some(_)) => ("OK", s.success()),
                _ => ("··", s.text_dim()),
            };
            let d = widgets::fit(&detail(p), detail_w);
            let mut spans = vec![
                Span::styled("[ ", Style::default().fg(widgets::chrome(s))),
                Span::styled(mark, Style::default().fg(color).add_modifier(Modifier::BOLD)),
                Span::styled(" ] ", Style::default().fg(widgets::chrome(s))),
                Span::styled(
                    format!("{:<name_w$}", p.id),
                    Style::default().fg(if p.panel.is_some() { s.text() } else { s.text_dim() }),
                ),
            ];
            if detail_w > 0 {
                spans.push(Span::styled(
                    format!("  {d:<detail_w$}"),
                    Style::default().fg(s.text_dim()),
                ));
            }
            let l = Line::from(spans);
            debug_assert_eq!(widgets::line_width(&l), total, "ragged roster line");
            l
        })
        .collect()
}

/// The parenthesised reason a subsystem is not reporting, or empty.
fn detail(p: &PanelState) -> String {
    match &p.freshness {
        Freshness::Unavailable(why) => format!("({why})"),
        Freshness::Failed(err) => format!("({err})"),
        _ => String::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ratatui::backend::TestBackend;
    use ratatui::Terminal;
    use std::time::Duration;
    use warroom_core::model::{Health, Panel};

    fn skin() -> Skin {
        Skin::new(warroom_core::theme::DEMOD)
    }

    fn st(id: &'static str, title: &'static str, fr: Freshness, ok: bool) -> PanelState {
        let mut s = PanelState::new(id, title);
        if ok {
            s.panel = Some(Panel::new(Health::Good, "up"));
        }
        s.freshness = fr;
        s
    }

    /// Mid-boot: three in, one failed, one missing, two still going.
    fn booting() -> Vec<PanelState> {
        vec![
            st("system", "SITREP", Freshness::Fresh, true),
            st("dsp", "DSP", Freshness::Fresh, true),
            st("mesh", "MESH", Freshness::Stale(Duration::ZERO), false),
            st("security", "PERIMETER", Freshness::Fresh, true),
            st("net", "NET", Freshness::Failed("nft exit 1".into()), false),
            st("ai", "AI", Freshness::Stale(Duration::ZERO), false),
            st(
                "forge",
                "FORGE",
                Freshness::Unavailable("not installed"),
                false,
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
            for (w, h) in [(140u16, 45u16), (80, 24), (74, 22), (60, 18), (40, 12)] {
                println!("\n===== SPLASH {w}x{h} =====");
                print!("{}", text(w, h, &booting()));
            }
        }
    }

    #[test]
    fn wordmark_rows_are_rectangular() {
        for (i, row) in WORDMARK.iter().enumerate() {
            assert_eq!(row.chars().count(), WORDMARK_W, "row {i} is the odd one out");
        }
    }

    #[test]
    fn the_block_letters_survive_eighty_columns() {
        // 80x24 is the floor this splash promises to look correct at.
        assert!(WORDMARK_W + 4 <= 80);
        let out = text(80, 24, &booting());
        assert!(out.contains("██████╗"), "block letters missing at 80x24");
        assert!(out.contains("THE WAR MACHINE"));
        // Nothing may spill past column 80 into a wrapped row.
        for l in out.lines() {
            assert!(l.chars().count() <= 80);
        }
    }

    #[test]
    fn a_small_terminal_gets_the_plain_wordmark_not_a_clipped_one() {
        let out = text(60, 18, &booting());
        assert!(!out.contains("██████╗"), "block letters clipped instead of dropped");
        assert!(out.contains("O L I G A R C H Y"));
    }

    #[test]
    fn the_roster_reports_every_collector_and_why() {
        let out = text(140, 45, &booting());
        for id in ["system", "dsp", "mesh", "security", "net", "ai", "forge"] {
            assert!(out.contains(id), "{id} missing from the boot roster");
        }
        assert!(out.contains("[ OK ]"));
        assert!(out.contains("[ ·· ]"));
        assert!(out.contains("[ !! ]"));
        assert!(out.contains("[ -- ]"));
        assert!(out.contains("(not installed)"), "no reason for the missing one");
        assert!(out.contains("(nft exit 1)"), "no reason for the failed one");
        // The roster is a progress readout, so it says how far along it is.
        assert!(out.contains("5/7"), "no progress count");
    }

    #[test]
    fn the_gradient_actually_sweeps() {
        use warroom_core::theme::{ColorMode, DEMOD};
        // On truecolor the sweep is nearly per-column; on a bare TTY it
        // collapses to a handful of ANSI steps. Both must still *sweep* —
        // a wordmark rendered in one flat color is the failure mode here, and
        // it is invisible unless something checks.
        for mode in [ColorMode::TrueColor, ColorMode::Ansi16] {
            let s = Skin { p: DEMOD, mode };
            let l = gradient_line(&s, WORDMARK[0]);
            assert!(l.spans.len() >= 2, "{mode:?}: gradient collapsed flat");
            assert_ne!(
                l.spans.first().unwrap().style.fg,
                l.spans.last().unwrap().style.fg,
                "{mode:?}: both ends of the sweep are the same color"
            );
            let text: String = l.spans.iter().map(|sp| sp.content.to_string()).collect();
            assert_eq!(text.chars().count(), WORDMARK_W, "{mode:?}: glyphs lost");
        }
        // Truecolor really does get a fine sweep, not two blocks.
        let s = Skin { p: DEMOD, mode: ColorMode::TrueColor };
        assert!(gradient_line(&s, WORDMARK[0]).spans.len() > 20);
    }

    #[test]
    fn renders_at_every_size_without_panicking() {
        let empty: Vec<PanelState> = Vec::new();
        for w in [1u16, 4, 12, 30, 40, 60, 74, 80, 100, 140, 240] {
            for h in [1u16, 2, 5, 9, 12, 18, 20, 24, 45, 70] {
                text(w, h, &booting());
                text(w, h, &empty);
            }
        }
    }
}
