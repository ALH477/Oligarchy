//! Frame layout, chrome, and the palette-to-ratatui adapter.
//!
//! OWNER: work stream S0 (frozen). `Skin` is the contract every UI stream uses
//! to get a color; no stream should construct `Color` from a hex literal.

pub mod actions;
pub mod dsp;
pub mod logs;
pub mod mesh;
pub mod overview;
pub mod security;
pub mod splash;
pub mod widgets;

use crate::app::{App, Tab};
use ratatui::layout::{Alignment, Constraint, Direction, Layout, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Clear, Paragraph, Wrap};
use ratatui::Frame;
use warroom_core::model::Health;
use warroom_core::theme::{ColorMode, Palette, Rgb};

/// A palette bound to a terminal's actual color capability.
pub struct Skin {
    pub p: Palette,
    pub mode: ColorMode,
}

impl Skin {
    pub fn new(p: Palette) -> Self {
        Skin { p, mode: warroom_core::theme::color_mode() }
    }

    /// The single place an `Rgb` becomes a ratatui `Color`.
    pub fn c(&self, rgb: Rgb) -> Color {
        match self.mode {
            ColorMode::TrueColor => Color::Rgb(rgb.0, rgb.1, rgb.2),
            ColorMode::Ansi16 => Color::Indexed(rgb.nearest_ansi()),
        }
    }

    pub fn bg(&self) -> Color { self.c(self.p.bg) }
    pub fn surface(&self) -> Color { self.c(self.p.surface) }
    pub fn overlay(&self) -> Color { self.c(self.p.overlay) }
    pub fn border(&self) -> Color { self.c(self.p.border) }
    pub fn border_focus(&self) -> Color { self.c(self.p.border_focus) }
    pub fn accent(&self) -> Color { self.c(self.p.accent) }
    pub fn accent_dim(&self) -> Color { self.c(self.p.accent_dim) }
    pub fn text(&self) -> Color { self.c(self.p.text) }
    pub fn text_dim(&self) -> Color { self.c(self.p.text_dim) }
    pub fn success(&self) -> Color { self.c(self.p.success) }
    pub fn warning(&self) -> Color { self.c(self.p.warning) }
    pub fn error(&self) -> Color { self.c(self.p.error) }
    pub fn purple(&self) -> Color { self.c(self.p.purple) }

    /// Health color. Always pair with `Health::label()` — never color alone.
    pub fn health(&self, h: Health) -> Color {
        match h {
            Health::Good => self.success(),
            Health::Warn => self.warning(),
            Health::Bad => self.error(),
            Health::Unknown => self.text_dim(),
        }
    }
}

pub fn render(f: &mut Frame, app: &mut App) {
    let area = f.area();
    f.render_widget(Block::default().style(Style::default().bg(app.skin.bg())), area);

    if !app.splash_done {
        splash::render(f, area, app);
        return;
    }

    let rows = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Length(1), Constraint::Min(0), Constraint::Length(1)])
        .split(area);

    header(f, rows[0], app);
    body(f, rows[1], app);
    footer(f, rows[2], app);

    if app.help {
        help_overlay(f, area, app);
    }
    if let Some(c) = &app.confirm {
        confirm_overlay(f, area, &app.skin, &c.title, &c.body);
    }
}

fn header(f: &mut Frame, area: Rect, app: &App) {
    let s = &app.skin;
    let cols = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([Constraint::Length(24), Constraint::Min(0), Constraint::Length(10)])
        .split(area);

    let brand = Line::from(vec![
        Span::styled("OLIGARCHY", Style::default().fg(s.accent()).add_modifier(Modifier::BOLD)),
        Span::styled(" // ", Style::default().fg(s.text_dim())),
        Span::styled("WAR ROOM", Style::default().fg(s.purple()).add_modifier(Modifier::BOLD)),
    ]);
    f.render_widget(
        Paragraph::new(brand).style(Style::default().bg(s.surface())),
        cols[0],
    );

    let mut tabs: Vec<Span> = Vec::new();
    for (i, t) in Tab::ALL.iter().enumerate() {
        if i > 0 {
            tabs.push(Span::styled("  ", Style::default().bg(s.surface())));
        }
        let style = if *t == app.tab {
            Style::default().fg(s.accent()).bg(s.surface()).add_modifier(Modifier::BOLD)
        } else {
            Style::default().fg(s.text_dim()).bg(s.surface())
        };
        tabs.push(Span::styled(format!(" {} {} ", i + 1, t.title()), style));
    }
    f.render_widget(
        Paragraph::new(Line::from(tabs)).style(Style::default().bg(s.surface())),
        cols[1],
    );

    f.render_widget(
        Paragraph::new(Line::from(Span::styled(
            app.host.clone(),
            Style::default().fg(s.text_dim()),
        )))
        .alignment(Alignment::Right)
        .style(Style::default().bg(s.surface())),
        cols[2],
    );
}

