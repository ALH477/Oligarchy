//! MESH pane — DCF / HydraMesh node status on top, the peer roll below.
//!
//! OWNER: work stream S3.
//!
//! The peer list is the part that has to survive reality: a node with nobody
//! on it and a node with fifty peers are both normal, and both have to be
//! readable. Hence a scrolling table with an explicit `n-m / total` counter
//! rather than a list that silently stops at the bottom of the block.
//!
//! Shared helpers (`header`, `stat_line`, `no_collector`, ...) live in
//! `ui::dsp`; see that module's header for why.

use super::dsp::{header, is_stale, no_collector, stat_line, window};
use super::widgets;
use super::Skin;
use crate::app::{Action, App};
use crossterm::event::{KeyCode, KeyEvent};
use ratatui::layout::{Constraint, Direction, Layout, Rect};
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Paragraph, Row as TRow, Table as TTable};
use ratatui::Frame;
use warroom_core::model::{PanelState, Table};

/// Rows of chrome the peer block spends on things that are not peers: the
/// column header, and the `n-m / total` counter under it.
const PEER_CHROME: u16 = 2;

/// A column never gets narrower than this or wider than that; a peer id that
/// eats the whole width hides the columns that say whether it is reachable.
const COL_MIN: usize = 4;
const COL_MAX: usize = 38;

#[derive(Debug, Default)]
pub struct State {
    /// First peer row on screen. Clamped in `render` against the real viewport,
    /// which is the only place that knows how tall the table ended up.
    pub scroll: u16,
}

pub fn render(f: &mut Frame, area: Rect, app: &mut App) {
    // Read what the clamp needs and let the borrow end before touching
    // `app.mesh`, which is a mutable field of the same struct.
    let (node_rows, peer_rows) = match app.panel("mesh").and_then(|s| s.panel.as_ref()) {
        Some(p) => (
            p.rows.len(),
            p.table.as_ref().map(|t| t.rows.len()).unwrap_or(0),
        ),
        None => (0, 0),
    };
    let viewport = peer_viewport(area, node_rows);
    let max = (peer_rows as u16).saturating_sub(viewport);
    app.mesh.scroll = app.mesh.scroll.min(max);
    let scroll = app.mesh.scroll;
    draw(f, area, &app.skin, app.panel("mesh"), scroll);
}

/// How the pane splits. Shared by `render` (to clamp the scroll) and `draw`
/// (to lay out), because a clamp computed against a different geometry than
/// the one drawn is a scroll offset that sticks one row from the end.
fn split(area: Rect, node_rows: usize) -> (Rect, Rect) {
    // Header + rule + node rows + borders, but never more than half the pane:
    // the peers are the part that grows.
    let want = (node_rows as u16).saturating_add(5);
    let top = want.min(area.height / 2).max(3);
    let v = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Length(top), Constraint::Min(3)])
        .split(area);
    (v[0], v[1])
}

fn peer_viewport(area: Rect, node_rows: usize) -> u16 {
    let (_, peers) = split(area, node_rows);
    peers.height.saturating_sub(2).saturating_sub(PEER_CHROME)
}

