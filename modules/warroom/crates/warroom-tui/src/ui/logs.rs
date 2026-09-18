//! TRAFFIC — journal tail plus the output of the last action.
//!
//! OWNER: work stream S4. `push()` is wired into the app's action dispatch, so
//! its signature is frozen.
//!
//! This pane is what gives ORDNANCE the feedback the wofi/fzf front-ends never
//! had: `oligarchy-ctl run` reports through `notify-send` and frequently says
//! nothing on stdout at all, so without somewhere to look, "did that work?" had
//! no answer short of opening a terminal.
//!
//! ## Two rules this file exists to honour
//!
//! **Empty output is a distinct state, never success.** `journalctl -u <unit>`
//! exits 0 and prints `-- No entries --` for a unit that is disabled, for a unit
//! that has simply been quiet, and — the dangerous one — for a caller who cannot
//! read the system journal. Those three are rendered as three different things,
//! because CLAUDE.md's recorded lesson is that a tool returning nothing looks
//! exactly like a healthy tool with nothing to say.
//!
//! **Permission is checked, not inferred.** Journal access is an ACL on
//! `/var/log/journal` (`group:wheel:r-x`, `group:adm:r-x`, owner group
//! `systemd-journal`), and a caller outside all of them does not get an error —
//! it gets *its own* messages and a hint on stderr that `exec::run` discards on
//! a zero exit. So access is probed directly by trying to read the journal
//! directory, and [`Access::Restricted`] is rendered as loudly as a failure.
//!
//! The fetch runs on its own thread and reports through a channel: the frame
//! loop never blocks on a subprocess, which is the same reason the collectors
//! have a scheduler.

use super::widgets;
use crate::app::{Action, App};
use crossterm::event::{KeyCode, KeyEvent};
use ratatui::layout::{Constraint, Direction, Layout, Rect};
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Paragraph, Wrap};
use ratatui::Frame;
use std::sync::mpsc::{self, Receiver};
use std::time::{Duration, Instant};
use warroom_core::exec;

/// Keeps the pane bounded; a runaway action must not grow memory forever.
const MAX_LINES: usize = 2000;
/// Lines asked of journalctl per refresh.
const TAIL: &str = "200";
/// Short on purpose: this runs off-thread, but a wedged journalctl still holds
/// a thread and a stale "fetching" label until it expires.
const FETCH_TIMEOUT: Duration = Duration::from_secs(4);
/// How often the selected unit is re-tailed while this pane is on screen.
const REFRESH: Duration = Duration::from_secs(5);

/// A curated unit set: every name here is declared by a module in this repo
/// (`systemd.services.<name>` / `systemd.user.services.<name>`), so the list
/// cannot drift into units that never existed. A unit that is not enabled on
/// this host reports as such rather than being hidden — "the p2p daemon is off"
/// is exactly the kind of thing an operator opens this pane to learn.
pub struct Unit {
    pub unit: &'static str,
    pub label: &'static str,
    /// `--user`: a session unit, readable without any journal privilege.
    pub user: bool,
}

pub const UNITS: &[Unit] = &[
    Unit { unit: "oligarchy-p2pd", label: "p2p daemon", user: false },
    Unit { unit: "oligarchy-plugind", label: "plugin host", user: false },
    Unit { unit: "oligarchy-mcp", label: "MCP servers", user: false },
    Unit { unit: "strict-egress-rules", label: "egress fw", user: false },
    Unit { unit: "malware-shield-yara", label: "YARA scan", user: false },
    Unit { unit: "demod-ip-blocker-update", label: "ip blocklists", user: false },
    Unit { unit: "dcf-spa-gate-rules", label: "SPA gate", user: false },
    Unit { unit: "nix-daemon", label: "nix-daemon", user: false },
    Unit { unit: "dcf-mesh-agent", label: "mesh agent", user: true },
    Unit { unit: "blipply-assistant", label: "blipply", user: true },
];

/// What the journal had to say, as four distinguishable outcomes.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub enum Tail {
    #[default]
    Idle,
    Fetching,
    /// Lines came back.
    Lines,
    /// journalctl succeeded and the unit genuinely has nothing.
    Empty,
    /// journalctl succeeded but we are not allowed to see other users' logs, so
    /// "nothing" means nothing-we-can-see.
    Restricted,
    /// journalctl failed outright (absent, timed out, refused).
    Failed(String),
}