fn body(f: &mut Frame, area: Rect, app: &mut App) {
    match app.tab {
        Tab::Sitrep => overview::render(f, area, app),
        Tab::Dsp => dsp::render(f, area, app),
        Tab::Mesh => mesh::render(f, area, app),
        Tab::Perimeter => security::render(f, area, app),
        Tab::Ordnance => actions::render(f, area, app),
        Tab::Traffic => logs::render(f, area, app),
    }
}

fn footer(f: &mut Frame, area: Rect, app: &App) {
    let s = &app.skin;
    let mut spans = Vec::new();
    let key = |k: &str, desc: &str, spans: &mut Vec<Span<'static>>| {
        spans.push(Span::styled(
            format!(" {k} "),
            Style::default().fg(s.accent()).bg(s.surface()).add_modifier(Modifier::BOLD),
        ));
        spans.push(Span::styled(
            format!("{desc}  "),
            Style::default().fg(s.text_dim()).bg(s.surface()),
        ));
    };
    key("1-6/tab", "pane", &mut spans);
    key("r", "refresh", &mut spans);
    key("t", "theme", &mut spans);
    key("?", "help", &mut spans);
    key("q", "stand down", &mut spans);
    for extra in app.tab_hints() {
        key(extra.0, extra.1, &mut spans);
    }
    f.render_widget(
        Paragraph::new(Line::from(spans)).style(Style::default().bg(s.surface())),
        area,
    );
}

fn centered(area: Rect, w: u16, h: u16) -> Rect {
    let w = w.min(area.width);
    let h = h.min(area.height);
    Rect {
        x: area.x + (area.width.saturating_sub(w)) / 2,
        y: area.y + (area.height.saturating_sub(h)) / 2,
        width: w,
        height: h,
    }
}

fn help_overlay(f: &mut Frame, area: Rect, app: &App) {
    let s = &app.skin;
    let lines = vec![
        Line::from(Span::styled("PANES", Style::default().fg(s.accent()).add_modifier(Modifier::BOLD))),
        Line::from("  1-6 / Tab / Shift-Tab   select pane"),
        Line::from(""),
        Line::from(Span::styled("GLOBAL", Style::default().fg(s.accent()).add_modifier(Modifier::BOLD))),
        Line::from("  r   refresh every collector now"),
        Line::from("  t   cycle theme"),
        Line::from("  D   hand off to dsp-ctl"),
        Line::from("  F   hand off to oligarchy-forge"),
        Line::from("  ?   this help"),
        Line::from("  q   stand down"),
        Line::from(""),
        Line::from(Span::styled("ORDNANCE", Style::default().fg(s.accent()).add_modifier(Modifier::BOLD))),
        Line::from("  j/k arrows  navigate     /  fuzzy filter"),
        Line::from("  Enter       run action   Esc clear filter"),
    ];
    let rect = centered(area, 58, lines.len() as u16 + 2);
    f.render_widget(Clear, rect);
    f.render_widget(
        Paragraph::new(lines)
            .block(widgets::block(s, "HELP", true))
            .style(Style::default().bg(s.overlay()).fg(s.text()))
            .wrap(Wrap { trim: false }),
        rect,
    );
}

fn confirm_overlay(f: &mut Frame, area: Rect, s: &Skin, title: &str, body: &str) {
    let rect = centered(area, 60, 7);
    f.render_widget(Clear, rect);
    let lines = vec![
        Line::from(""),
        Line::from(Span::styled(body.to_string(), Style::default().fg(s.text()))),
        Line::from(""),
        Line::from(vec![
            Span::styled("  [y] ", Style::default().fg(s.error()).add_modifier(Modifier::BOLD)),
            Span::styled("confirm    ", Style::default().fg(s.text_dim())),
            Span::styled("[n/Esc] ", Style::default().fg(s.accent()).add_modifier(Modifier::BOLD)),
            Span::styled("abort", Style::default().fg(s.text_dim())),
        ]),
    ];
    f.render_widget(
        Paragraph::new(lines)
            .block(widgets::block(s, title, true))
            .style(Style::default().bg(s.overlay()))
            .wrap(Wrap { trim: false }),
        rect,
    );
}
