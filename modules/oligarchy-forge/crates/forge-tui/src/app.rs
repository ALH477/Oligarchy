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
use std::sync::mpsc::Receiver;
use std::time::Duration;

const MAX_LOG_LINES: usize = 2000;
const TICK: Duration = Duration::from_millis(100);

struct App {
    projects: Vec<KnownProject>,
    selected: usize,
    log: VecDeque<String>,
    build_rx: Option<Receiver<BuildEvent>>,
    building: bool,
    status: String,
}

impl App {
    fn new() -> Result<Self> {
        Ok(App {
            projects: discover()?,
            selected: 0,
            log: VecDeque::new(),
            build_rx: None,
            building: false,
            status: "j/k: navigate  b/enter: build  r: refresh  q: quit".into(),
        })
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
    enable_raw_mode().context("enabling terminal raw mode")?;
    let mut stdout = std::io::stdout();
    execute!(stdout, EnterAlternateScreen).context("entering alternate screen")?;
    let backend = CrosstermBackend::new(stdout);
    let mut terminal = Terminal::new(backend).context("creating terminal")?;

    let result = run_app(&mut terminal);

    disable_raw_mode().ok();
    execute!(terminal.backend_mut(), LeaveAlternateScreen).ok();

    result
}

fn run_app(terminal: &mut Terminal<CrosstermBackend<Stdout>>) -> Result<()> {
    let mut app = App::new()?;

    loop {
        terminal.draw(|frame| draw(frame, &app))?;
        app.poll_build();

        if event::poll(TICK)? {
            if let Event::Key(key) = event::read()? {
                if key.kind != KeyEventKind::Press {
                    continue;
                }
                match key.code {
                    KeyCode::Char('q') | KeyCode::Esc => return Ok(()),
                    KeyCode::Char('j') | KeyCode::Down => {
                        if !app.projects.is_empty() {
                            app.selected = (app.selected + 1).min(app.projects.len() - 1);
                        }
                    }
                    KeyCode::Char('k') | KeyCode::Up => {
                        app.selected = app.selected.saturating_sub(1);
                    }
                    KeyCode::Char('r') => {
                        app.projects = discover()?;
                        app.status = "refreshed".into();
                    }
                    KeyCode::Char('b') | KeyCode::Enter => app.start_build(),
                    _ => {}
                }
            }
        }
    }
}

fn draw(frame: &mut Frame, app: &App) {
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
    draw_status(frame, root[1], app);
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

fn draw_status(frame: &mut Frame, area: Rect, app: &App) {
    let paragraph = Paragraph::new(app.status.as_str()).style(Style::default().fg(Color::DarkGray));
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

    fn rendered_text(app: &App) -> String {
        let backend = TestBackend::new(80, 24);
        let mut terminal = Terminal::new(backend).unwrap();
        terminal.draw(|frame| draw(frame, app)).unwrap();
        terminal
            .backend()
            .buffer()
            .content()
            .iter()
            .map(|cell| cell.symbol())
            .collect()
    }

    #[test]
    fn session_list_shows_discovered_project_names() {
        let app = App {
            projects: vec![sample_project("demo-project", true)],
            selected: 0,
            log: VecDeque::new(),
            build_rx: None,
            building: false,
            status: "test".into(),
        };
        let text = rendered_text(&app);
        assert!(text.contains("demo-project"), "rendered output:\n{text}");
        assert!(text.contains("rust"), "rendered output:\n{text}");
    }

    #[test]
    fn empty_session_list_shows_a_hint_instead_of_a_blank_pane() {
        let app = App {
            projects: vec![],
            selected: 0,
            log: VecDeque::new(),
            build_rx: None,
            building: false,
            status: "test".into(),
        };
        let text = rendered_text(&app);
        assert!(text.contains("no projects built yet"), "rendered output:\n{text}");
    }

    #[test]
    fn build_log_lines_appear_in_the_log_pane() {
        let mut app = App {
            projects: vec![sample_project("demo-project", false)],
            selected: 0,
            log: VecDeque::new(),
            build_rx: None,
            building: true,
            status: "test".into(),
        };
        app.push_log("copying path '/nix/store/abc-example'".into());
        let text = rendered_text(&app);
        assert!(text.contains("copying path"), "rendered output:\n{text}");
        assert!(text.contains("running"), "rendered output:\n{text}"); // "(running)" in the log pane title
    }
}
