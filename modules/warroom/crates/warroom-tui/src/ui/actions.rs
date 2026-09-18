//! ORDNANCE — the action catalog.
//!
//! OWNER: work stream S4. Minimal-but-working placeholder.
//!
//! S4 builds: two columns (categories left, items right), `/` opening a flat
//! fuzzy filter over `Catalog::flat()` (a ~40-line subsequence+bonus matcher —
//! no fzf dependency), `Enter` emitting `Action::RunAction`, and
//! `warroom_core::actions::is_destructive` wrapping that in `Action::Confirm`.
//!
//! The confirm modal is not decoration: this pane can restart the mesh node and
//! switch kernels.

use super::widgets;
use crate::app::{Action, App};
use crossterm::event::KeyEvent;
use ratatui::layout::Rect;
use ratatui::style::Style;
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;
use ratatui::Frame;
use warroom_core::actions::Catalog;

#[derive(Debug, Default)]
pub struct State {
    pub catalog: Option<Catalog>,
    pub error: Option<String>,
    pub cat_idx: usize,
    pub item_idx: usize,
    /// `Some` while the `/` filter is open.
    pub filter: Option<String>,
}

pub fn render(f: &mut Frame, area: Rect, app: &mut App) {
    let s = &app.skin;
    let blk = widgets::block(s, "ORDNANCE", true);
    let inner = blk.inner(area);
    f.render_widget(blk, area);

    let msg = match (&app.ordnance.catalog, &app.ordnance.error) {
        (Some(_), _) => "catalog loaded",
        (None, Some(e)) => e.as_str(),
        (None, None) => "action catalog not wired yet (work stream S4)",
    };
    f.render_widget(
        Paragraph::new(Line::from(Span::styled(
            msg.to_string(),
            Style::default().fg(s.text_dim()),
        ))),
        inner,
    );
}

pub fn on_key(_st: &mut State, _k: KeyEvent) -> Option<Action> {
    None
}
