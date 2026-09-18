//! SITREP — the one screen that answers "is my machine healthy".
//!
//! OWNER: work stream S2. Minimal-but-working; S2 makes it good (load/memory
//! gauges, temp, battery, a properly balanced rollup grid).

use super::{widgets, Skin};
use crate::app::App;
use ratatui::layout::{Constraint, Direction, Layout, Rect};
use ratatui::Frame;
use warroom_core::model::PanelState;

/// Subsystems that get a rollup card, in grid order.
const CARDS: [&str; 6] = ["dsp", "mesh", "security", "net", "ai", "forge"];

pub fn render(f: &mut Frame, area: Rect, app: &mut App) {
    let rows = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Length(9), Constraint::Min(0)])
        .split(area);

    if let Some(system) = app.panel("system") {
        widgets::panel(f, rows[0], &app.skin, system, true);
    }

    grid(f, rows[1], &app.skin, app);
}

fn grid(f: &mut Frame, area: Rect, skin: &Skin, app: &App) {
    let halves = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Percentage(50), Constraint::Percentage(50)])
        .split(area);

    for (row, chunk) in halves.iter().enumerate() {
        let cols = Layout::default()
            .direction(Direction::Horizontal)
            .constraints([
                Constraint::Percentage(34),
                Constraint::Percentage(33),
                Constraint::Percentage(33),
            ])
            .split(*chunk);
        for (col, cell) in cols.iter().enumerate() {
            let Some(id) = CARDS.get(row * 3 + col) else { continue };
            match app.panel(id) {
                Some(st) => widgets::card(f, *cell, skin, st),
                None => {
                    let missing = PanelState::new("", id);
                    widgets::card(f, *cell, skin, &missing);
                }
            }
        }
    }
}
