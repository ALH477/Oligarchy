//! TRAFFIC — journal tail plus the output of the last action.
//!
//! OWNER: work stream S4. `push()` is already wired into the app's action
//! dispatch, so it must keep its signature.
//!
//! S4 adds: a rolling `journalctl -n --no-pager -u <unit>` tail over a curated
//! unit set, and scrollback. This pane is what gives actions the feedback the
//! fzf front-ends never had.

use super::widgets;
use crate::app::{Action, App};
use crossterm::event::{KeyCode, KeyEvent};
use ratatui::layout::Rect;
use ratatui::style::Style;
use ratatui::text::{Line, Span};
use ratatui::widgets::{Paragraph, Wrap};
use ratatui::Frame;

/// Keeps the pane bounded; a runaway action must not grow memory forever.
const MAX_LINES: usize = 2000;

#[derive(Debug, Default)]
pub struct State {
    pub lines: Vec<String>,
    pub scroll: u16,
}

/// Append output. Called from the app's action dispatch.
pub fn push(st: &mut State, text: &str) {
    for l in text.lines() {
        st.lines.push(l.to_string());
    }
    if st.lines.len() > MAX_LINES {
        let cut = st.lines.len() - MAX_LINES;
        st.lines.drain(0..cut);
    }
}

pub fn render(f: &mut Frame, area: Rect, app: &mut App) {
    let s = &app.skin;
    let blk = widgets::block(s, "TRAFFIC", true);
    let inner = blk.inner(area);
    f.render_widget(blk, area);

    if app.traffic.lines.is_empty() {
        return f.render_widget(
            Paragraph::new(Line::from(Span::styled(
                "NO TRAFFIC",
                Style::default().fg(s.text_dim()),
            ))),
            inner,
        );
    }

    let lines: Vec<Line> = app
        .traffic
        .lines
        .iter()
        .map(|l| Line::from(Span::styled(l.clone(), Style::default().fg(s.text()))))
        .collect();
    f.render_widget(
        Paragraph::new(lines)
            .scroll((app.traffic.scroll, 0))
            .wrap(Wrap { trim: false }),
        inner,
    );
}

pub fn on_key(st: &mut State, k: KeyEvent) -> Option<Action> {
    match k.code {
        KeyCode::Char('j') | KeyCode::Down => st.scroll = st.scroll.saturating_add(1),
        KeyCode::Char('k') | KeyCode::Up => st.scroll = st.scroll.saturating_sub(1),
        KeyCode::Home => st.scroll = 0,
        _ => {}
    }
    None
}
