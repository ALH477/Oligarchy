//! ORDNANCE — the action catalog.
//!
//! OWNER: work stream S4.
//!
//! Two columns (categories left, items right), `/` opening a flat fuzzy filter
//! over [`Catalog::flat`], `Enter` running the selection — and every one of
//! those paths funnelled through [`activate`], which is the only function in
//! this file that constructs [`Action::RunAction`].
//!
//! **The confirm modal is the safety property, not decoration.** This pane can
//! restart the mesh node, switch kernels and swap personas. A second execution
//! path that skipped the gate would be invisible until the day it mattered, so
//! there is exactly one: `activate` asks
//! [`warroom_core::actions::is_destructive`] and returns an [`Action::Confirm`]
//! wrapping the run instead of the run itself. `destructive_ids_cannot_reach_a
//! _bare_run_action` walks a fixture catalog and asserts it.
//!
//! The catalog is loaded lazily on first render and cached: building it costs a
//! subprocess per category (a dozen), so doing it per frame would make the pane
//! unusable and hammer the dispatcher's own `jq`/`hyprctl` probes.
//!
//! ## Known cross-stream issue: the filter cannot see every key
//!
//! `App::on_key` (S0, frozen) claims `q`, `r`, `t`, `D`, `F`, `1`-`6`, `Tab` and
//! `Esc` globally *before* dispatching to the active pane, so a query typed here
//! silently loses those characters — "restart" arrives as "estat" and `Esc`
//! quits the app rather than closing the filter. Nothing in this file can fix
//! that; the fix is one line in `app.rs`:
//!
//! ```ignore
//! if self.tab == Tab::Ordnance && ui::actions::capturing_text(&self.ordnance) {
//!     return ui::actions::on_key(&mut self.ordnance, k);
//! }
//! ```
//!
//! [`capturing_text`] exists for exactly that call site. Until it is wired,
//! `Backspace` on an empty query closes the filter, because `Esc` never arrives.

use super::widgets;
use crate::app::{Action, App};
use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use ratatui::layout::{Constraint, Direction, Layout, Rect};
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;
use ratatui::Frame;
use warroom_core::actions::{self, Catalog, Item};

/// Width of the category gutter. Long enough for "⚙ System & Kernel".
const CAT_WIDTH: u16 = 24;

#[derive(Debug, Default)]
pub struct State {
    pub catalog: Option<Catalog>,
    pub error: Option<String>,
    pub cat_idx: usize,
    pub item_idx: usize,
    /// `Some` while the `/` filter is open.
    pub filter: Option<String>,
    /// Have we attempted a load? Distinct from `catalog.is_some()`: a failed
    /// load must not be retried on every frame.
    pub loaded: bool,
    /// Indices into `Catalog::flat()` that match the current query, best first.
    pub hits: Vec<usize>,
    pub hit_idx: usize,
}

impl State {
    fn cats_len(&self) -> usize {
        self.catalog.as_ref().map(|c| c.cats.len()).unwrap_or(0)
    }

    fn items_len(&self) -> usize {
        self.catalog
            .as_ref()
            .and_then(|c| c.cats.get(self.cat_idx))
            .map(|c| c.items.len())
            .unwrap_or(0)
    }

    /// The selected item, whichever mode we are in. `None` is a normal answer:
    /// the filter can be narrowed to nothing, and a category can be empty.
    fn selected(&self) -> Option<&Item> {
        let catalog = self.catalog.as_ref()?;
        match &self.filter {
            Some(_) => {
                let flat = catalog.flat();
                let idx = *self.hits.get(self.hit_idx)?;
                flat.get(idx).copied()
            }
            None => catalog.cats.get(self.cat_idx)?.items.get(self.item_idx),
        }
    }

    /// Keep every index inside its list. Called after anything that can shrink
    /// a list under a cursor — which is what typing into the filter does on
    /// every keystroke.
    fn clamp(&mut self) {
        self.cat_idx = self.cat_idx.min(self.cats_len().saturating_sub(1));
        self.item_idx = self.item_idx.min(self.items_len().saturating_sub(1));
        self.hit_idx = self.hit_idx.min(self.hits.len().saturating_sub(1));
    }

