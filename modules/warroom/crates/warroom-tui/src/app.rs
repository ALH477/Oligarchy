//! App state, the event loop, and key dispatch.
//!
//! OWNER: work stream S0 (frozen). Each tab's own state lives in that tab's
//! file and is reached through the fields below, so no stream ever needs to
//! edit this file to add behavior to its own pane.

use crate::ui::{self, Skin};
use anyhow::Result;
use crossterm::event::{self, Event, KeyCode, KeyEvent, KeyEventKind, KeyModifiers};
use ratatui::backend::CrosstermBackend;
use ratatui::Terminal;
use std::io::Stdout;
use std::time::{Duration, Instant};

/// The one backend this binary ever uses. Naming it concretely keeps
/// `Backend::Error`'s Send/Sync bounds out of every signature.
pub type Term = Terminal<CrosstermBackend<Stdout>>;
use warroom_core::collect::{self, Scheduler};
use warroom_core::model::{CollectorMsg, Freshness, PanelState};
use warroom_core::theme;

/// The splash stays up until the first collection pass lands, or this long,
/// whichever is later — it is doing real work, not just posing.
const SPLASH_MIN: Duration = Duration::from_millis(1200);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Tab {
    Sitrep,
    Dsp,
    Mesh,
    Perimeter,
    Ordnance,
    Traffic,
}

impl Tab {
    pub const ALL: [Tab; 6] =
        [Tab::Sitrep, Tab::Dsp, Tab::Mesh, Tab::Perimeter, Tab::Ordnance, Tab::Traffic];

    pub fn title(self) -> &'static str {
        match self {
            Tab::Sitrep => "SITREP",
            Tab::Dsp => "DSP",
            Tab::Mesh => "MESH",
            Tab::Perimeter => "PERIMETER",
            Tab::Ordnance => "ORDNANCE",
            Tab::Traffic => "TRAFFIC",
        }
    }

    fn index(self) -> usize {
        Tab::ALL.iter().position(|t| *t == self).unwrap_or(0)
    }

    fn step(self, delta: isize) -> Tab {
        let n = Tab::ALL.len() as isize;
        let i = (self.index() as isize + delta).rem_euclid(n);
        Tab::ALL[i as usize]
    }
}

/// What a key press asks the app to do. Returned by the per-tab `on_key`
/// handlers so that tabs never need terminal or scheduler access themselves.
#[derive(Debug, Clone)]
pub enum Action {
    RefreshAll,
    /// Suspend the TUI and run this argv on the same tty.
    Handoff(Vec<String>),
    /// Run an `oligarchy-ctl` action by id.
    RunAction(String),
    /// Ask for confirmation before performing the inner action.
    Confirm { title: String, body: String, action: Box<Action> },
    Quit,
}

pub struct Confirm {
    pub title: String,
    pub body: String,
    pub action: Action,
}

pub struct App {
    pub skin: Skin,
    pub tab: Tab,
    pub panels: Vec<PanelState>,
    pub sched: Scheduler,
    pub host: String,
    pub started: Instant,
    pub splash_done: bool,
    pub first_pass: bool,
    pub help: bool,
    pub confirm: Option<Confirm>,
    pub should_quit: bool,

    pub dsp: ui::dsp::State,
    pub mesh: ui::mesh::State,
    pub perimeter: ui::security::State,
    pub ordnance: ui::actions::State,
    pub traffic: ui::logs::State,

    pub theme_ids: Vec<String>,
    pub theme_idx: usize,
}

impl App {
    pub fn new(skin: Skin, splash: bool, theme_sync: bool) -> Self {
        let collectors = collect::all();
        let panels: Vec<PanelState> =
            collectors.iter().map(|c| PanelState::new(c.id(), c.title())).collect();
        let sched = collect::spawn(collectors);

        App {
            skin,
            tab: Tab::Sitrep,
            panels,
            sched,
            host: hostname(),
            started: Instant::now(),
            splash_done: !splash,
            first_pass: false,
            help: false,
            confirm: None,
            should_quit: false,
            dsp: Default::default(),
            mesh: Default::default(),
            perimeter: Default::default(),
            ordnance: Default::default(),
            traffic: Default::default(),
            // `--no-theme-sync` means the on-disk themes are ignored entirely,
            // so there is nothing for `t` to cycle through either.
            theme_ids: if theme_sync { theme::available_themes() } else { Vec::new() },
            theme_idx: 0,
        }
    }

    pub fn panel(&self, id: &str) -> Option<&PanelState> {
        self.panels.iter().find(|p| p.id == id)
    }

    /// Extra footer hints contributed by the active pane.
    pub fn tab_hints(&self) -> Vec<(&'static str, &'static str)> {
        match self.tab {
            Tab::Dsp => vec![("D", "dsp-ctl")],
            Tab::Ordnance => vec![("/", "filter"), ("enter", "run")],
            _ => vec![],
        }
    }

