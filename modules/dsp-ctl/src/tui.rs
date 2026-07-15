// SPDX-License-Identifier: MIT
// TUI dashboard — real-time DSP coprocessor monitoring.
// Works with any transport (local, SSH, TCP, USB, HydraMesh).

use anyhow::Result;
use crossterm::{
    event::{self, Event, KeyCode, KeyEventKind},
    terminal::{disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen},
    execute,
};
use ratatui::{
    backend::CrosstermBackend,
    layout::{Constraint, Direction, Layout, Rect},
    style::{Color, Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Borders, Gauge, List, ListItem, Paragraph, Tabs},
    Terminal,
};
use std::{io, time::{Duration, Instant}};

use crate::transport::{TransportSpec, SystemCommand, OrchCommand, DspStatus, DspMeters};

#[derive(Clone, Copy, PartialEq)]
enum Tab {
    Overview,
    Audio,
    Meters,
    Ports,
}

impl Tab {
    fn titles() -> Vec<&'static str> {
        vec!["Overview", "Audio", "Meters", "Ports"]
    }
    fn next(self) -> Self {
        match self {
            Tab::Overview => Tab::Audio,
            Tab::Audio => Tab::Meters,
            Tab::Meters => Tab::Ports,
            Tab::Ports => Tab::Overview,
        }
    }
    fn prev(self) -> Self {
        match self {
            Tab::Overview => Tab::Ports,
            Tab::Audio => Tab::Overview,
            Tab::Meters => Tab::Audio,
            Tab::Ports => Tab::Meters,
        }
    }
}

struct App {
    transport: TransportSpec,
    tab: Tab,
    status: DspStatus,
    meters: DspMeters,
    last_update: Instant,
    error: Option<String>,
}

impl App {
    fn new(transport: TransportSpec) -> Self {
        Self {
            transport,
            tab: Tab::Overview,
            status: DspStatus::default(),
            meters: DspMeters::default(),
            last_update: Instant::now() - Duration::from_secs(10),
            error: None,
        }
    }

    fn refresh(&mut self) {
        let mut t = self.transport.create();
        match t.get_status() {
            Ok(s) => { self.status = s; self.error = None; }
            Err(e) => { self.error = Some(e.to_string()); }
        }
        // Get meters from get_health
        if let Ok(resp) = t.send_orch(OrchCommand::GetHealth) {
            if resp.ok {
                if let Some(ref data) = resp.data {
                    self.meters.cpu_load = data.get("cpu_load")
                        .and_then(|v| v.as_f64()).unwrap_or(0.0) as f32;
                    self.meters.xrun_count = data.get("xruns")
                        .and_then(|v| v.as_u64()).unwrap_or(0);
                    self.meters.callback_count = data.get("callbacks")
                        .and_then(|v| v.as_u64()).unwrap_or(0);
                }
            }
        }
        self.last_update = Instant::now();
    }
}

pub fn run_dashboard(transport: TransportSpec) -> Result<()> {
    enable_raw_mode()?;
    let mut stdout = io::stdout();
    execute!(stdout, EnterAlternateScreen)?;
    let backend = CrosstermBackend::new(stdout);
    let mut terminal = Terminal::new(backend)?;

    let mut app = App::new(transport);
    app.refresh();

    loop {
        terminal.draw(|f| ui(f, &mut app))?;

        if event::poll(Duration::from_secs(2))? {
            if let Event::Key(key) = event::read()? {
                if key.kind != KeyEventKind::Press { continue; }
                match key.code {
                    KeyCode::Char('q') | KeyCode::Esc => break,
                    KeyCode::Tab => app.tab = app.tab.next(),
                    KeyCode::BackTab => app.tab = app.tab.prev(),
                    KeyCode::Char('1') => app.tab = Tab::Overview,
                    KeyCode::Char('2') => app.tab = Tab::Audio,
                    KeyCode::Char('3') => app.tab = Tab::Meters,
                    KeyCode::Char('4') => app.tab = Tab::Ports,
                    KeyCode::Char('s') => {
                        let mut t = app.transport.create();
                        let _ = t.send_system(SystemCommand::VmStart);
                        let _ = t.send_system(SystemCommand::NetjackStart);
                        let _ = t.send_system(SystemCommand::DemodRtStart);
                        app.refresh();
                    }
                    KeyCode::Char('x') => {
                        let mut t = app.transport.create();
                        let _ = t.send_system(SystemCommand::DemodRtStop);
                        let _ = t.send_system(SystemCommand::NetjackStop);
                        let _ = t.send_system(SystemCommand::VmStop);
                        app.refresh();
                    }
                    KeyCode::Char('r') => {
                        let mut t = app.transport.create();
                        let _ = t.send_system(SystemCommand::NetjackRestart);
                        app.refresh();
                    }
                    KeyCode::Char('p') => {
                        let mut t = app.transport.create();
                        let _ = t.send_orch(OrchCommand::Ping);
                        app.refresh();
                    }
                    _ => {}
                }
            }
        }

        if app.last_update.elapsed() > Duration::from_secs(2) {
            app.refresh();
        }
    }

    disable_raw_mode()?;
    execute!(terminal.backend_mut(), LeaveAlternateScreen)?;
    Ok(())
}