/// Result of one off-thread fetch.
struct Fetched {
    unit: &'static str,
    lines: Vec<String>,
    state: Tail,
}

#[derive(Debug, Default)]
pub struct State {
    /// Action output, appended by [`push`].
    pub lines: Vec<String>,
    pub scroll: u16,
    /// 0 = action output; 1.. = `UNITS[src - 1]`.
    pub src: usize,
    pub journal: Vec<String>,
    pub tail: Tail,
    pub fetched_at: Option<Instant>,
    /// In-flight fetch. `try_recv` only — the frame loop never waits. Private:
    /// nothing outside this pane has any business holding its channel.
    pending: Option<Receiver<Fetched>>,
}

impl std::fmt::Debug for Fetched {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Fetched").field("unit", &self.unit).finish()
    }
}

impl State {
    fn unit(&self) -> Option<&'static Unit> {
        self.src.checked_sub(1).and_then(|i| UNITS.get(i))
    }
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
    // New output is the reason the pane was switched to; show it from the top
    // of what just landed rather than wherever the operator had scrolled to.
    st.src = 0;
    st.scroll = 0;
}

// ─────────────────────────────────────────────────────────────────────────────
// Journal
// ─────────────────────────────────────────────────────────────────────────────

/// Whether this process can read other users' journals at all.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Access {
    /// The journal directory is readable: `systemd-journal`, `adm` or `wheel`.
    Full,
    /// Present but unreadable — we will only ever see our own messages, and
    /// journalctl will not say so on a zero exit.
    Restricted,
    /// No journal on disk at all (`Storage=none`, or a container).
    Absent,
}

/// Probe journal access by the only signal that does not lie: whether the
/// directory systemd ACLs can actually be opened.
///
/// `journalctl` itself is no help here — a caller without access still exits 0,
/// prints whatever of its own it can see, and puts the explanation on stderr,
/// which a zero exit discards.
pub fn access() -> Access {
    let mut absent = true;
    for dir in ["/var/log/journal", "/run/log/journal"] {
        match std::fs::read_dir(dir) {
            Ok(_) => return Access::Full,
            Err(e) if e.kind() == std::io::ErrorKind::PermissionDenied => {
                absent = false;
            }
            Err(_) => {}
        }
    }
    if absent {
        Access::Absent
    } else {
        Access::Restricted
    }
}

/// Classify one journalctl result. Split out from the thread so the states are
/// testable without a journal.
fn classify(out: &str, user_unit: bool, acc: Access) -> (Vec<String>, Tail) {
    let lines: Vec<String> = out
        .lines()
        .map(str::trim_end)
        .filter(|l| !l.is_empty() && !l.starts_with("-- No entries"))
        .map(str::to_string)
        .collect();

    if !lines.is_empty() {
        return (lines, Tail::Lines);
    }
    // A user unit lives in this user's own journal, so a restricted system
    // journal says nothing about it — do not mislabel it.
    if !user_unit && acc == Access::Restricted {
        return (Vec::new(), Tail::Restricted);
    }
    (Vec::new(), Tail::Empty)
}

/// Kick off a fetch on its own thread. Returns immediately.
fn spawn_fetch(st: &mut State) {
    let Some(u) = st.unit() else { return };
    let (tx, rx) = mpsc::channel();
    let unit = u.unit;
    let user = u.user;
    std::thread::spawn(move || {
        let acc = access();
        let mut args: Vec<&str> = vec!["--no-pager", "-n", TAIL, "-u", unit];
        if user {
            args.insert(0, "--user");
        }
        let fetched = match exec::run("journalctl", &args, FETCH_TIMEOUT) {
            Ok(out) => {
                let (lines, state) = classify(&out, user, acc);
                Fetched { unit, lines, state }
            }
            Err(e) => {
                let msg = e.to_string();
                // journalctl reports a refusal on stderr with a non-zero exit
                // only in some configurations; catch it either way.
                let state = if is_denial(&msg) {
                    Tail::Restricted
                } else {
                    Tail::Failed(msg)
                };
                Fetched { unit, lines: Vec::new(), state }
            }
        };
        let _ = tx.send(fetched);
    });
    st.pending = Some(rx);
    st.tail = Tail::Fetching;
    st.fetched_at = Some(Instant::now());
}