    fn recompute_hits(&mut self) {
        let (Some(catalog), Some(q)) = (&self.catalog, &self.filter) else {
            self.hits.clear();
            self.hit_idx = 0;
            return;
        };
        let flat = catalog.flat();
        let mut scored: Vec<(usize, i32)> = flat
            .iter()
            .enumerate()
            .filter_map(|(i, it)| rank(it, q).map(|s| (i, s)))
            .collect();
        // Stable by construction: equal scores keep catalog order, so the list
        // does not shuffle under the cursor as the query grows.
        scored.sort_by(|a, b| b.1.cmp(&a.1));
        self.hits = scored.into_iter().map(|(i, _)| i).collect();
        self.hit_idx = 0;
    }
}

/// Is the `/` filter capturing raw text? See the module header — `app.rs` needs
/// this to stop eating the letters the query is made of.
// Unused until S0 wires the call site above; kept because the fix belongs in
// this pane's vocabulary, not in a global key table that has to know what a
// filter is.
#[allow(dead_code)]
pub fn capturing_text(st: &State) -> bool {
    st.filter.is_some()
}

/// Load the catalog once. A failure is recorded, shown, and NOT retried until
/// the operator asks (`R`) — `oligarchy-ctl` not being on PATH is a permanent
/// condition for this process, and retrying it per frame would spawn a dozen
/// doomed subprocesses a second.
fn ensure_loaded(st: &mut State) {
    if st.loaded {
        return;
    }
    st.loaded = true;
    match actions::catalog() {
        Ok(c) => {
            st.catalog = Some(c);
            st.error = None;
        }
        Err(e) => st.error = Some(e.to_string()),
    }
    st.clamp();
}

// ─────────────────────────────────────────────────────────────────────────────
// The gate
// ─────────────────────────────────────────────────────────────────────────────

/// Turn a selected item into the action that runs it — via a confirm modal when
/// the id is destructive.
///
/// THE single execution path. `Action::RunAction` appears nowhere else in this
/// file, which is what makes the gate structural rather than a convention.
fn activate(item: &Item) -> Action {
    let run = Action::RunAction(item.id.clone());
    if !actions::is_destructive(&item.id) {
        return run;
    }
    // One line: `confirm_overlay` gives the body a 58-column box seven rows
    // tall, and a body that wraps past it loses the y/n legend underneath.
    Action::Confirm {
        title: "CONFIRM ORDNANCE".to_string(),
        body: format!("{}  [{}] — changes system state. Fire?", plain(&item.title), item.id),
        action: Box::new(run),
    }
}

/// Strip the dispatcher's decorative leading glyph so the confirm body reads as
/// a sentence. Labels arrive as "🔊 Output → next device".
fn plain(label: &str) -> String {
    label
        .trim_start_matches(|c: char| !c.is_alphanumeric() && !c.is_whitespace())
        .trim()
        .to_string()
}

// ─────────────────────────────────────────────────────────────────────────────
// Fuzzy matching
// ─────────────────────────────────────────────────────────────────────────────

const BASE: i32 = 16;
/// A match immediately after the previous one. Ranked above a word start so
/// "status" prefers `dsp-status` to `sec-scan-... t...`-style scatter.
const CONSECUTIVE: i32 = 14;
/// A match at the start of a word: after `-`, `_`, `:`, `/`, `.`, a space, or at
/// a lower→upper case change.
const WORD_START: i32 = 12;
/// A match at position 0, on top of the word-start bonus it also earns.
const FIRST_CHAR: i32 = 10;
/// The query char matched the haystack's case exactly.
const EXACT_CASE: i32 = 2;
/// Per character skipped to reach a match, floored so one long gap does not
/// dominate the whole score.
const GAP: i32 = -2;
const GAP_FLOOR: i32 = -20;
/// Matching in the id is worth slightly more than matching in the label: ids
/// are what an operator who knows the system types.
const ID_BONUS: i32 = 8;

