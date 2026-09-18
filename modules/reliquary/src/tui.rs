use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::time::Duration;

use crossterm::event::{self, Event, KeyCode, KeyEventKind};
use crossterm::execute;
use crossterm::terminal::{disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen};
use ratatui::backend::CrosstermBackend;
use ratatui::layout::{Constraint, Direction, Layout};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, List, ListItem, ListState, Paragraph, Wrap};
use ratatui::Terminal;

use crate::config::Config;
use crate::optical;
use crate::store::Store;
use crate::usb;

#[derive(Clone, Copy, PartialEq, Eq)]
enum Focus {
    Browser,
    Blocks,
}

struct FsRow {
    label: String,
    path: PathBuf,
    is_dir: bool,
    kind: RowKind,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum RowKind {
    Here,
    Parent,
    Dir,
    File,
}

pub fn run() -> anyhow::Result<()> {
    let cfg = Config::load();
    let store = Store::new(cfg.clone())?;
    enable_raw_mode()?;
    let mut stdout = io::stdout();
    execute!(stdout, EnterAlternateScreen)?;
    let backend = CrosstermBackend::new(stdout);
    let mut terminal = Terminal::new(backend)?;
    let result = run_app(&mut terminal, store);
    disable_raw_mode()?;
    execute!(terminal.backend_mut(), LeaveAlternateScreen)?;
    terminal.show_cursor()?;
    result
}

struct App {
    store: Store,
    cwd: PathBuf,
    rows: Vec<FsRow>,
    browser: ListState,
    blocks: Vec<String>,
    block_list: ListState,
    focus: Focus,
    log: Vec<String>,
    cmd: String,
    composing: bool,
    status: String,
    profile: String,
}

impl App {
    fn new(store: Store) -> Self {
        let cwd = std::env::current_dir()
            .or_else(|_| std::env::var("HOME").map(PathBuf::from))
            .unwrap_or_else(|_| PathBuf::from("/"));
        let mut app = Self {
            store,
            cwd,
            rows: Vec::new(),
            browser: ListState::default(),
            blocks: Vec::new(),
            block_list: ListState::default(),
            focus: Focus::Browser,
            log: vec![
                "Select a directory and press Enter or b to pack it into a block.".into(),
                "Tab switches panes. c toggles cd/usb profile. q quits.".into(),
            ],
            cmd: String::new(),
            composing: false,
            status: String::new(),
            profile: "cd".into(),
        };
        app.reload_browser();
        app.refresh_blocks();
        app
    }

    fn selected_block(&self) -> Option<String> {
        self.block_list
            .selected()
            .and_then(|i| self.blocks.get(i).cloned())
    }

    fn selected_row(&self) -> Option<&FsRow> {
        self.browser.selected().and_then(|i| self.rows.get(i))
    }

    fn reload_browser(&mut self) {
        let mut rows = vec![
            FsRow {
                label: ".   (this directory)".into(),
                path: self.cwd.clone(),
                is_dir: true,
                kind: RowKind::Here,
            },
            FsRow {
                label: "..  (parent)".into(),
                path: self.cwd.parent().unwrap_or(&self.cwd).to_path_buf(),
                is_dir: true,
                kind: RowKind::Parent,
            },
        ];
        let mut dirs = Vec::new();
        let mut files = Vec::new();
        match fs::read_dir(&self.cwd) {
            Ok(rd) => {
                for entry in rd.flatten() {
                    let path = entry.path();
                    let name = entry.file_name().to_string_lossy().into_owned();
                    let is_dir = path.is_dir();
                    if is_dir {
                        dirs.push(FsRow {
                            label: format!("{name}/"),
                            path,
                            is_dir: true,
                            kind: RowKind::Dir,
                        });
                    } else {
                        files.push(FsRow {
                            label: name,
                            path,
                            is_dir: false,
                            kind: RowKind::File,
                        });
                    }
                }
            }
            Err(err) => self.log_line(format!("cannot read {}: {err}", self.cwd.display())),
        }
        dirs.sort_by(|a, b| a.label.to_lowercase().cmp(&b.label.to_lowercase()));
        files.sort_by(|a, b| a.label.to_lowercase().cmp(&b.label.to_lowercase()));
        rows.extend(dirs);
        rows.extend(files);
        self.rows = rows;
        self.browser.select(Some(0));
    }

    fn enter_dir(&mut self, path: PathBuf) {
        if path.is_dir() {
            self.cwd = path;
            self.reload_browser();
        }
    }

