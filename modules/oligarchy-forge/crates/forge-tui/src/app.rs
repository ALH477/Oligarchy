use crate::edit::{EditState, EvalStatus, SELECTABLE};
use crate::project::{discover, KnownProject};
use anyhow::{Context, Result};
use crossterm::event::{self, Event, KeyCode, KeyEventKind};
use crossterm::execute;
use crossterm::terminal::{disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen};
use forge_core::stream::{build_and_load_streaming, BuildEvent};
use ratatui::backend::CrosstermBackend;
use ratatui::layout::{Constraint, Direction, Layout, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, List, ListItem, ListState, Paragraph, Wrap};
use ratatui::{Frame, Terminal};
use std::collections::VecDeque;
use std::io::Stdout;
use std::path::PathBuf;
use std::sync::mpsc::Receiver;
use std::time::Duration;
use tui_tree_widget::{Tree, TreeItem};

const MAX_LOG_LINES: usize = 2000;
const TICK: Duration = Duration::from_millis(100);

enum Mode {
    Sessions,
    Edit(EditState),
}

struct App {
    mode: Mode,
    projects: Vec<KnownProject>,
    selected: usize,
    log: VecDeque<String>,
    build_rx: Option<Receiver<BuildEvent>>,
    building: bool,
    status: String,
}

fn cwd_project_name() -> String {
    std::env::current_dir()
        .ok()
        .and_then(|p| p.file_name().map(|n| n.to_string_lossy().into_owned()))
        .unwrap_or_else(|| "project".into())
}

impl App {
    fn new() -> Result<Self> {
        Ok(App {
            mode: Mode::Sessions,
            projects: discover()?,
            selected: 0,
            log: VecDeque::new(),
            build_rx: None,
            building: false,
            status: "j/k: navigate  b/enter: build  e: edit this dir  r: refresh  q: quit".into(),
        })
    }

    fn enter_edit_mode(&mut self) {
        let path = PathBuf::from("oligarchy-forge.toml");
        match EditState::open(path, &cwd_project_name()) {
            Ok(state) => self.mode = Mode::Edit(state),
            Err(e) => self.status = format!("failed to open oligarchy-forge.toml: {e:#}"),
        }
    }

    fn selected_project(&self) -> Option<&KnownProject> {
        self.projects.get(self.selected)
    }

    fn push_log(&mut self, line: String) {
        self.log.push_back(line);
        while self.log.len() > MAX_LOG_LINES {
            self.log.pop_front();
        }
    }

    fn start_build(&mut self) {
        if self.building {
            return;
        }
        let Some(project) = self.selected_project() else {
            self.status = "no project selected".into();
            return;
        };
        let cfg = project.cfg.clone();
        let name = cfg.project.name.clone();
        match build_and_load_streaming(cfg) {
            Ok(rx) => {
                self.log.clear();
                self.push_log(format!("== building {name} =="));
                self.build_rx = Some(rx);
                self.building = true;
                self.status = format!("building {name}...");
            }
            Err(e) => {
                self.status = format!("failed to start build: {e:#}");
            }
        }
    }

    /// Drains any pending build events without blocking. Called once per
    /// tick regardless of whether a build is in flight.
    fn poll_build(&mut self) {
        // Take the receiver out so `self` isn't borrowed while push_log
        // (below) needs `&mut self` — put it back at the end if the build
        // is still in flight.
        let Some(rx) = self.build_rx.take() else { return };
        let mut still_running = true;

        loop {
            match rx.try_recv() {
                Ok(BuildEvent::Line(line)) => self.push_log(line),
                Ok(BuildEvent::Done(result)) => {
                    self.building = false;
                    still_running = false;
                    match result {
                        Ok(()) => {
                            self.push_log("== build + load succeeded ==".into());
                            self.status = "build succeeded".into();
                        }
                        Err(e) => {
                            self.push_log(format!("== build failed: {e} =="));
                            self.status = "build failed — see log".into();
                        }
                    }
                    // Refresh built/not-built state for the session list.
                    if let Ok(projects) = discover() {
                        self.projects = projects;
                    }
                    break;
                }
                Err(std::sync::mpsc::TryRecvError::Empty) => break,
                Err(std::sync::mpsc::TryRecvError::Disconnected) => {
                    self.building = false;
                    still_running = false;
                    break;
                }
            }
        }

        if still_running {
            self.build_rx = Some(rx);
        }
    }
}