/// Score `needle` against `haystack`, or `None` if it is not a subsequence.
///
/// Deliberately hand-rolled and dependency-free (~40 lines): a fuzzy crate would
/// be a new pinned input for one pane's filter, and shelling out to `fzf` would
/// mean a second interactive program fighting this one for the tty.
///
/// The match is greedy-leftmost, which is the known weakness of this family:
/// `score("aab", "ab")` takes the first `a` and cannot backtrack to the pairing
/// that scores higher. For a catalog of ~70 short strings that costs nothing
/// visible, and it keeps the function O(len) with no allocation per candidate
/// beyond the two char vectors.
pub fn score(haystack: &str, needle: &str) -> Option<i32> {
    if needle.is_empty() {
        return Some(0);
    }
    // char vectors throughout: these labels carry emoji and `·`, and byte
    // indexing into them is a panic waiting for the first non-ASCII query.
    let hay: Vec<char> = haystack.chars().collect();
    let hay_lower: Vec<char> = hay.iter().flat_map(|c| c.to_lowercase()).collect();
    // `to_lowercase` can change the length (ẞ → ss), which would desynchronise
    // the two vectors and break the case bonus. Fall back to the raw chars in
    // that rare case rather than index a mismatched pair.
    let hay_lower = if hay_lower.len() == hay.len() {
        hay_lower
    } else {
        hay.clone()
    };

    let mut total = 0i32;
    let mut cursor = 0usize;
    let mut prev: Option<usize> = None;

    for nc in needle.chars() {
        if nc.is_whitespace() {
            continue; // a space in the query is a separator, not a character
        }
        let target = nc.to_lowercase().next().unwrap_or(nc);
        let found = (cursor..hay.len()).find(|&i| hay_lower[i] == target)?;

        total += BASE;
        let gap = (found - cursor) as i32;
        if gap > 0 {
            total += (GAP * gap).max(GAP_FLOOR);
        }
        if prev.is_some_and(|p| p + 1 == found) {
            total += CONSECUTIVE;
        }
        if found == 0 {
            total += FIRST_CHAR + WORD_START;
        } else if is_boundary(hay[found - 1], hay[found]) {
            total += WORD_START;
        }
        if hay[found] == nc {
            total += EXACT_CASE;
        }

        prev = Some(found);
        cursor = found + 1;
    }

    // Tie-break toward the shorter label: "DSP status" over "Benchmark DSP
    // latency" for the query "dsp".
    Some(total - (hay.len() as i32) / 8)
}

fn is_boundary(prev: char, cur: char) -> bool {
    matches!(prev, ' ' | '-' | '_' | ':' | '/' | '.' | ',' | '(' | '[' | '·' | '→')
        || (prev.is_lowercase() && cur.is_uppercase())
        || !prev.is_alphanumeric() && cur.is_alphanumeric()
}

/// Best of the item's id and its label.
pub fn rank(item: &Item, query: &str) -> Option<i32> {
    let by_id = score(&item.id, query).map(|s| s + ID_BONUS);
    let by_title = score(&item.title, query);
    match (by_id, by_title) {
        (Some(a), Some(b)) => Some(a.max(b)),
        (Some(a), None) => Some(a),
        (None, Some(b)) => Some(b),
        (None, None) => None,
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Render
// ─────────────────────────────────────────────────────────────────────────────

pub fn render(f: &mut Frame, area: Rect, app: &mut App) {
    ensure_loaded(&mut app.ordnance);

    let blk = widgets::block(&app.skin, "ORDNANCE", true);
    let inner = blk.inner(area);
    f.render_widget(blk, area);
    if inner.width == 0 || inner.height == 0 {
        return;
    }

    let s = &app.skin;
    let st = &app.ordnance;

    if st.catalog.is_none() {
        let why = st.error.as_deref().unwrap_or("catalog empty");
        return f.render_widget(
            Paragraph::new(vec![
                Line::from(Span::styled(
                    "NO CATALOG",
                    Style::default().fg(s.error()).add_modifier(Modifier::BOLD),
                )),
                Line::from(Span::styled(why.to_string(), Style::default().fg(s.text_dim()))),
                Line::from(""),
                Line::from(Span::styled(
                    "oligarchy-ctl is the shared action registry; without it this \
                     pane has nothing to drive.  R to retry.",
                    Style::default().fg(s.text_dim()),
                )),
            ])
            .wrap(ratatui::widgets::Wrap { trim: true }),
            inner,
        );
    }

    // One row at the bottom for the filter prompt / hit count.
    let rows = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Min(1), Constraint::Length(1)])
        .split(inner);

    if st.filter.is_some() {
        render_filter(f, rows[0], app);
    } else {
        render_browse(f, rows[0], app);
    }
    render_prompt(f, rows[1], app);
}

