//! DSP pane.
//!
//! OWNER: work stream S3. Minimal-but-working: it renders the generic panel.
//! `D` hands off to the real dsp-ctl; this pane is summary only.
//! S3: gauges (dsp-ctl's own green<50/yellow<80/red>=80 thresholds), latency
//! budget, xrun counters.

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
    if let Some(st) = app.panel("dsp") {
        widgets::panel(f, area, &app.skin, st, true);
    }
}

pub fn on_key(_st: &mut State, _k: KeyEvent) -> Option<Action> {
    None
}