pub fn run() -> Result<()> {
    run_with(Mode::Sessions)
}

/// Launches straight into the extension-picker for the current directory
/// (`oligarchy-forge edit`), instead of the session-list dashboard.
pub fn run_edit() -> Result<()> {
    let path = PathBuf::from("oligarchy-forge.toml");
    let state = EditState::open(path, &cwd_project_name())?;
    run_with(Mode::Edit(state))
}

fn run_with(mode: Mode) -> Result<()> {
    enable_raw_mode().context("enabling terminal raw mode")?;
    let mut stdout = std::io::stdout();
    execute!(stdout, EnterAlternateScreen).context("entering alternate screen")?;
    let backend = CrosstermBackend::new(stdout);
    let mut terminal = Terminal::new(backend).context("creating terminal")?;

    let mut app = App::new()?;
    app.mode = mode;

    let result = run_app(&mut terminal, &mut app);

    disable_raw_mode().ok();
    execute!(terminal.backend_mut(), LeaveAlternateScreen).ok();

    result
}

fn run_app(terminal: &mut Terminal<CrosstermBackend<Stdout>>, app: &mut App) -> Result<()> {
    loop {
        terminal.draw(|frame| draw(frame, app))?;
        app.poll_build();
        if let Mode::Edit(state) = &mut app.mode {
            state.poll_eval();
        }

        if event::poll(TICK)? {
            if let Event::Key(key) = event::read()? {
                if key.kind != KeyEventKind::Press {
                    continue;
                }
                match &mut app.mode {
                    Mode::Sessions => {
                        if !handle_sessions_key(app, key.code) {
                            return Ok(());
                        }
                    }
                    Mode::Edit(_) => {
                        if handle_edit_key(app, key.code) {
                            return Ok(());
                        }
                    }
                }
            }
        }
    }
}

/// Returns `false` to quit the whole program.
fn handle_sessions_key(app: &mut App, code: KeyCode) -> bool {
    match code {
        KeyCode::Char('q') | KeyCode::Esc => return false,
        KeyCode::Char('j') | KeyCode::Down => {
            if !app.projects.is_empty() {
                app.selected = (app.selected + 1).min(app.projects.len() - 1);
            }
        }
        KeyCode::Char('k') | KeyCode::Up => {
            app.selected = app.selected.saturating_sub(1);
        }
        KeyCode::Char('r') => {
            if let Ok(projects) = discover() {
                app.projects = projects;
            }
            app.status = "refreshed".into();
        }
        KeyCode::Char('b') | KeyCode::Enter => app.start_build(),
        KeyCode::Char('e') => app.enter_edit_mode(),
        _ => {}
    }
    true
}

/// Returns `true` to quit the whole program (only on `q` — `Esc` backs out
/// to the session list instead, matching the doc's "additive over the CLI"
/// framing: edit mode is a detour, not a dead end).
fn handle_edit_key(app: &mut App, code: KeyCode) -> bool {
    let Mode::Edit(state) = &mut app.mode else { return false };

    if state.pending_conflict.is_some() {
        match code {
            KeyCode::Char('n') | KeyCode::Enter | KeyCode::Right => state.resolve_conflict_keep_new(),
            KeyCode::Char('e') | KeyCode::Esc | KeyCode::Left => state.resolve_conflict_keep_existing(),
            _ => {}
        }
        return false;
    }

    match code {
        KeyCode::Char('q') => return true,
        KeyCode::Esc => app.mode = Mode::Sessions,
        KeyCode::Char('j') | KeyCode::Down => {
            state.tree_state.key_down();
        }
        KeyCode::Char('k') | KeyCode::Up => {
            state.tree_state.key_up();
        }
        KeyCode::Char(' ') | KeyCode::Enter => {
            if let Some(ext) = state.highlighted() {
                state.toggle(ext);
            }
        }
        _ => {}
    }
    false
}

fn draw(frame: &mut Frame, app: &mut App) {
    // if-let (rather than a `match &mut app.mode`) so the `else` branch's
    // borrow of `app.mode` ends before `draw_sessions` needs the rest of
    // `app` — the tree widget is the only thing here that needs `&mut`.
    if let Mode::Edit(state) = &mut app.mode {
        draw_edit(frame, state);
    } else {
        draw_sessions(frame, app);
    }
}