fn render_browse(f: &mut Frame, area: Rect, app: &App) {
    let s = &app.skin;
    let st = &app.ordnance;
    let Some(catalog) = &st.catalog else { return };

    let cols = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([Constraint::Length(CAT_WIDTH.min(area.width)), Constraint::Min(0)])
        .split(area);

    let height = cols[0].height as usize;
    let off = window(st.cat_idx, catalog.cats.len(), height);
    let cat_lines: Vec<Line> = catalog
        .cats
        .iter()
        .enumerate()
        .skip(off)
        .take(height)
        .map(|(i, c)| {
            let sel = i == st.cat_idx;
            let style = if sel {
                Style::default().fg(s.accent()).add_modifier(Modifier::BOLD)
            } else {
                Style::default().fg(s.text_dim())
            };
            Line::from(vec![
                Span::styled(if sel { "▸ " } else { "  " }, style),
                Span::styled(truncate(&c.title, CAT_WIDTH as usize - 3), style),
            ])
        })
        .collect();
    f.render_widget(Paragraph::new(cat_lines), cols[0]);

    let Some(cat) = catalog.cats.get(st.cat_idx) else { return };
    if cat.items.is_empty() {
        return f.render_widget(
            Paragraph::new(Line::from(Span::styled(
                "no actions in this category",
                Style::default().fg(s.text_dim()),
            ))),
            cols[1],
        );
    }

    let height = cols[1].height as usize;
    let off = window(st.item_idx, cat.items.len(), height);
    let width = cols[1].width as usize;
    let lines: Vec<Line> = cat
        .items
        .iter()
        .enumerate()
        .skip(off)
        .take(height)
        .map(|(i, it)| item_line(app, it, i == st.item_idx, width))
        .collect();
    f.render_widget(Paragraph::new(lines), cols[1]);
}

fn render_filter(f: &mut Frame, area: Rect, app: &App) {
    let s = &app.skin;
    let st = &app.ordnance;
    let Some(catalog) = &st.catalog else { return };

    if st.hits.is_empty() {
        return f.render_widget(
            Paragraph::new(Line::from(Span::styled(
                "no action matches",
                Style::default().fg(s.warning()),
            ))),
            area,
        );
    }

    let flat = catalog.flat();
    let height = area.height as usize;
    let off = window(st.hit_idx, st.hits.len(), height);
    let width = area.width as usize;
    let lines: Vec<Line> = st
        .hits
        .iter()
        .enumerate()
        .skip(off)
        .take(height)
        .filter_map(|(row, &idx)| {
            let it = flat.get(idx).copied()?;
            Some(item_line(app, it, row == st.hit_idx, width))
        })
        .collect();
    f.render_widget(Paragraph::new(lines), area);
}

/// `▸ ! dcf-restart          Restart node`
fn item_line(app: &App, it: &Item, selected: bool, width: usize) -> Line<'static> {
    let s = &app.skin;
    let style = if selected {
        Style::default().fg(s.accent()).add_modifier(Modifier::BOLD)
    } else {
        Style::default().fg(s.text())
    };
    let destructive = actions::is_destructive(&it.id);
    // The gate made visible: an operator should be able to see which rows will
    // stop and ask before they press Enter on one.
    let mark = if destructive {
        Span::styled("! ", Style::default().fg(s.error()).add_modifier(Modifier::BOLD))
    } else {
        Span::styled("  ", Style::default().fg(s.text_dim()))
    };

    let id_w = 22usize;
    let id = truncate(&it.id, id_w);
    let pad = id_w.saturating_sub(id.chars().count()) + 1;
    let label_w = width.saturating_sub(id_w + pad + 4).max(8);

    Line::from(vec![
        Span::styled(if selected { "▸" } else { " " }, style),
        mark,
        Span::styled(id, Style::default().fg(if selected { s.accent() } else { s.text_dim() })),
        Span::raw(" ".repeat(pad)),
        Span::styled(truncate(&it.title, label_w), style),
    ])
}