fn is_denial(msg: &str) -> bool {
    let m = msg.to_lowercase();
    m.contains("permission denied") || m.contains("access denied") || m.contains("not permitted")
}

/// Drain a finished fetch and start a new one when the tail has gone cold.
/// Called from `render`, which is the only place that knows the pane is visible.
fn poll(st: &mut State) {
    if let Some(rx) = st.pending.take() {
        match rx.try_recv() {
            Ok(f) => {
                // A result for a unit the operator has since moved off is
                // dropped rather than shown under the wrong heading.
                if st.unit().map(|u| u.unit) == Some(f.unit) {
                    st.journal = f.lines;
                    st.tail = f.state;
                    st.fetched_at = Some(Instant::now());
                }
            }
            Err(mpsc::TryRecvError::Empty) => {
                // Still running: put it back and come again next frame.
                st.pending = Some(rx);
                return;
            }
            Err(mpsc::TryRecvError::Disconnected) => {
                st.tail = Tail::Failed("journal fetch thread died".into());
            }
        }
    }
    if st.unit().is_none() {
        return;
    }
    let cold = st.fetched_at.map(|t| t.elapsed() >= REFRESH).unwrap_or(true);
    if cold {
        spawn_fetch(st);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Render
// ─────────────────────────────────────────────────────────────────────────────

pub fn render(f: &mut Frame, area: Rect, app: &mut App) {
    poll(&mut app.traffic);

    let s = &app.skin;
    let blk = widgets::block(s, "TRAFFIC", true);
    let inner = blk.inner(area);
    f.render_widget(blk, area);
    if inner.width == 0 || inner.height == 0 {
        return;
    }

    let rows = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Length(1), Constraint::Min(0)])
        .split(inner);

    render_sources(f, rows[0], app);

    let st = &app.traffic;
    match st.unit() {
        None => render_output(f, rows[1], app),
        Some(u) => render_journal(f, rows[1], app, u),
    }
}

/// The source strip: action output plus every curated unit, current one lit.
fn render_sources(f: &mut Frame, area: Rect, app: &App) {
    let s = &app.skin;
    let st = &app.traffic;
    let mut spans = vec![Span::styled(
        "◂ ",
        Style::default().fg(s.text_dim()),
    )];
    let names = std::iter::once("output").chain(UNITS.iter().map(|u| u.label));
    for (i, name) in names.enumerate() {
        let sel = i == st.src;
        spans.push(Span::styled(
            format!(" {name} "),
            if sel {
                Style::default().fg(s.bg()).bg(s.accent()).add_modifier(Modifier::BOLD)
            } else {
                Style::default().fg(s.text_dim())
            },
        ));
    }
    spans.push(Span::styled(" ▸", Style::default().fg(s.text_dim())));
    f.render_widget(Paragraph::new(Line::from(spans)), area);
}

fn render_output(f: &mut Frame, area: Rect, app: &App) {
    let s = &app.skin;
    let st = &app.traffic;
    if st.lines.is_empty() {
        return f.render_widget(
            Paragraph::new(vec![
                Line::from(Span::styled("NO TRAFFIC", Style::default().fg(s.text_dim()))),
                Line::from(Span::styled(
                    "output from ORDNANCE actions lands here; h/l for a unit journal",
                    Style::default().fg(s.text_dim()),
                )),
            ]),
            area,
        );
    }
    let lines: Vec<Line> = st
        .lines
        .iter()
        .map(|l| {
            // The dispatch prefixes each run with its own command line; make it
            // findable in a wall of output.
            let style = if l.starts_with("$ ") {
                Style::default().fg(s.accent()).add_modifier(Modifier::BOLD)
            } else if l.starts_with("FAILED") || l.starts_with("handoff failed") {
                Style::default().fg(s.error())
            } else {
                Style::default().fg(s.text())
            };
            Line::from(Span::styled(l.clone(), style))
        })
        .collect();
    f.render_widget(
        Paragraph::new(lines).scroll((st.scroll, 0)).wrap(Wrap { trim: false }),
        area,
    );
}