fn draw_sessions(frame: &mut Frame, app: &App) {
    let root = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Min(1), Constraint::Length(1)])
        .split(frame.area());

    let panes = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([Constraint::Percentage(30), Constraint::Percentage(70)])
        .split(root[0]);

    let right = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Length(2), Constraint::Min(1)])
        .split(panes[1]);

    draw_project_list(frame, panes[0], app);
    draw_detail(frame, right[0], app);
    draw_log(frame, right[1], app);
    draw_status(frame, root[1], app.status.as_str());
}

fn draw_project_list(frame: &mut Frame, area: Rect, app: &App) {
    // Kept to just the built marker + name: the pane is narrow (roughly a
    // third of the terminal width) and cramming the extension list in here
    // truncates mid-word at typical widths — the full detail lives in
    // draw_detail() for the selected project instead.
    let items: Vec<ListItem> = if app.projects.is_empty() {
        vec![ListItem::new("(no projects built yet — run `oligarchy-forge build` in a project)")]
    } else {
        app.projects
            .iter()
            .map(|p| {
                let mark = if p.built { "●" } else { "○" };
                let color = if p.built { Color::Green } else { Color::DarkGray };
                ListItem::new(Line::from(vec![
                    Span::styled(format!("{mark} "), Style::default().fg(color)),
                    Span::raw(p.cfg.project.name.clone()),
                ]))
            })
            .collect()
    };

    let mut state = ListState::default();
    if !app.projects.is_empty() {
        state.select(Some(app.selected));
    }

    let list = List::new(items)
        .block(Block::default().borders(Borders::ALL).title(" sessions "))
        .highlight_style(Style::default().add_modifier(Modifier::BOLD).bg(Color::DarkGray));

    frame.render_stateful_widget(list, area, &mut state);
}

fn draw_detail(frame: &mut Frame, area: Rect, app: &App) {
    // Two lines, wrapped rather than truncated — a project with several
    // extensions plus a long name can exceed one 80-column line; wrapping
    // keeps the info intact instead of silently cutting it off.
    let text = match app.selected_project() {
        Some(p) => format!(
            "{}  ({:?}/{:?})\nextensions: {}",
            p.cfg.project.name,
            p.cfg.runtime.backend,
            p.cfg.runtime.volume_mode,
            p.extensions_summary()
        ),
        None => String::new(),
    };
    let paragraph = Paragraph::new(text)
        .style(Style::default().add_modifier(Modifier::BOLD))
        .wrap(Wrap { trim: false });
    frame.render_widget(paragraph, area);
}

fn draw_log(frame: &mut Frame, area: Rect, app: &App) {
    let visible_height = area.height.saturating_sub(2) as usize; // minus borders
    let start = app.log.len().saturating_sub(visible_height);
    let text: Vec<Line> = app.log.iter().skip(start).map(|l| Line::from(l.as_str())).collect();

    let title = if app.building { " build log (running) " } else { " build log " };
    let paragraph = Paragraph::new(text)
        .block(Block::default().borders(Borders::ALL).title(title))
        .wrap(Wrap { trim: false });

    frame.render_widget(paragraph, area);
}

fn draw_status(frame: &mut Frame, area: Rect, status: &str) {
    let paragraph = Paragraph::new(status).style(Style::default().fg(Color::DarkGray));
    frame.render_widget(paragraph, area);
}

fn draw_edit(frame: &mut Frame, state: &mut EditState) {
    let root = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Min(1), Constraint::Length(1)])
        .split(frame.area());

    let panes = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([Constraint::Percentage(40), Constraint::Percentage(60)])
        .split(root[0]);

    draw_extension_tree(frame, panes[0], state);
    if let Some(conflict) = &state.pending_conflict {
        draw_conflict_chooser(frame, panes[1], conflict);
    } else {
        draw_edit_side_panel(frame, panes[1], state);
    }
    draw_status(frame, root[1], state.status.as_str());
}

