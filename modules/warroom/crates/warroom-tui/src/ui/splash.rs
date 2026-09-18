//! The one ASCII moment.
//!
//! OWNER: work stream S2. This placeholder draws the wordmark and the boot
//! roster; S2 replaces the wordmark with real block letters and applies the
//! per-column turquoise→violet gradient (interpolate `p.gradient_start` →
//! `p.gradient_end` across glyph columns via `Rgb::lerp`, one `Span` per
//! column).
//!
//! The splash earns its place by doing real work: it IS the first collection
//! pass, and the roster below fills in live as each collector reports.

use crate::app::App;
use ratatui::layout::{Alignment, Constraint, Direction, Layout, Rect};
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;
use ratatui::Frame;
use warroom_core::model::Freshness;

pub fn render(f: &mut Frame, area: Rect, app: &App) {
    let s = &app.skin;

    let rows = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Percentage(30),
            Constraint::Length(3),
            Constraint::Length(2),
            Constraint::Min(0),
        ])
        .split(area);

    // TODO(S2): block-letter OLIGARCHY with a per-column gradient.
    let word: Vec<Span> = {
        let text = "O L I G A R C H Y";
        let n = text.chars().count().max(1);
        text.chars()
            .enumerate()
            .map(|(i, ch)| {
                let t = i as f32 / (n - 1).max(1) as f32;
                let rgb = s.p.gradient_start.lerp(s.p.gradient_end, t);
                Span::styled(
                    ch.to_string(),
                    Style::default().fg(s.c(rgb)).add_modifier(Modifier::BOLD),
                )
            })
            .collect()
    };
    f.render_widget(
        Paragraph::new(Line::from(word)).alignment(Alignment::Center),
        rows[1],
    );

    f.render_widget(
        Paragraph::new(Line::from(Span::styled(
            "// THE WAR MACHINE — WAR ROOM",
            Style::default().fg(s.text_dim()),
        )))
        .alignment(Alignment::Center),
        rows[2],
    );

    let roster: Vec<Line> = app
        .panels
        .iter()
        .map(|p| {
            let (mark, color) = match (&p.freshness, &p.panel) {
                (Freshness::Unavailable(_), _) => ("--", s.text_dim()),
                (Freshness::Failed(_), _) => ("!!", s.error()),
                (_, Some(_)) => ("OK", s.success()),
                _ => ("··", s.text_dim()),
            };
            Line::from(vec![
                Span::styled("[ ", Style::default().fg(s.border())),
                Span::styled(mark, Style::default().fg(color)),
                Span::styled(" ] ", Style::default().fg(s.border())),
                Span::styled(
                    p.title.to_lowercase(),
                    Style::default().fg(s.text_dim()),
                ),
            ])
        })
        .collect();
    f.render_widget(Paragraph::new(roster).alignment(Alignment::Center), rows[3]);
}