    fn go_parent(&mut self) {
        if let Some(parent) = self.cwd.parent() {
            self.cwd = parent.to_path_buf();
            self.reload_browser();
        }
    }

    fn refresh_blocks(&mut self) {
        self.blocks = self
            .store
            .list_blocks()
            .unwrap_or_default()
            .into_iter()
            .filter_map(|m| m.get("id").and_then(|v| v.as_str()).map(|s| s.to_string()))
            .collect();
        if self.block_list.selected().is_none() && !self.blocks.is_empty() {
            self.block_list.select(Some(0));
        }
        let usb = usb::volume_status(&self.store.cfg).unwrap_or(serde_json::json!({}));
        let mut lines = vec![format!(
            "store {}   blocks={}   profile={}   par2={}%",
            self.store.cfg.store_root.display(),
            self.blocks.len(),
            self.profile,
            self.store.cfg.par2_redundancy
        )];
        for role in ["A", "B"] {
            let info = &usb[role];
            let flag = if info["ready"].as_bool() == Some(true) {
                "READY"
            } else if info["present"].as_bool() == Some(true) {
                "SEEN"
            } else {
                "ABSENT"
            };
            let mp = info["data"]["mountpoint"].as_str().unwrap_or("—");
            lines.push(format!(
                "USB-{role}  {flag}  {} @ {mp}",
                info["data"]["label"].as_str().unwrap_or("?")
            ));
        }
        self.status = lines.join("\n");
    }

    fn log_line(&mut self, s: impl Into<String>) {
        self.log.push(s.into());
        if self.log.len() > 200 {
            self.log.remove(0);
        }
    }

    fn pack_path(&mut self, path: PathBuf) {
        if !path.exists() {
            self.log_line(format!("no such path: {}", path.display()));
            return;
        }
        let profile = self.profile.clone();
        self.log_line(format!(
            "packing {}  profile={profile} …",
            path.display()
        ));
        match self.store.ingest(&path, &profile, "", false) {
            Ok(man) => {
                let id = man
                    .get("id")
                    .and_then(|v| v.as_str())
                    .unwrap_or("?")
                    .to_string();
                let bytes = man
                    .get("payload")
                    .and_then(|p| p.get("bytes"))
                    .and_then(|v| v.as_u64())
                    .unwrap_or(0);
                self.log_line(format!("ingested {id}  {bytes} B from {}", path.display()));
                if let Some(idx) = self.blocks.iter().position(|b| b == &id) {
                    self.block_list.select(Some(idx));
                }
            }
            Err(err) => self.log_line(format!("error: {err}")),
        }
        self.refresh_blocks();
    }

    fn pack_selection(&mut self) {
        match self.selected_row() {
            Some(row) if row.kind == RowKind::Parent => {
                self.log_line("select . or a child directory, not ..");
            }
            Some(row) => {
                let path = row.path.clone();
                self.pack_path(path);
            }
            None => self.log_line("nothing selected"),
        }
    }

    fn toggle_profile(&mut self) {
        self.profile = if self.profile == "cd" {
            "usb".into()
        } else {
            "cd".into()
        };
        self.log_line(format!("profile={}", self.profile));
        self.refresh_blocks();
    }

    fn move_list(state: &mut ListState, len: usize, delta: isize) {
        if len == 0 {
            return;
        }
        let cur = state.selected().unwrap_or(0) as isize;
        let next = (cur + delta).clamp(0, len as isize - 1) as usize;
        state.select(Some(next));
    }

