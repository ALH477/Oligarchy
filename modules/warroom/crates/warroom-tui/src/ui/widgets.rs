//! Shared widget vocabulary.
//!
//! OWNER: work stream S2. These bodies are deliberately minimal-but-working so
//! the S0 skeleton runs; S2 refines them. The SIGNATURES are frozen — S3 and S4
//! code against them, so changing one breaks two other streams.
//!
//! `panel()` is the load-bearing one: it renders ANY `PanelState` with no new
//! UI code, which is what makes adding a subsystem a one-file change.

use super::Skin;
use ratatui::layout::{Alignment, Constraint, Direction, Layout, Rect};
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, BorderType, Borders, Gauge, Paragraph, Row, Table, Wrap};
use ratatui::Frame;
use warroom_core::model::{Freshness, Health, PanelState};

/// A bordered pane. Focused panes take the accent border.
pub fn block(s: &Skin, title: &str, focused: bool) -> Block<'static> {
    let border = if focused { s.border_focus() } else { s.border() };
    Block::default()
        .borders(Borders::ALL)
        .border_type(BorderType::Plain)
        .border_style(Style::default().fg(border))
        .title(Line::from(vec![
            Span::styled(" ▎", Style::default().fg(s.accent())),
            Span::styled(
                format!("{title} "),
                Style::default().fg(s.accent()).add_modifier(Modifier::BOLD),
            ),
        ]))
}

/// A horizontal rule in dsp-ctl's idiom.
pub fn rule(s: &Skin, width: usize) -> Line<'static> {
    Line::from(Span::styled(
        "━".repeat(width),
        Style::default().fg(s.border()),
    ))
}

/// The health dot. ALWAYS emitted next to `Health::label()` text — a glyph that
/// carries meaning only in its color is unreadable to a chunk of users and
/// invisible in a no-color terminal.
pub fn dot(s: &Skin, h: Health) -> Span<'static> {
    Span::styled("●", Style::default().fg(s.health(h)))
}

/// `LABEL:              value  ● OK`
pub fn stat(s: &Skin, label: &str, value: &str, h: Health, width: usize) -> Line<'static> {
    let label = format!("{}:", label.to_uppercase());
    let tail = format!("{value} ");
    let pad = width.saturating_sub(label.len() + tail.len() + 4);
    Line::from(vec![
        Span::styled(label, Style::default().fg(s.text_dim())),
        Span::raw(" ".repeat(pad.max(1))),
        Span::styled(tail, Style::default().fg(s.text())),
        dot(s, h),
        Span::styled(
            format!(" {}", h.label()),
            Style::default().fg(s.health(h)),
        ),
    ])
}

/// dsp-ctl's thresholds, kept identical on purpose: two gauges in one distro
/// that disagree about what 70% means is worse than either choice.
pub fn gauge(s: &Skin, label: &str, pct: u16) -> Gauge<'static> {
    let pct = pct.min(100);
    let color = if pct < 50 {
        s.success()
    } else if pct < 80 {
        s.warning()
    } else {
        s.error()
    };
    Gauge::default()
        .block(Block::default().title(Span::styled(
            label.to_string(),
            Style::default().fg(s.text_dim()),
        )))
        .gauge_style(Style::default().fg(color).bg(s.surface()))
        .percent(pct)
}

/// How much the pane's data can be trusted, rendered so it cannot be mistaken
/// for fresh data.
pub fn freshness_span(s: &Skin, f: &Freshness) -> Span<'static> {
    match f {
        Freshness::Fresh => Span::styled("live", Style::default().fg(s.text_dim())),
        Freshness::Stale(d) => Span::styled(
            format!("stale {}", human_age(*d)),
            Style::default().fg(s.warning()),
        ),
        Freshness::Failed(_) => Span::styled("FAILED", Style::default().fg(s.error())),
        Freshness::Unavailable(_) => Span::styled("offline", Style::default().fg(s.text_dim())),
    }
}

pub fn human_age(d: std::time::Duration) -> String {
    let secs = d.as_secs();
    if secs < 60 {
        format!("{secs}s")
    } else if secs < 3600 {
        format!("{}m{:02}s", secs / 60, secs % 60)
    } else {
        format!("{}h{:02}m", secs / 3600, (secs % 3600) / 60)
    }
}