fn draw_extension_tree(frame: &mut Frame, area: Rect, state: &mut EditState) {
    let leaves: Vec<TreeItem<&'static str>> = SELECTABLE
        .iter()
        .map(|ext| {
            let checked = if state.is_selected(*ext) { "[x]" } else { "[ ]" };
            TreeItem::new_leaf(ext.label(), format!("{checked} {}", ext.label()))
        })
        .collect();
    let items = vec![TreeItem::new("extensions", "Extensions (base always included)", leaves)
        .expect("leaf identifiers are all distinct extension labels")];

    let tree = Tree::new(&items)
        .expect("tree item identifiers are unique")
        .block(Block::default().borders(Borders::ALL).title(" extensions "))
        .highlight_style(Style::default().add_modifier(Modifier::BOLD).bg(Color::DarkGray));

    frame.render_stateful_widget(tree, area, &mut state.tree_state);
}

fn draw_edit_side_panel(frame: &mut Frame, area: Rect, state: &EditState) {
    let rows = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Length(3), Constraint::Min(1)])
        .split(area);

    let eval_line = match &state.eval_status {
        EvalStatus::Idle => "flake: (no changes yet)".to_string(),
        EvalStatus::Checking => "flake: checking...".to_string(),
        EvalStatus::Ok => "flake: OK".to_string(),
        EvalStatus::Error(e) => format!("flake: ERROR — {e}"),
    };
    let eval_color = match state.eval_status {
        EvalStatus::Ok => Color::Green,
        EvalStatus::Error(_) => Color::Red,
        _ => Color::DarkGray,
    };
    frame.render_widget(
        Paragraph::new(eval_line).style(Style::default().fg(eval_color)).wrap(Wrap { trim: false }),
        rows[0],
    );

    let summary = format!(
        "project: {}\nbackend: {:?}\nvolume: {:?}\nextensions: {}",
        state.cfg.project.name,
        state.cfg.runtime.backend,
        state.cfg.runtime.volume_mode,
        state
            .cfg
            .project
            .extensions
            .iter()
            .map(|e| e.label())
            .collect::<Vec<_>>()
            .join(", ")
    );
    frame.render_widget(
        Paragraph::new(summary)
            .block(Block::default().borders(Borders::ALL).title(" oligarchy-forge.toml "))
            .wrap(Wrap { trim: false }),
        rows[1],
    );
}

fn draw_conflict_chooser(frame: &mut Frame, area: Rect, conflict: &crate::edit::PendingConflict) {
    let text = format!(
        "{} and {} both provide: {}\n\nKeep existing ({})  [e/esc/←]\nSwitch to new ({})  [n/enter/→]",
        conflict.existing.label(),
        conflict.new.label(),
        conflict.shared.join(", "),
        conflict.existing.label(),
        conflict.new.label(),
    );
    let paragraph = Paragraph::new(text)
        .block(
            Block::default()
                .borders(Borders::ALL)
                .title(" conflict — pick one ")
                .border_style(Style::default().fg(Color::Yellow)),
        )
        .wrap(Wrap { trim: false });
    frame.render_widget(paragraph, area);
}

#[cfg(test)]
mod tests {
    use super::*;
    use forge_core::ForgeConfig;
    use ratatui::backend::TestBackend;

    fn sample_project(name: &str, built: bool) -> KnownProject {
        let cfg = ForgeConfig::parse(&format!(
            "[project]\nname = \"{name}\"\nextensions = [\"rust\"]\n"
        ))
        .unwrap();
        KnownProject { cfg, built }
    }

    fn rendered_text_from(draw_fn: impl FnOnce(&mut Frame)) -> String {
        let backend = TestBackend::new(80, 24);
        let mut terminal = Terminal::new(backend).unwrap();
        terminal.draw(|frame| draw_fn(frame)).unwrap();
        terminal.backend().buffer().content().iter().map(|cell| cell.symbol()).collect()
    }

    fn rendered_text(app: &mut App) -> String {
        rendered_text_from(|frame| draw(frame, app))
    }

    #[test]
    fn session_list_shows_discovered_project_names() {
        let mut app = App {
            mode: Mode::Sessions,
            projects: vec![sample_project("demo-project", true)],
            selected: 0,
            log: VecDeque::new(),
            build_rx: None,
            building: false,
            status: "test".into(),
        };
        let text = rendered_text(&mut app);
        assert!(text.contains("demo-project"), "rendered output:\n{text}");
        assert!(text.contains("rust"), "rendered output:\n{text}");
    }

