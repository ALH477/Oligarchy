//! MESH pane.
//!
//! OWNER: work stream S3. Minimal-but-working: it renders the generic panel.
//! S3: node status rows plus the peer table.

use super::widgets;
use crate::app::{Action, App};
use crossterm::event::KeyEvent;
use ratatui::layout::Rect;
use ratatui::Frame;

#[derive(Debug, Default)]
pub struct State {
    /// Scroll offset, for panes whose content outgrows the viewport.
    pub scroll: u16,
}

pub fn render(f: &mut Frame, area: Rect, app: &mut App) {
    if let Some(st) = app.panel("mesh") {
        widgets::panel(f, area, &app.skin, st, true);
    }
}

pub fn on_key(_st: &mut State, _k: KeyEvent) -> Option<Action> {
    None
}