    fn run_command(&mut self, raw: &str) {
        let raw = raw.trim().trim_start_matches(':');
        self.log_line(format!("» {raw}"));
        let parts: Vec<&str> = raw.split_whitespace().collect();
        if parts.is_empty() {
            return;
        }
        match parts[0] {
            "ingest" | "pack" if parts.len() >= 2 => {
                if let Some(p) = parts.get(2) {
                    if *p == "cd" || *p == "usb" {
                        self.profile = (*p).into();
                    }
                }
                self.pack_path(PathBuf::from(parts[1]));
            }
            "cd" if parts.len() >= 2 => {
                let path = PathBuf::from(parts[1]);
                if path.is_dir() {
                    self.enter_dir(path);
                } else {
                    self.log_line(format!("not a directory: {}", parts[1]));
                }
            }
            "verify" if parts.len() >= 2 => match self.store.verify(parts[1], parts.contains(&"--repair"))
            {
                Ok(r) if r["ok"].as_bool() == Some(true) => self.log_line("OK"),
                Ok(r) => self.log_line(format!("FAILED {}", r["checksum_problems"])),
                Err(e) => self.log_line(format!("error: {e}")),
            },
            "push" if parts.len() >= 2 => match usb::push_block(&self.store.cfg, &self.store, parts[1], "AB")
            {
                Ok(v) => self.log_line(v.to_string()),
                Err(e) => self.log_line(format!("error: {e}")),
            },
            "iso" if parts.len() >= 2 => match crate::store::validate_block_id(parts[1])
                .and_then(|()| optical::make_iso(&self.store.cfg, &self.store, parts[1]))
            {
                Ok(p) => self.log_line(format!(
                    "ISO {} ({} B)",
                    p.display(),
                    p.metadata().map(|m| m.len()).unwrap_or(0)
                )),
                Err(e) => self.log_line(format!("error: {e}")),
            },
            "extract" if parts.len() >= 3 => {
                match self.store.extract(parts[1], Path::new(parts[2]), true) {
                    Ok(p) => self.log_line(format!("extracted to {}", p.display())),
                    Err(e) => self.log_line(format!("error: {e}")),
                }
            }
            "profile" if parts.len() >= 2 => {
                if parts[1] == "cd" || parts[1] == "usb" {
                    self.profile = parts[1].into();
                    self.refresh_blocks();
                    self.log_line(format!("profile={}", self.profile));
                }
            }
            "status" => {
                self.refresh_blocks();
                self.log_line("refreshed");
            }
            "help" => self.log_line(
                "Enter/b pack dir  Tab pane  c profile  h parent  v verify  p push  i iso",
            ),
            other => self.log_line(format!("unknown command {other}")),
        }
        self.refresh_blocks();
    }
}

fn run_app(
    terminal: &mut Terminal<CrosstermBackend<io::Stdout>>,
    store: Store,
) -> anyhow::Result<()> {
    let mut app = App::new(store);
    loop {
        terminal.draw(|f| {
            let chunks = Layout::default()
                .direction(Direction::Vertical)
                .constraints([
                    Constraint::Length(5),
                    Constraint::Min(8),
                    Constraint::Length(3),
                ])
                .split(f.size());
            let mid = Layout::default()
                .direction(Direction::Horizontal)
                .constraints([
                    Constraint::Percentage(38),
                    Constraint::Percentage(24),
                    Constraint::Percentage(38),
                ])
                .split(chunks[1]);

            let status = Paragraph::new(app.status.clone())
                .style(Style::default().fg(Color::Rgb(230, 217, 162)))
                .block(
                    Block::default()
                        .title(" Reliquary ")
                        .borders(Borders::ALL)
                        .border_style(border(false)),
                );
            f.render_widget(status, chunks[0]);

            let browser_title = format!(" Directories  {} ", app.cwd.display());
            let items: Vec<ListItem> = app
                .rows
                .iter()
                .map(|row| {
                    let style = match row.kind {
                        RowKind::Here => Style::default()
                            .fg(Color::Rgb(215, 247, 208))
                            .add_modifier(Modifier::BOLD),
                        RowKind::Parent => Style::default().fg(Color::Rgb(160, 160, 140)),
                        RowKind::Dir => Style::default().fg(Color::Rgb(180, 220, 190)),
                        RowKind::File => Style::default().fg(Color::Rgb(110, 110, 110)),
                    };
                    ListItem::new(row.label.as_str()).style(style)
                })
                .collect();
            let list = List::new(items)
                .block(
                    Block::default()
                        .title(browser_title)
                        .borders(Borders::ALL)
                        .border_style(border(app.focus == Focus::Browser)),
                )
                .highlight_style(
                    Style::default()
                        .bg(Color::Rgb(27, 42, 34))
                        .fg(Color::Rgb(215, 247, 208))
                        .add_modifier(Modifier::BOLD),
                )
                .highlight_symbol("▸ ");
            f.render_stateful_widget(list, mid[0], &mut app.browser);

            let items: Vec<ListItem> = app
                .blocks
                .iter()
                .map(|id| ListItem::new(id.as_str()))
                .collect();
            let list = List::new(items)
                .block(
                    Block::default()
                        .title(" Blocks ")
                        .borders(Borders::ALL)
                        .border_style(border(app.focus == Focus::Blocks)),
                )
                .highlight_style(
                    Style::default()
                        .bg(Color::Rgb(27, 42, 34))
                        .fg(Color::Rgb(215, 247, 208))
                        .add_modifier(Modifier::BOLD),
                )
                .highlight_symbol("▸ ");
            f.render_stateful_widget(list, mid[1], &mut app.block_list);

            let log_text: Vec<Line> = app
                .log
                .iter()
                .rev()
                .take(40)
                .collect::<Vec<_>>()
                .into_iter()
                .rev()
                .map(|s| Line::from(Span::raw(s.clone())))
                .collect();
            let log = Paragraph::new(log_text).wrap(Wrap { trim: false }).block(
                Block::default()
                    .title(" Log ")
                    .borders(Borders::ALL)
                    .border_style(border(false)),
            );
            f.render_widget(log, mid[2]);

            let prompt = if app.composing {
                format!(":{}", app.cmd)
            } else {
                format!(
                    "Tab pane  Enter open dir  b pack  c profile={}  h parent  v verify  p push  i iso  q quit",
                    app.profile
                )
            };
            let cmd = Paragraph::new(prompt).block(
                Block::default()
                    .title(" Command ")
                    .borders(Borders::ALL)
                    .border_style(border(app.composing)),
            );
            f.render_widget(cmd, chunks[2]);
        })?;

        if event::poll(Duration::from_millis(200))? {
            if let Event::Key(key) = event::read()? {
                if key.kind != KeyEventKind::Press {
                    continue;
                }
                if app.composing {
                    match key.code {
                        KeyCode::Esc => {
                            app.composing = false;
                            app.cmd.clear();
                        }
                        KeyCode::Enter => {
                            let cmd = std::mem::take(&mut app.cmd);
                            app.composing = false;
                            app.run_command(&cmd);
                        }
                        KeyCode::Backspace => {
                            app.cmd.pop();
                        }
                        KeyCode::Char(c) => app.cmd.push(c),
                        _ => {}
                    }
                    continue;
                }
                match key.code {
                    KeyCode::Char('q') => break,
                    KeyCode::Char(':') => {
                        app.composing = true;
                        app.cmd.clear();
                    }
                    KeyCode::Tab => {
                        app.focus = match app.focus {
                            Focus::Browser => Focus::Blocks,
                            Focus::Blocks => Focus::Browser,
                        };
                    }
                    KeyCode::Char('c') => app.toggle_profile(),
                    KeyCode::Char('r') => {
                        app.reload_browser();
                        app.refresh_blocks();
                        app.log_line("refreshed");
                    }
                    KeyCode::Char('b') | KeyCode::Char(' ') => {
                        if app.focus == Focus::Browser {
                            app.pack_selection();
                        }
                    }
                    KeyCode::Char('h') | KeyCode::Backspace => {
                        if app.focus == Focus::Browser {
                            app.go_parent();
                        }
                    }
                    KeyCode::Enter => match app.focus {
                        Focus::Browser => {
                            if let Some(row) = app.selected_row() {
                                match row.kind {
                                    RowKind::Here => {
                                        let path = row.path.clone();
                                        app.pack_path(path);
                                    }
                                    RowKind::Parent | RowKind::Dir => {
                                        let path = row.path.clone();
                                        app.enter_dir(path);
                                    }
                                    RowKind::File => {
                                        let path = row.path.clone();
                                        app.pack_path(path);
                                    }
                                }
                            }
                        }
                        Focus::Blocks => {}
                    },
                    KeyCode::Char('j') | KeyCode::Down => match app.focus {
                        Focus::Browser => App::move_list(&mut app.browser, app.rows.len(), 1),
                        Focus::Blocks => App::move_list(&mut app.block_list, app.blocks.len(), 1),
                    },
                    KeyCode::Char('k') | KeyCode::Up => match app.focus {
                        Focus::Browser => App::move_list(&mut app.browser, app.rows.len(), -1),
                        Focus::Blocks => App::move_list(&mut app.block_list, app.blocks.len(), -1),
                    },
                    KeyCode::Char('v') => {
                        if let Some(id) = app.selected_block() {
                            app.run_command(&format!("verify {id}"));
                        }
                    }
                    KeyCode::Char('p') => {
                        if let Some(id) = app.selected_block() {
                            app.run_command(&format!("push {id}"));
                        }
                    }
                    KeyCode::Char('i') => {
                        if let Some(id) = app.selected_block() {
                            app.run_command(&format!("iso {id}"));
                        }
                    }
                    _ => {}
                }
            }
        }
    }
    Ok(())
}

fn border(active: bool) -> Style {
    if active {
        Style::default().fg(Color::Rgb(215, 247, 208))
    } else {
        Style::default().fg(Color::Rgb(45, 74, 56))
    }
}