    #[test]
    fn empty_session_list_shows_a_hint_instead_of_a_blank_pane() {
        let mut app = App {
            mode: Mode::Sessions,
            projects: vec![],
            selected: 0,
            log: VecDeque::new(),
            build_rx: None,
            building: false,
            status: "test".into(),
        };
        let text = rendered_text(&mut app);
        assert!(text.contains("no projects built yet"), "rendered output:\n{text}");
    }

    #[test]
    fn build_log_lines_appear_in_the_log_pane() {
        let mut app = App {
            mode: Mode::Sessions,
            projects: vec![sample_project("demo-project", false)],
            selected: 0,
            log: VecDeque::new(),
            build_rx: None,
            building: true,
            status: "test".into(),
        };
        app.push_log("copying path '/nix/store/abc-example'".into());
        let text = rendered_text(&mut app);
        assert!(text.contains("copying path"), "rendered output:\n{text}");
        assert!(text.contains("running"), "rendered output:\n{text}"); // "(running)" in the log pane title
    }

    fn edit_state_for(dir: &std::path::Path, extensions: &[&str]) -> EditState {
        let toml_str = format!(
            "[project]\nname = \"edit-test\"\nextensions = [{}]\n",
            extensions.iter().map(|e| format!("\"{e}\"")).collect::<Vec<_>>().join(", ")
        );
        let path = dir.join("oligarchy-forge.toml");
        std::fs::write(&path, toml_str).unwrap();
        EditState::open(path, "edit-test").unwrap()
    }

    #[test]
    fn key_down_navigation_lands_on_a_leaf_after_two_presses() {
        // tui-tree-widget's key_down/key_up rely on TreeState::last_identifiers,
        // only populated as a side effect of rendering — so the first
        // key_down (no render yet) would silently no-op if we skipped this.
        // Caught via a real 0x0-area interactive pty run showing highlighted()
        // stuck at None; this is the regression test for that root cause.
        let dir = std::env::temp_dir().join(format!("forge-tui-edit-test-{}-nav", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let mut state = edit_state_for(&dir, &[]);

        rendered_text_from(|frame| draw_edit(frame, &mut state));

        assert!(state.tree_state.key_down()); // -> "extensions" category node
        assert!(state.tree_state.key_down()); // -> first leaf
        assert_eq!(state.highlighted(), Some(forge_core::schema::Extension::Rust));

        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn extension_tree_shows_checked_and_unchecked_extensions() {
        let dir = std::env::temp_dir().join(format!("forge-tui-edit-test-{}-tree", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let mut state = edit_state_for(&dir, &["rust"]);

        let text = rendered_text_from(|frame| draw_edit(frame, &mut state));
        assert!(text.contains("[x] rust"), "rendered output:\n{text}");
        assert!(text.contains("[ ] python") || text.contains("[ ]python"), "rendered output:\n{text}");

        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn toggling_node_then_node_lts_shows_conflict_chooser() {
        let dir = std::env::temp_dir().join(format!("forge-tui-edit-test-{}-conflict", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let mut state = edit_state_for(&dir, &["node"]);

        state.toggle(forge_core::schema::Extension::NodeLts);
        assert!(state.pending_conflict.is_some());

        let text = rendered_text_from(|frame| draw_edit(frame, &mut state));
        assert!(text.contains("conflict"), "rendered output:\n{text}");
        assert!(text.contains("node"), "rendered output:\n{text}");

        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn resolving_conflict_keep_new_swaps_extensions() {
        let dir = std::env::temp_dir().join(format!("forge-tui-edit-test-{}-resolve", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let mut state = edit_state_for(&dir, &["node"]);

        state.toggle(forge_core::schema::Extension::NodeLts);
        state.resolve_conflict_keep_new();

        assert!(state.pending_conflict.is_none());
        assert!(state.is_selected(forge_core::schema::Extension::NodeLts));
        assert!(!state.is_selected(forge_core::schema::Extension::Node));

        // Write-back happened as part of the resolution.
        let raw = std::fs::read_to_string(dir.join("oligarchy-forge.toml")).unwrap();
        assert!(raw.contains("node-lts"));
        assert!(!raw.contains("\"node\""));

        std::fs::remove_dir_all(&dir).ok();
    }
}