fn render_prompt(f: &mut Frame, area: Rect, app: &App) {
    let s = &app.skin;
    let st = &app.ordnance;
    let line = match &st.filter {
        Some(q) => Line::from(vec![
            Span::styled("/", Style::default().fg(s.accent()).add_modifier(Modifier::BOLD)),
            Span::styled(q.clone(), Style::default().fg(s.text())),
            Span::styled("▏", Style::default().fg(s.accent())),
            Span::styled(
                format!("  {} match{}", st.hits.len(), if st.hits.len() == 1 { "" } else { "es" }),
                Style::default().fg(s.text_dim()),
            ),
        ]),
        None => {
            let total = st.catalog.as_ref().map(|c| c.len()).unwrap_or(0);
            Line::from(vec![
                Span::styled(
                    format!("{total} actions  "),
                    Style::default().fg(s.text_dim()),
                ),
                Span::styled("!", Style::default().fg(s.error()).add_modifier(Modifier::BOLD)),
                Span::styled(
                    " confirms first   / filter   h/l category   j/k action   R reload",
                    Style::default().fg(s.text_dim()),
                ),
            ])
        }
    };
    f.render_widget(Paragraph::new(line), area);
}

/// First visible row for a list of `len` shown `height` rows tall with `sel`
/// selected. Keeps the cursor off the edges without scrolling past the end.
fn window(sel: usize, len: usize, height: usize) -> usize {
    if height == 0 || len <= height {
        return 0;
    }
    let half = height / 2;
    if sel < half {
        0
    } else {
        (sel - half).min(len - height)
    }
}

/// Truncate on CHARACTER boundaries — these labels are full of emoji, and
/// `&s[..n]` on one is a panic.
fn truncate(s: &str, max: usize) -> String {
    if max == 0 {
        return String::new();
    }
    if s.chars().count() <= max {
        return s.to_string();
    }
    s.chars().take(max.saturating_sub(1)).collect::<String>() + "…"
}

// ─────────────────────────────────────────────────────────────────────────────
// Keys
// ─────────────────────────────────────────────────────────────────────────────

pub fn on_key(st: &mut State, k: KeyEvent) -> Option<Action> {
    if st.filter.is_some() {
        return filter_key(st, k);
    }

    match k.code {
        KeyCode::Char('/') => {
            st.filter = Some(String::new());
            st.recompute_hits();
        }
        KeyCode::Char('R') => {
            // Explicit reload: the catalog is a dozen subprocesses, so it is
            // never refreshed implicitly.
            st.loaded = false;
            st.catalog = None;
            st.error = None;
            ensure_loaded(st);
        }
        KeyCode::Char('j') | KeyCode::Down => move_item(st, 1),
        KeyCode::Char('k') | KeyCode::Up => move_item(st, -1),
        KeyCode::Char('l') | KeyCode::Right | KeyCode::Char('L') => move_cat(st, 1),
        KeyCode::Char('h') | KeyCode::Left => move_cat(st, -1),
        KeyCode::PageDown => move_item(st, 10),
        KeyCode::PageUp => move_item(st, -10),
        KeyCode::Home => st.item_idx = 0,
        KeyCode::End => st.item_idx = st.items_len().saturating_sub(1),
        KeyCode::Enter => return st.selected().map(activate),
        _ => {}
    }
    st.clamp();
    None
}

fn filter_key(st: &mut State, k: KeyEvent) -> Option<Action> {
    // Ctrl/Alt chords are never query text.
    let chord = k.modifiers.intersects(KeyModifiers::CONTROL | KeyModifiers::ALT);
    match k.code {
        KeyCode::Esc => {
            // Only arrives once `app.rs` stops claiming Esc — see the module
            // header. Harmless to handle now.
            st.filter = None;
            st.hits.clear();
            st.hit_idx = 0;
        }
        KeyCode::Backspace => {
            let empty = match st.filter.as_mut() {
                Some(q) => {
                    q.pop();
                    q.is_empty()
                }
                None => true,
            };
            if empty {
                // Backspacing out of an empty query is the only way to leave the
                // filter while Esc is claimed globally.
                st.filter = None;
                st.hits.clear();
                st.hit_idx = 0;
            } else {
                st.recompute_hits();
            }
        }
        KeyCode::Char(c) if !chord => {
            if let Some(q) = st.filter.as_mut() {
                q.push(c);
            }
            st.recompute_hits();
        }
        KeyCode::Down => move_hit(st, 1),
        KeyCode::Up => move_hit(st, -1),
        KeyCode::PageDown => move_hit(st, 10),
        KeyCode::PageUp => move_hit(st, -10),
        KeyCode::Enter => return st.selected().map(activate),
        _ => {}
    }
    st.clamp();
    None
}