fn ui(f: &mut ratatui::Frame, app: &mut App) {
    let size = f.size();

    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(3),
            Constraint::Min(5),
            Constraint::Length(3),
        ])
        .split(size);

    let tab_titles: Vec<Line> = Tab::titles().iter().enumerate().map(|(i, t)| {
        Line::from(vec![
            Span::styled(format!(" {} ", i + 1), Style::default().add_modifier(Modifier::DIM)),
            Span::raw(*t),
        ])
    }).collect();
    let tabs = Tabs::new(tab_titles)
        .block(Block::default().borders(Borders::ALL).title(" dsp-ctl "))
        .select(match app.tab { Tab::Overview => 0, Tab::Audio => 1, Tab::Meters => 2, Tab::Ports => 3 })
        .highlight_style(Style::default().fg(Color::Cyan).add_modifier(Modifier::BOLD));
    f.render_widget(tabs, chunks[0]);

    match app.tab {
        Tab::Overview => draw_overview(f, app, chunks[1]),
        Tab::Audio => draw_audio(f, app, chunks[1]),
        Tab::Meters => draw_meters(f, app, chunks[1]),
        Tab::Ports => draw_ports(f, app, chunks[1]),
    }

    let status_bar = if let Some(ref err) = app.error {
        Paragraph::new(format!(" ERROR: {} | [q]uit [Tab]switch [s]tart [x]stop [r]estart [p]ing ", truncate(err, 50)))
            .style(Style::default().fg(Color::Red))
    } else {
        Paragraph::new(format!(" {} | {:?} | [q]uit [Tab] [s]tart [x]stop [r]estart [p]ing ",
            app.transport.name(),
            app.last_update.elapsed()))
            .style(Style::default().fg(Color::DarkGray))
    };
    f.render_widget(status_bar, chunks[2]);
}

fn draw_overview(f: &mut ratatui::Frame, app: &mut App, area: Rect) {
    let s = &app.status;
    let green = Style::default().fg(Color::Green);
    let red = Style::default().fg(Color::Red);
    let dim = Style::default().fg(Color::DarkGray);

    let info = vec![
        Line::from(vec![
            Span::styled(" DSP VM:        ", dim),
            Span::styled(if s.vm_active { "● ACTIVE" } else { "○ INACTIVE" },
                if s.vm_active { green } else { red }),
        ]),
        Line::from(vec![
            Span::styled(" NETJACK:       ", dim),
            Span::styled(if s.netjack_active { "● ACTIVE" } else { "○ INACTIVE" },
                if s.netjack_active { green } else { red }),
        ]),
        Line::from(vec![
            Span::styled(" demod-rt:      ", dim),
            Span::styled(if s.demod_rt_active { "● ACTIVE" } else { "○ INACTIVE" },
                if s.demod_rt_active { green } else { red }),
        ]),
        Line::from(vec![
            Span::styled(" JACK:          ", dim),
            Span::styled(if s.jack_running { "● RUNNING" } else { "○ STOPPED" },
                if s.jack_running { green } else { red }),
        ]),
        Line::raw(""),
        Line::from(vec![
            Span::styled(" Transport:     ", dim),
            Span::raw(&s.transport),
        ]),
        Line::from(vec![
            Span::styled(" Sample Rate:   ", dim),
            Span::raw(format!("{} Hz", s.sample_rate)),
        ]),
        Line::from(vec![
            Span::styled(" Buffer Size:   ", dim),
            Span::raw(format!("{} samples ({:.2}ms period)", s.buffer_size,
                s.buffer_size as f32 / s.sample_rate as f32 * 1000.0)),
        ]),
        Line::raw(""),
        Line::from(vec![
            Span::styled(" CPU Isolated:  ", dim),
            Span::raw(if s.isolated_cpus.is_empty() { "none" } else { &s.isolated_cpus }),
        ]),
        Line::from(vec![
            Span::styled(" Hugepages:     ", dim),
            Span::raw(format!("{}", s.hugepages_total)),
        ]),
        Line::from(vec![
            Span::styled(" VFIO c7:00.3:  ", dim),
            Span::styled(if s.vfio_bound { "● BOUND (passed to VM)" } else { "○ HOST (not passed)" },
                if s.vfio_bound { green } else { Style::default().fg(Color::Yellow) }),
        ]),
    ];

    let block = Block::default().borders(Borders::ALL).title(" Overview ");
    f.render_widget(Paragraph::new(info).block(block), area);
}