/// Render any `PanelState` — rows, optional table, freshness, and the
/// unavailable/failed states, in one place.
pub fn panel(f: &mut Frame, area: Rect, s: &Skin, st: &PanelState, focused: bool) {
    let blk = block(s, st.title, focused);
    let inner = blk.inner(area);
    f.render_widget(blk, area);

    // Dead states get one honest line instead of a stale-looking body.
    match &st.freshness {
        Freshness::Unavailable(why) => {
            return f.render_widget(
                Paragraph::new(vec![
                    Line::from(Span::styled(
                        "SUBSYSTEM OFFLINE",
                        Style::default().fg(s.text_dim()).add_modifier(Modifier::BOLD),
                    )),
                    Line::from(Span::styled(
                        (*why).to_string(),
                        Style::default().fg(s.text_dim()),
                    )),
                ])
                .wrap(Wrap { trim: true }),
                inner,
            );
        }
        Freshness::Failed(err) if st.panel.is_none() => {
            return f.render_widget(
                Paragraph::new(vec![
                    Line::from(Span::styled(
                        "NO CONTACT",
                        Style::default().fg(s.error()).add_modifier(Modifier::BOLD),
                    )),
                    Line::from(Span::styled(err.clone(), Style::default().fg(s.text_dim()))),
                ])
                .wrap(Wrap { trim: true }),
                inner,
            );
        }
        _ => {}
    }

    let Some(p) = &st.panel else {
        return f.render_widget(
            Paragraph::new(Span::styled("NO CONTACT", Style::default().fg(s.text_dim()))),
            inner,
        );
    };

    // Stale data is dimmed wholesale: a stale green dot is worse than no dot.
    let stale = !matches!(st.freshness, Freshness::Fresh);
    let value_color = if stale { s.text_dim() } else { s.text() };

    let w = inner.width as usize;
    let mut lines: Vec<Line> = Vec::new();
    lines.push(Line::from(vec![
        dot(s, p.health),
        Span::styled(format!(" {}", p.summary), Style::default().fg(value_color)),
        Span::raw("  "),
        freshness_span(s, &st.freshness),
    ]));
    lines.push(rule(s, w));
    for r in &p.rows {
        let h = if stale { Health::Unknown } else { r.health };
        lines.push(stat(s, &r.label, &r.value, h, w));
    }

    let table_rows = p.table.as_ref().map(|t| t.rows.len()).unwrap_or(0);
    if table_rows == 0 {
        return f.render_widget(Paragraph::new(lines), inner);
    }

    let split = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(lines.len() as u16),
            Constraint::Min(0),
        ])
        .split(inner);
    f.render_widget(Paragraph::new(lines), split[0]);

    let t = p.table.as_ref().unwrap();
    let ncols = t.headers.len().max(1);
    let widths: Vec<Constraint> =
        (0..ncols).map(|_| Constraint::Percentage((100 / ncols) as u16)).collect();
    let header = Row::new(t.headers.clone()).style(
        Style::default().fg(s.accent()).add_modifier(Modifier::BOLD),
    );
    let rows: Vec<Row> = t
        .rows
        .iter()
        .map(|r| Row::new(r.clone()).style(Style::default().fg(value_color)))
        .collect();
    f.render_widget(Table::new(rows, widths).header(header), split[1]);
}

/// SITREP rollup card: one subsystem reduced to a dot, a name, and one line.
pub fn card(f: &mut Frame, area: Rect, s: &Skin, st: &PanelState) {
    let blk = block(s, st.title, false);
    let inner = blk.inner(area);
    f.render_widget(blk, area);
    let h = st.health();
    let lines = vec![
        Line::from(vec![
            dot(s, h),
            Span::styled(
                format!(" {}", h.label()),
                Style::default().fg(s.health(h)).add_modifier(Modifier::BOLD),
            ),
            Span::raw("  "),
            freshness_span(s, &st.freshness),
        ]),
        Line::from(Span::styled(st.summary(), Style::default().fg(s.text_dim()))),
    ];
    f.render_widget(
        Paragraph::new(lines).alignment(Alignment::Left).wrap(Wrap { trim: true }),
        inner,
    );
}