fn move_item(st: &mut State, delta: isize) {
    st.item_idx = step(st.item_idx, delta, st.items_len());
}

fn move_hit(st: &mut State, delta: isize) {
    st.hit_idx = step(st.hit_idx, delta, st.hits.len());
}

fn move_cat(st: &mut State, delta: isize) {
    st.cat_idx = step(st.cat_idx, delta, st.cats_len());
    st.item_idx = 0;
}

/// Saturating movement inside a list that may be empty. Never wraps: wrapping a
/// category list under a two-column browse loses the operator's place.
fn step(idx: usize, delta: isize, len: usize) -> usize {
    if len == 0 {
        return 0;
    }
    let max = (len - 1) as isize;
    (idx as isize + delta).clamp(0, max) as usize
}

#[cfg(test)]
mod tests {
    use super::*;
    use warroom_core::actions::Category;

    fn item(cat: &str, id: &str, title: &str) -> Item {
        Item { id: id.into(), title: title.into(), cat: cat.into() }
    }

    /// A trimmed but faithful slice of the real dispatcher's catalog, including
    /// the emoji labels and the generated `theme-set:` ids.
    fn fixture() -> Catalog {
        Catalog {
            cats: vec![
                Category {
                    id: "appearance".into(),
                    title: "🎨 Style".into(),
                    items: vec![
                        item("appearance", "theme-set:demod", "DeMoD ✓"),
                        item("appearance", "theme-next", "Next theme"),
                    ],
                },
                Category {
                    id: "dsp".into(),
                    title: "🎛 Audio / DSP".into(),
                    items: vec![
                        item("dsp", "dsp-status", "DSP status"),
                        item("dsp", "dsp-netjack", "Restart NETJACK"),
                        item("dsp", "dsp-bench", "Benchmark DSP latency"),
                        item("dsp", "arm-dsp", "Arm / disarm coprocessor"),
                    ],
                },
                Category {
                    id: "dcf".into(),
                    title: "🛰 DCF Fabric".into(),
                    items: vec![
                        item("dcf", "dcf-status", "Mesh status"),
                        item("dcf", "dcf-restart", "Restart node"),
                    ],
                },
                Category { id: "tv".into(), title: "📺 Theater".into(), items: vec![] },
                Category {
                    id: "system".into(),
                    title: "⚙ System & Kernel".into(),
                    items: vec![
                        item("system", "kernel-zen", "Kernel → zen"),
                        item("system", "repo-pull", "Pull repo updates (fast-forward only)"),
                        item("system", "persona-show", "Current persona"),
                    ],
                },
            ],
        }
    }

    fn loaded() -> State {
        let mut st = State { catalog: Some(fixture()), loaded: true, ..Default::default() };
        st.clamp();
        st
    }

    fn press(code: KeyCode) -> KeyEvent {
        KeyEvent::new(code, KeyModifiers::NONE)
    }

    // ── the gate ────────────────────────────────────────────────────────────

    /// The safety property, asserted over the whole catalog rather than a
    /// hand-picked id: nothing `is_destructive` says yes to may produce a bare
    /// `RunAction`, and nothing it says no to may cost an extra keystroke.
    #[test]
    fn destructive_ids_cannot_reach_a_bare_run_action() {
        for it in fixture().flat() {
            match activate(it) {
                Action::Confirm { action, body, title } => {
                    assert!(
                        actions::is_destructive(&it.id),
                        "{} is gated but not destructive",
                        it.id
                    );
                    assert!(matches!(*action, Action::RunAction(ref id) if id == &it.id));
                    assert!(!title.is_empty());
                    assert!(body.contains(&it.id), "confirm body must name the action");
                }
                Action::RunAction(id) => {
                    assert_eq!(id, it.id);
                    assert!(
                        !actions::is_destructive(&it.id),
                        "{} reached a bare RunAction",
                        it.id
                    );
                }
                other => panic!("activate produced {other:?}"),
            }
        }
    }