fn render_journal(f: &mut Frame, area: Rect, app: &App, u: &Unit) {
    let s = &app.skin;
    let st = &app.traffic;

    let note = |title: &str, body: String, color: ratatui::style::Color| {
        Paragraph::new(vec![
            Line::from(Span::styled(
                title.to_string(),
                Style::default().fg(color).add_modifier(Modifier::BOLD),
            )),
            Line::from(Span::styled(body, Style::default().fg(s.text_dim()))),
        ])
        .wrap(Wrap { trim: true })
    };

    let scope = if u.user { "--user " } else { "" };
    match &st.tail {
        Tail::Fetching | Tail::Idle if st.journal.is_empty() => {
            return f.render_widget(
                note("READING", format!("journalctl {scope}-u {}", u.unit), s.text_dim()),
                area,
            );
        }
        Tail::Restricted => {
            // The state this pane exists to make visible.
            return f.render_widget(
                note(
                    "NO JOURNAL ACCESS",
                    format!(
                        "the system journal is not readable by this user, so `journalctl \
                         -u {}` returns nothing rather than an error. Membership in \
                         systemd-journal, adm or wheel is what grants it.",
                        u.unit
                    ),
                    s.error(),
                ),
                area,
            );
        }
        Tail::Failed(e) => {
            return f.render_widget(note("JOURNAL UNAVAILABLE", e.clone(), s.error()), area);
        }
        Tail::Empty => {
            return f.render_widget(
                note(
                    "NO ENTRIES",
                    format!(
                        "journalctl {scope}-u {} has nothing — the unit may not be \
                         enabled on this host, or may simply have been quiet.",
                        u.unit
                    ),
                    s.warning(),
                ),
                area,
            );
        }
        _ => {}
    }

    let lines: Vec<Line> = st
        .journal
        .iter()
        .map(|l| {
            let lower = l.to_lowercase();
            let style = if lower.contains("error") || lower.contains("failed") {
                Style::default().fg(s.error())
            } else if lower.contains("warn") {
                Style::default().fg(s.warning())
            } else {
                Style::default().fg(s.text())
            };
            Line::from(Span::styled(l.clone(), style))
        })
        .collect();
    f.render_widget(
        Paragraph::new(lines).scroll((st.scroll, 0)).wrap(Wrap { trim: false }),
        area,
    );
}

// ─────────────────────────────────────────────────────────────────────────────
// Keys
// ─────────────────────────────────────────────────────────────────────────────

pub fn on_key(st: &mut State, k: KeyEvent) -> Option<Action> {
    let len = UNITS.len() + 1;
    match k.code {
        KeyCode::Char('j') | KeyCode::Down => st.scroll = st.scroll.saturating_add(1),
        KeyCode::Char('k') | KeyCode::Up => st.scroll = st.scroll.saturating_sub(1),
        KeyCode::PageDown => st.scroll = st.scroll.saturating_add(20),
        KeyCode::PageUp => st.scroll = st.scroll.saturating_sub(20),
        KeyCode::Home => st.scroll = 0,
        KeyCode::Char('l') | KeyCode::Right => select(st, (st.src + 1) % len),
        KeyCode::Char('h') | KeyCode::Left => select(st, (st.src + len - 1) % len),
        KeyCode::Char('c') => {
            // Clear only the action output; a journal tail is not ours to clear.
            if st.src == 0 {
                st.lines.clear();
                st.scroll = 0;
            }
        }
        _ => {}
    }
    None
}

fn select(st: &mut State, src: usize) {
    if src == st.src {
        return;
    }
    st.src = src;
    st.scroll = 0;
    st.journal.clear();
    // Drop any in-flight answer for the old unit and re-tail immediately.
    st.pending = None;
    st.fetched_at = None;
    st.tail = Tail::Idle;
}

#[cfg(test)]
mod tests {
    use super::*;
    use crossterm::event::KeyModifiers;

    fn press(code: KeyCode) -> KeyEvent {
        KeyEvent::new(code, KeyModifiers::NONE)
    }

    #[test]
    fn push_keeps_the_pane_bounded_and_splits_lines() {
        let mut st = State::default();
        push(&mut st, "$ oligarchy-ctl run dsp-status\nline one\nline two");
        assert_eq!(st.lines.len(), 3);
        for i in 0..MAX_LINES {
            push(&mut st, &format!("line {i}"));
        }
        assert_eq!(st.lines.len(), MAX_LINES);
        let newest = format!("line {}", MAX_LINES - 1);
        assert_eq!(st.lines.last(), Some(&newest), "the oldest lines are what get dropped");
    }