    /// Drain the collector channel and age everything that did not report.
    pub fn tick(&mut self) {
        while let Ok(msg) = self.sched.rx.try_recv() {
            match msg {
                CollectorMsg::Update { id, panel, at } => {
                    if let Some(p) = self.panels.iter_mut().find(|p| p.id == id) {
                        p.panel = Some(panel);
                        p.freshness = Freshness::Fresh;
                        p.last_ok = Some(at);
                    }
                }
                CollectorMsg::Failed { id, err, .. } => {
                    if let Some(p) = self.panels.iter_mut().find(|p| p.id == id) {
                        p.freshness = Freshness::Failed(err);
                    }
                }
                CollectorMsg::Unavailable { id, why } => {
                    if let Some(p) = self.panels.iter_mut().find(|p| p.id == id) {
                        p.freshness = Freshness::Unavailable(why);
                    }
                }
            }
            self.first_pass = true;
        }

        // Age anything whose last success has drifted past its own budget.
        for p in &mut self.panels {
            if let (Freshness::Fresh, Some(last)) = (&p.freshness, p.last_ok) {
                let age = last.elapsed();
                if age > Duration::from_secs(30) {
                    p.freshness = Freshness::Stale(age);
                }
            }
        }

        if !self.splash_done && self.started.elapsed() >= SPLASH_MIN {
            let all_reported = self
                .panels
                .iter()
                .all(|p| p.panel.is_some() || !matches!(p.freshness, Freshness::Stale(_)));
            if all_reported || self.started.elapsed() > Duration::from_secs(5) {
                self.splash_done = true;
            }
        }
    }

    pub fn on_key(&mut self, k: KeyEvent) -> Option<Action> {
        // Modals swallow everything.
        if let Some(c) = &self.confirm {
            return match k.code {
                KeyCode::Char('y') | KeyCode::Char('Y') => {
                    let action = c.action.clone();
                    self.confirm = None;
                    Some(action)
                }
                KeyCode::Char('n') | KeyCode::Char('N') | KeyCode::Esc => {
                    self.confirm = None;
                    None
                }
                _ => None,
            };
        }
        if self.help {
            self.help = false;
            return None;
        }
        if !self.splash_done {
            self.splash_done = true;
            return None;
        }

        if k.modifiers.contains(KeyModifiers::CONTROL) && k.code == KeyCode::Char('c') {
            return Some(Action::Quit);
        }

        // A pane that is collecting typed text owns the whole keyboard. Without
        // this, the global bindings below eat the letters as they are typed —
        // "restart" arrives as "estat" — and Esc quits the app instead of
        // closing the filter. Ctrl-C above stays reachable on purpose.
        if self.tab == Tab::Ordnance && ui::actions::capturing_text(&self.ordnance) {
            return ui::actions::on_key(&mut self.ordnance, k);
        }

        match k.code {
            KeyCode::Char('q') | KeyCode::Esc => return Some(Action::Quit),
            KeyCode::Char('?') => {
                self.help = true;
                return None;
            }
            KeyCode::Tab => {
                self.tab = self.tab.step(1);
                return None;
            }
            KeyCode::BackTab => {
                self.tab = self.tab.step(-1);
                return None;
            }
            KeyCode::Char(c @ '1'..='6') => {
                self.tab = Tab::ALL[c as usize - '1' as usize];
                return None;
            }
            KeyCode::Char('r') => return Some(Action::RefreshAll),
            KeyCode::Char('t') => {
                self.cycle_theme();
                return None;
            }
            KeyCode::Char('D') => {
                return Some(Action::Handoff(vec!["dsp-ctl".into()]));
            }
            KeyCode::Char('F') => {
                return Some(Action::Handoff(vec!["oligarchy-forge".into()]));
            }
            _ => {}
        }

        match self.tab {
            Tab::Dsp => ui::dsp::on_key(&mut self.dsp, k),
            Tab::Mesh => ui::mesh::on_key(&mut self.mesh, k),
            Tab::Perimeter => ui::security::on_key(&mut self.perimeter, k),
            Tab::Ordnance => ui::actions::on_key(&mut self.ordnance, k),
            Tab::Traffic => ui::logs::on_key(&mut self.traffic, k),
            Tab::Sitrep => None,
        }
    }

    fn cycle_theme(&mut self) {
        if self.theme_ids.is_empty() {
            return;
        }
        self.theme_idx = (self.theme_idx + 1) % self.theme_ids.len();
        let id = self.theme_ids[self.theme_idx].clone();
        self.skin = Skin::new(theme::load(Some(&id), true));
    }
}

fn hostname() -> String {
    std::fs::read_to_string("/proc/sys/kernel/hostname")
        .map(|s| s.trim().to_string())
        .unwrap_or_else(|_| "oligarchy".into())
}

pub fn run(app: &mut App, term: &mut Term) -> Result<()> {
    loop {
        app.tick();
        term.draw(|f| ui::render(f, app))?;

        if event::poll(Duration::from_millis(100))? {
            if let Event::Key(k) = event::read()? {
                if k.kind == KeyEventKind::Press {
                    if let Some(action) = app.on_key(k) {
                        dispatch(app, term, action)?;
                    }
                }
            }
        }
        if app.should_quit {
            return Ok(());
        }
    }
}

fn dispatch(app: &mut App, term: &mut Term, action: Action) -> Result<()> {
    match action {
        Action::Quit => app.should_quit = true,
        Action::RefreshAll => app.sched.refresh_all(),
        Action::Confirm { title, body, action } => {
            app.confirm = Some(Confirm { title, body, action: *action });
        }
        Action::Handoff(argv) => {
            if argv.is_empty() {
                return Ok(());
            }
            let out = crate::handoff::suspend_and_run(term, &argv);
            if let Err(e) = out {
                ui::logs::push(&mut app.traffic, &format!("handoff failed: {e}"));
                app.tab = Tab::Traffic;
            }
            app.sched.refresh_all();
        }
        Action::RunAction(id) => {
            let result = warroom_core::actions::run(&id);
            let text = match result {
                Ok(out) => format!("$ oligarchy-ctl run {id}\n{out}"),
                Err(e) => format!("$ oligarchy-ctl run {id}\nFAILED: {e}"),
            };
            ui::logs::push(&mut app.traffic, &text);
            app.tab = Tab::Traffic;
            app.sched.refresh_all();
        }
    }
    Ok(())
}