    #[test]
    fn enter_on_a_destructive_row_confirms_in_both_modes() {
        // Browse: category 2 ("dcf"), item 1 ("dcf-restart").
        let mut st = loaded();
        st.cat_idx = 2;
        st.item_idx = 1;
        assert!(matches!(on_key(&mut st, press(KeyCode::Enter)), Some(Action::Confirm { .. })));

        // Filter: same action reached through the fuzzy list.
        let mut st = loaded();
        on_key(&mut st, press(KeyCode::Char('/')));
        for c in "dcfrest".chars() {
            on_key(&mut st, press(KeyCode::Char(c)));
        }
        match on_key(&mut st, press(KeyCode::Enter)) {
            Some(Action::Confirm { action, .. }) => {
                assert!(matches!(*action, Action::RunAction(ref id) if id == "dcf-restart"));
            }
            other => panic!("expected a confirm, got {other:?}"),
        }
    }

    #[test]
    fn a_read_only_action_runs_without_a_modal() {
        let mut st = loaded();
        st.cat_idx = 4;
        st.item_idx = 2; // persona-show — exempted from the persona- prefix
        assert!(matches!(
            on_key(&mut st, press(KeyCode::Enter)),
            Some(Action::RunAction(ref id)) if id == "persona-show"
        ));
    }

    // ── never panic ─────────────────────────────────────────────────────────

    #[test]
    fn an_empty_catalog_survives_every_key() {
        let mut st = State::default();
        for code in [
            KeyCode::Char('j'), KeyCode::Char('k'), KeyCode::Char('h'), KeyCode::Char('l'),
            KeyCode::Up, KeyCode::Down, KeyCode::Left, KeyCode::Right, KeyCode::PageUp,
            KeyCode::PageDown, KeyCode::Home, KeyCode::End, KeyCode::Enter, KeyCode::Char('/'),
            KeyCode::Backspace, KeyCode::Char('x'), KeyCode::Esc, KeyCode::Enter,
        ] {
            assert!(on_key(&mut st, press(code)).is_none());
        }
    }

    /// The most likely crash in this pane: a filter narrowed to nothing with a
    /// cursor left pointing into the old, longer list.
    #[test]
    fn filtering_to_nothing_then_pressing_enter_is_a_no_op() {
        let mut st = loaded();
        on_key(&mut st, press(KeyCode::Char('/')));
        for c in "dsp".chars() {
            on_key(&mut st, press(KeyCode::Char(c)));
        }
        assert!(!st.hits.is_empty());
        on_key(&mut st, press(KeyCode::Down));
        on_key(&mut st, press(KeyCode::Down));
        let sunk = st.hit_idx;
        for c in "zzzzqqqq".chars() {
            on_key(&mut st, press(KeyCode::Char(c)));
        }
        assert!(st.hits.is_empty());
        assert!(sunk > 0);
        assert!(st.selected().is_none());
        assert!(on_key(&mut st, press(KeyCode::Enter)).is_none());
    }

    #[test]
    fn an_empty_category_selects_nothing() {
        let mut st = loaded();
        st.cat_idx = 3; // tv, which really does ship with zero items sometimes
        st.clamp();
        assert!(st.selected().is_none());
        assert!(on_key(&mut st, press(KeyCode::Enter)).is_none());
    }

    #[test]
    fn navigation_saturates_at_both_ends() {
        let mut st = loaded();
        for _ in 0..50 {
            on_key(&mut st, press(KeyCode::Char('l')));
        }
        assert_eq!(st.cat_idx, 4);
        for _ in 0..50 {
            on_key(&mut st, press(KeyCode::Char('j')));
        }
        assert_eq!(st.item_idx, st.items_len() - 1);
        for _ in 0..50 {
            on_key(&mut st, press(KeyCode::Char('k')));
            on_key(&mut st, press(KeyCode::Char('h')));
        }
        assert_eq!((st.cat_idx, st.item_idx), (0, 0));
    }

    #[test]
    fn backspacing_out_of_an_empty_query_closes_the_filter() {
        let mut st = loaded();
        on_key(&mut st, press(KeyCode::Char('/')));
        on_key(&mut st, press(KeyCode::Char('d')));
        assert!(capturing_text(&st));
        on_key(&mut st, press(KeyCode::Backspace));
        on_key(&mut st, press(KeyCode::Backspace));
        assert!(!capturing_text(&st));
    }

    #[test]
    fn truncate_never_splits_a_glyph() {
        assert_eq!(truncate("🎛 Audio / DSP", 0), "");
        assert_eq!(truncate("🎛 Audio / DSP", 4).chars().count(), 4);
        assert_eq!(truncate("short", 40), "short");
    }