    #[test]
    fn push_brings_the_operator_back_to_the_output_source() {
        let mut st = State::default();
        st.src = 3;
        st.scroll = 40;
        push(&mut st, "something happened");
        assert_eq!(st.src, 0);
        assert_eq!(st.scroll, 0);
    }

    /// `-- No entries --` is journalctl's zero-exit way of saying nothing, and
    /// it must never be mistaken for a log line.
    #[test]
    fn no_entries_is_empty_not_a_line() {
        let (lines, state) = classify("-- No entries --\n", false, Access::Full);
        assert!(lines.is_empty());
        assert_eq!(state, Tail::Empty);
    }

    /// The silent failure this pane exists to expose: a caller without journal
    /// access gets an empty, successful answer.
    #[test]
    fn empty_output_without_access_is_restricted_not_empty() {
        let (_, state) = classify("-- No entries --\n", false, Access::Restricted);
        assert_eq!(state, Tail::Restricted);
        // …but a *user* unit is in this user's own journal, so the system
        // journal ACL says nothing about it.
        let (_, state) = classify("", true, Access::Restricted);
        assert_eq!(state, Tail::Empty);
    }

    #[test]
    fn real_lines_beat_every_other_state() {
        let out = "Sep 17 21:45:42 nixos systemd[1]: Started Strict Egress.\n";
        let (lines, state) = classify(out, false, Access::Restricted);
        assert_eq!(state, Tail::Lines);
        assert_eq!(lines.len(), 1);
    }

    #[test]
    fn a_boot_marker_is_kept_but_blank_lines_are_not() {
        let out = "-- Boot 922d8fc6 --\n\n   \nreal line\n";
        let (lines, _) = classify(out, false, Access::Full);
        assert_eq!(lines, ["-- Boot 922d8fc6 --", "real line"]);
    }

    #[test]
    fn a_refusal_in_an_error_is_recognised() {
        assert!(is_denial("journalctl: Permission denied"));
        assert!(is_denial("Failed to open files: Access denied"));
        assert!(!is_denial("journalctl: timed out after 4s"));
    }

    #[test]
    fn every_curated_unit_is_named_once() {
        let mut seen: Vec<&str> = UNITS.iter().map(|u| u.unit).collect();
        seen.sort_unstable();
        let n = seen.len();
        seen.dedup();
        assert_eq!(seen.len(), n, "duplicate unit in the curated set");
        assert!(UNITS.iter().all(|u| !u.unit.is_empty() && !u.label.is_empty()));
    }

    #[test]
    fn source_selection_wraps_and_never_indexes_off_the_end() {
        let mut st = State::default();
        assert!(st.unit().is_none(), "source 0 is the action output, not a unit");
        for _ in 0..UNITS.len() + 1 {
            on_key(&mut st, press(KeyCode::Char('l')));
        }
        assert_eq!(st.src, 0);
        on_key(&mut st, press(KeyCode::Char('h')));
        assert_eq!(st.src, UNITS.len());
        assert_eq!(st.unit().map(|u| u.unit), UNITS.last().map(|u| u.unit));
        // …and nothing panics at any position.
        for i in 0..=UNITS.len() {
            st.src = i;
            let _ = st.unit();
        }
    }

    #[test]
    fn scrolling_saturates_instead_of_wrapping() {
        let mut st = State::default();
        on_key(&mut st, press(KeyCode::Up));
        assert_eq!(st.scroll, 0);
        on_key(&mut st, press(KeyCode::PageUp));
        assert_eq!(st.scroll, 0);
        st.scroll = u16::MAX;
        on_key(&mut st, press(KeyCode::Down));
        assert_eq!(st.scroll, u16::MAX);
    }

    #[test]
    fn clearing_only_ever_touches_the_action_output() {
        let mut st = State::default();
        push(&mut st, "a\nb");
        st.journal = vec!["kept".into()];
        st.src = 1;
        on_key(&mut st, press(KeyCode::Char('c')));
        assert_eq!(st.lines.len(), 2, "a journal tail is not ours to clear");
        st.src = 0;
        on_key(&mut st, press(KeyCode::Char('c')));
        assert!(st.lines.is_empty());
        assert_eq!(st.journal, ["kept"]);
    }

    /// Probing access must be side-effect free and never panic, whatever the
    /// host looks like.
    #[test]
    fn access_probe_answers_on_any_host() {
        assert!(matches!(
            access(),
            Access::Full | Access::Restricted | Access::Absent
        ));
    }
}