pub(super) fn draw(f: &mut Frame, area: Rect, s: &Skin, st: Option<&PanelState>, scroll: u16) {
    let Some(st) = st else {
        return no_collector(f, area, s, "MESH");
    };
    let Some(p) = st.panel.as_ref() else {
        return widgets::panel(f, area, s, st, true);
    };
    if area.width < 40 || area.height < 12 {
        return widgets::panel(f, area, s, st, true);
    }

    let stale = is_stale(&st.freshness);
    let (node_area, peer_area) = split(area, p.rows.len());

    // --- node -------------------------------------------------------------
    let blk = widgets::block(s, "NODE", true);
    let inner = blk.inner(node_area);
    f.render_widget(blk, node_area);
    let w = inner.width as usize;
    let mut lines = header(s, st);
    if !p.rows.is_empty() {
        lines.push(widgets::rule(s, w));
        for r in &p.rows {
            lines.push(stat_line(s, &r.label, &r.value, r.health, w, stale));
        }
    }
    // Node rows scroll with the peer list rather than on their own key: the
    // node block is at most half the pane and the marker says when it clipped.
    f.render_widget(
        Paragraph::new(window(s, lines, 0, inner.height as usize)),
        inner,
    );

    // --- peers ------------------------------------------------------------
    let empty = Table { headers: Vec::new(), rows: Vec::new() };
    let t = p.table.as_ref().unwrap_or(&empty);
    let total = t.rows.len();
    let blk = widgets::block(s, "PEERS", false);
    let inner = blk.inner(peer_area);
    f.render_widget(blk, peer_area);

    if total == 0 {
        // Zero peers is a fact, not an error: an isolated node is a normal
        // state of a mesh. Say it plainly instead of leaving an empty box that
        // reads like a pane that failed to draw.
        return f.render_widget(
            Paragraph::new(vec![
                Line::from(Span::styled(
                    "NO PEERS",
                    Style::default().fg(s.text_dim()).add_modifier(Modifier::BOLD),
                )),
                Line::from(Span::styled(
                    if p.table.is_some() {
                        "the node reported an empty peer list"
                    } else {
                        "the collector sent no peer list"
                    },
                    Style::default().fg(s.text_dim()),
                )),
            ]),
            inner,
        );
    }

    let rows = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Min(1), Constraint::Length(1)])
        .split(inner);
    let viewport = rows[0].height.saturating_sub(1).max(1) as usize; // minus the header row
    let first = (scroll as usize).min(total.saturating_sub(1));
    let last = (first + viewport).min(total);

    let ncols = t
        .headers
        .len()
        .max(t.rows.iter().map(|r| r.len()).max().unwrap_or(0))
        .max(1);
    let headers: Vec<String> = (0..ncols)
        .map(|i| t.headers.get(i).cloned().unwrap_or_default())
        .collect();
    let value_color = if stale { s.text_dim() } else { s.text() };
    let table = TTable::new(
        t.rows[first..last]
            .iter()
            .map(|r| TRow::new(r.clone()).style(Style::default().fg(value_color)))
            .collect::<Vec<_>>(),
        widths(&headers, &t.rows, ncols),
    )
    .header(
        TRow::new(headers).style(Style::default().fg(s.accent()).add_modifier(Modifier::BOLD)),
    );
    f.render_widget(table, rows[0]);

    let more = total > viewport;
    f.render_widget(
        Paragraph::new(Line::from(vec![
            Span::styled(
                format!("PEERS {}-{} / {}", first + 1, last, total),
                Style::default().fg(s.text_dim()),
            ),
            Span::styled(
                if more { "   j/k scroll  g/G top·end" } else { "" }.to_string(),
                Style::default().fg(s.accent_dim()),
            ),
            Span::styled(
                if stale { "   NOT LIVE" } else { "" }.to_string(),
                Style::default().fg(s.warning()).add_modifier(Modifier::BOLD),
            ),
        ])),
        rows[1],
    );
}

/// Size columns to their widest cell rather than splitting the width evenly:
/// a peer table is one long id and several short flags, and equal columns
/// truncate the flags to make room for whitespace.
fn widths(headers: &[String], rows: &[Vec<String>], ncols: usize) -> Vec<Constraint> {
    let mut w = vec![COL_MIN; ncols];
    for (i, h) in headers.iter().enumerate().take(ncols) {
        w[i] = w[i].max(h.chars().count());
    }
    for r in rows {
        for (i, c) in r.iter().enumerate().take(ncols) {
            w[i] = w[i].max(c.chars().count());
        }
    }
    w.iter()
        .map(|x| Constraint::Length((*x).min(COL_MAX) as u16 + 1))
        .collect()
}