    #[test]
    fn the_window_never_scrolls_past_the_end() {
        assert_eq!(window(0, 0, 10), 0);
        assert_eq!(window(5, 3, 10), 0);
        assert_eq!(window(9, 10, 0), 0);
        assert_eq!(window(0, 100, 10), 0);
        assert_eq!(window(99, 100, 10), 90);
        assert_eq!(window(50, 100, 10), 45);
    }

    // ── the matcher ─────────────────────────────────────────────────────────

    #[test]
    fn a_non_subsequence_never_matches() {
        assert!(score("dsp-status", "zz").is_none());
        assert!(score("dsp-status", "sd").is_none()); // order matters
        assert!(score("", "a").is_none());
        assert_eq!(score("anything", ""), Some(0));
    }

    #[test]
    fn matching_is_case_insensitive_but_exact_case_scores_higher() {
        let mixed = score("DSP status", "DSP").unwrap();
        let lower = score("DSP status", "dsp").unwrap();
        assert!(mixed > lower, "{mixed} !> {lower}");
    }

    #[test]
    fn consecutive_beats_scattered_and_word_starts_beat_the_middle() {
        // Same haystack, so the comparison is only about where chars landed.
        let consecutive = score("dsp-status", "sta").unwrap();
        let scattered = score("dsp-status", "sus").unwrap();
        assert!(consecutive > scattered, "{consecutive} !> {scattered}");

        let at_start = score("status", "s").unwrap();
        let after_dash = score("dcf-status", "s").unwrap();
        let mid_word = score("assorted", "s").unwrap();
        assert!(at_start > after_dash, "{at_start} !> {after_dash}");
        assert!(after_dash > mid_word, "{after_dash} !> {mid_word}");
    }

    #[test]
    fn emoji_labels_do_not_panic_or_confuse_the_boundaries() {
        assert!(score("🎛 Audio / DSP · DSP status", "dsp").is_some());
        assert!(score("🎨 Style", "style").is_some());
        assert!(rank(&item("dsp", "dsp-status", "🎛 DSP status"), "🎛").is_some());
    }

    /// End-to-end ranking over the fixture: what the operator actually sees.
    fn top(query: &str, n: usize) -> Vec<String> {
        let mut st = loaded();
        st.filter = Some(query.to_string());
        st.recompute_hits();
        let catalog = st.catalog.as_ref().unwrap();
        let flat = catalog.flat();
        st.hits.iter().take(n).filter_map(|&i| flat.get(i).map(|it| it.id.clone())).collect()
    }

    #[test]
    fn the_obvious_query_puts_the_obvious_action_first() {
        assert_eq!(top("dcfres", 1), ["dcf-restart"]);
        assert_eq!(top("dspst", 1), ["dsp-status"]);
        assert_eq!(top("kz", 1), ["kernel-zen"]);
        assert_eq!(top("netjack", 1), ["dsp-netjack"]);
        // Label-only match: no item id contains "bench"… except dsp-bench, so
        // use a word that lives purely in a label.
        assert_eq!(top("latency", 1), ["dsp-bench"]);
    }

    /// A word two actions share ranks both of them, and the one whose *label*
    /// starts with it is not unfairly beaten by the one whose *id* contains it.
    /// Ties keep catalog order rather than shuffling — which is the property
    /// that matters, since the operator picks from the list either way.
    #[test]
    fn a_shared_word_surfaces_every_action_that_has_it() {
        let hits = top("restart", 5);
        assert!(hits.contains(&"dcf-restart".to_string()), "{hits:?}");
        assert!(hits.contains(&"dsp-netjack".to_string()), "{hits:?}");
    }

    #[test]
    fn a_query_matching_nothing_returns_nothing_rather_than_everything() {
        assert!(top("qqqq", 5).is_empty());
    }

    #[test]
    fn an_empty_query_keeps_every_action_in_catalog_order() {
        let all = top("", 99);
        assert_eq!(all.len(), fixture().len());
        assert_eq!(all.first().map(String::as_str), Some("theme-set:demod"));
    }

    #[test]
    fn plain_strips_the_leading_glyph_only() {
        assert_eq!(plain("🔊 Output → next device"), "Output → next device");
        assert_eq!(plain("Restart node"), "Restart node");
        assert_eq!(plain(""), "");
    }
}