fn draw_audio(f: &mut ratatui::Frame, app: &mut App, area: Rect) {
    let s = &app.status;
    let period_ms = s.buffer_size as f32 / s.sample_rate as f32 * 1000.0;
    let dim = Style::default().fg(Color::DarkGray);
    let cyan = Style::default().fg(Color::Cyan).add_modifier(Modifier::BOLD);

    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Percentage(50), Constraint::Percentage(50)])
        .split(area);

    let latency_info = vec![
        Line::styled(" INPUT (instrument → DSP)", cyan),
        Line::raw(""),
        Line::from(vec![Span::styled("   USB micro-frame:   ", dim), Span::raw(format!("{:.3} ms", 0.125))]),
        Line::from(vec![Span::styled("   ALSA period:       ", dim), Span::raw(format!("{:.3} ms", period_ms))]),
        Line::from(vec![
            Span::styled("   Input total:       ", Style::default().fg(Color::Green)),
            Span::styled(format!(" {:.3} ms", s.latency_input_ms), Style::default().add_modifier(Modifier::BOLD)),
        ]),
        Line::raw(""),
        Line::styled(" OUTPUT (DSP → speakers)", cyan),
        Line::raw(""),
        Line::from(vec![Span::styled("   NETJACK + PipeWire:", dim), Span::raw(format!("{:.3} ms", s.latency_output_ms))]),
        Line::raw(""),
        Line::from(vec![
            Span::styled(" ROUND-TRIP: ", Style::default().fg(Color::Yellow)),
            Span::styled(format!(" {:.3} ms", s.latency_roundtrip_ms),
                Style::default().fg(Color::Yellow).add_modifier(Modifier::BOLD)),
        ]),
    ];
    let block = Block::default().borders(Borders::ALL).title(" Latency Budget ");
    f.render_widget(Paragraph::new(latency_info).block(block), chunks[0]);

    let mut jack_lines = vec![
        Line::from(vec![Span::styled(" JACK Ports:  ", dim), Span::raw(format!("{} visible", s.jack_ports.len()))]),
        Line::raw(""),
        Line::styled(" Port List (first 10):", dim),
        Line::raw(""),
    ];
    for (i, p) in s.jack_ports.iter().take(10).enumerate() {
        jack_lines.push(Line::from(vec![
            Span::styled(format!(" {:>2}. ", i + 1), dim),
            Span::raw(p),
        ]));
    }
    if s.jack_ports.len() > 10 {
        jack_lines.push(Line::styled(format!("   ... and {} more", s.jack_ports.len() - 10), dim));
    }
    let block = Block::default().borders(Borders::ALL).title(" Audio Paths ");
    f.render_widget(Paragraph::new(jack_lines).block(block), chunks[1]);
}

fn draw_meters(f: &mut ratatui::Frame, app: &mut App, area: Rect) {
    let s = &app.status;
    let m = &app.meters;
    let dim = Style::default().fg(Color::DarkGray);

    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Length(7), Constraint::Min(3)])
        .split(area);

    let cpu_pct = (m.cpu_load * 100.0) as u16;
    let cpu_gauge = Gauge::default()
        .block(Block::default().borders(Borders::ALL).title(" CPU Load "))
        .gauge_style(if cpu_pct > 80 { Style::default().fg(Color::Red) }
                     else if cpu_pct > 50 { Style::default().fg(Color::Yellow) }
                     else { Style::default().fg(Color::Green) })
        .percent(cpu_pct.min(100))
        .label(format!("{:.1}% (budget: {:.2}ms)", m.cpu_load * 100.0,
            s.buffer_size as f32 / s.sample_rate as f32 * 1000.0));
    f.render_widget(cpu_gauge, chunks[0]);

    let stats = vec![
        Line::from(vec![Span::styled(" Xruns:     ", dim),
            Span::styled(format!("{}", m.xrun_count),
                if m.xrun_count > 0 { Style::default().fg(Color::Yellow) } else { Style::default().fg(Color::Green) })]),
        Line::from(vec![Span::styled(" Callbacks: ", dim), Span::raw(format!("{}", m.callback_count))]),
    ];
    let block = Block::default().borders(Borders::ALL).title(" Engine Stats ");
    f.render_widget(Paragraph::new(stats).block(block), chunks[1]);
}

fn draw_ports(f: &mut ratatui::Frame, app: &mut App, area: Rect) {
    let s = &app.status;
    let items: Vec<ListItem> = s.jack_ports.iter()
        .map(|p| ListItem::new(Line::raw(p)))
        .collect();
    let list = List::new(items)
        .block(Block::default().borders(Borders::ALL).title(format!(" JACK Ports ({}) ", s.jack_ports.len())));
    f.render_widget(list, area);
}

fn truncate(s: &str, max: usize) -> String {
    if s.len() <= max { s.to_string() }
    else { format!("{}...", &s[..max]) }
}