pub fn on_key(st: &mut State, k: KeyEvent) -> Option<Action> {
    match k.code {
        KeyCode::Char('j') | KeyCode::Down => st.scroll = st.scroll.saturating_add(1),
        KeyCode::Char('k') | KeyCode::Up => st.scroll = st.scroll.saturating_sub(1),
        KeyCode::PageDown => st.scroll = st.scroll.saturating_add(10),
        KeyCode::PageUp => st.scroll = st.scroll.saturating_sub(10),
        KeyCode::Char('g') | KeyCode::Home => st.scroll = 0,
        // Clamped down to the real end by `render`, which knows the viewport.
        KeyCode::Char('G') | KeyCode::End => st.scroll = u16::MAX,
        _ => {}
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use crossterm::event::{KeyEvent, KeyModifiers};
    use ratatui::backend::TestBackend;
    use ratatui::Terminal;
    use std::time::Duration;
    use warroom_core::model::{Freshness, Health, Panel};

    fn skin() -> Skin {
        Skin::new(warroom_core::theme::DEMOD)
    }

    /// Stands in for work stream S1's collector, which does not exist yet.
    fn demo(peers: usize) -> Panel {
        let rows: Vec<Vec<String>> = (0..peers)
            .map(|i| {
                vec![
                    format!("node-{i:04x}-aaaabbbbccccddddeeeeffff"),
                    format!("10.42.0.{}", i % 255),
                    format!("{} ms", 3 + i),
                    if i % 4 == 0 { "direct" } else { "relay" }.to_string(),
                ]
            })
            .collect();
        Panel::new(Health::Good, format!("{peers} peers"))
            .row("Node", "oligarchy-fw16", Health::Good)
            .row("dcf-community-node", "active", Health::Good)
            .plain("Listen", "0.0.0.0:7777")
            .plain("Peers", peers.to_string())
            .table(
                vec!["PEER".into(), "ADDR".into(), "RTT".into(), "PATH".into()],
                rows,
            )
    }

    fn state(panel: Option<Panel>, f: Freshness) -> PanelState {
        let mut st = PanelState::new("mesh", "MESH");
        st.panel = panel;
        st.freshness = f;
        st
    }

    fn draw_at(w: u16, h: u16, st: Option<&PanelState>, scroll: u16) -> String {
        let mut term = Terminal::new(TestBackend::new(w, h)).unwrap();
        term.draw(|f| draw(f, f.area(), &skin(), st, scroll)).unwrap();
        term.backend()
            .buffer()
            .content()
            .iter()
            .map(|c| c.symbol())
            .collect()
    }

    #[test]
    fn renders_every_peer_count_and_freshness_without_panicking() {
        for peers in [0, 1, 3, 50, 500] {
            let states = [
                state(Some(demo(peers)), Freshness::Fresh),
                state(Some(demo(peers)), Freshness::Stale(Duration::from_secs(400))),
                state(Some(demo(peers)), Freshness::Failed("dcf exit 1".into())),
                state(None, Freshness::Failed("dcf exit 1".into())),
                state(None, Freshness::Unavailable("dcf not installed")),
                state(Some(Panel::new(Health::Unknown, "")), Freshness::Fresh),
            ];
            for st in &states {
                for (w, h) in [(140, 45), (80, 24), (40, 12), (30, 8), (6, 2)] {
                    // Scroll far past the end too: clamping lives in `render`,
                    // so `draw` must cope with a bogus offset on its own.
                    for scroll in [0, 7, u16::MAX] {
                        draw_at(w, h, Some(st), scroll);
                    }
                }
            }
        }
        draw_at(140, 45, None, 0);
    }

    #[test]
    fn empty_peer_list_says_so() {
        let st = state(Some(demo(0)), Freshness::Fresh);
        assert!(draw_at(140, 45, Some(&st), 0).contains("NO PEERS"));
    }

    #[test]
    fn a_long_peer_list_is_counted_and_scrolled() {
        let st = state(Some(demo(50)), Freshness::Fresh);
        let top = draw_at(140, 45, Some(&st), 0);
        assert!(top.contains("/ 50"), "peer counter missing: {top:?}");
        assert!(top.contains("PEERS 1-"), "counter does not start at 1");
        assert!(top.contains("node-0000"), "first peer not shown");
        let down = draw_at(140, 45, Some(&st), 12);
        assert!(down.contains("PEERS 13-"), "scroll offset not applied");
        assert!(!down.contains("node-0000"), "scrolled view still shows row 0");
    }

    #[test]
    fn three_peers_all_fit() {
        let st = state(Some(demo(3)), Freshness::Fresh);
        let out = draw_at(140, 45, Some(&st), 0);
        for i in 0..3 {
            assert!(out.contains(&format!("node-{i:04x}")), "peer {i} missing");
        }
        assert!(out.contains("PEERS 1-3 / 3"));
    }

    #[test]
    fn stale_peers_are_marked_not_live() {
        let st = state(Some(demo(3)), Freshness::Stale(Duration::from_secs(400)));
        let out = draw_at(140, 45, Some(&st), 0);
        assert!(out.contains("NOT LIVE"));
        assert!(!out.contains("● OK"), "stale pane still shows a healthy dot");
    }

    #[test]
    fn keys_move_the_offset() {
        let mut st = State::default();
        let key = |c| KeyEvent::new(c, KeyModifiers::NONE);
        on_key(&mut st, key(KeyCode::Char('j')));
        on_key(&mut st, key(KeyCode::Down));
        assert_eq!(st.scroll, 2);
        on_key(&mut st, key(KeyCode::Char('k')));
        assert_eq!(st.scroll, 1);
        on_key(&mut st, key(KeyCode::Char('k')));
        on_key(&mut st, key(KeyCode::Char('k')));
        assert_eq!(st.scroll, 0, "scroll must not wrap under zero");
        on_key(&mut st, key(KeyCode::PageDown));
        assert_eq!(st.scroll, 10);
        on_key(&mut st, key(KeyCode::Char('g')));
        assert_eq!(st.scroll, 0);
        on_key(&mut st, key(KeyCode::Char('G')));
        assert_eq!(st.scroll, u16::MAX);
    }

    #[test]
    fn columns_are_sized_to_content_and_capped() {
        let rows = vec![vec!["x".repeat(200), "ok".into()]];
        let w = widths(&["PEER".into(), "STATE".into()], &rows, 2);
        assert_eq!(w[0], Constraint::Length(COL_MAX as u16 + 1));
        assert_eq!(w[1], Constraint::Length(6));
    }
}
