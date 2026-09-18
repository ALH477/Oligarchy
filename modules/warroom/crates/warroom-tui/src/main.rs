//! Oligarchy War Room — unified Ratatui command center.
//!
//! OWNER: work stream S0 (frozen).
//!
//! Bare invocation launches the TUI, matching `forge-cli`'s k9s/lazydocker
//! convention (`None | Some(Command::Tui)` dispatch to the same call).

mod app;
mod handoff;
mod ui;

use anyhow::Result;
use clap::{Parser, Subcommand};
use crossterm::execute;
use crossterm::terminal::{
    disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen,
};
use ratatui::backend::CrosstermBackend;
use ratatui::Terminal;
use std::io::stdout;

mod cli;

#[derive(Parser)]
#[command(
    name = "warroom",
    about = "Oligarchy War Room — unified command center",
    version
)]
struct Cli {
    #[command(subcommand)]
    command: Option<Command>,

    /// Use a specific theme id instead of the active one.
    #[arg(long, global = true)]
    theme: Option<String>,

    /// Ignore ~/.config/oligarchy/themes and use the built-in DeMoD palette.
    #[arg(long, global = true)]
    no_theme_sync: bool,

    /// Skip the startup splash.
    #[arg(long)]
    no_splash: bool,
}

#[derive(Subcommand)]
enum Command {
    /// Launch the TUI (the default).
    Tui,
    /// One-shot system sitrep.
    Status {
        #[arg(long)]
        json: bool,
    },
    /// Per-collector availability and probe latency.
    Doctor,
    /// Dump the oligarchy-ctl action catalog.
    Actions {
        #[arg(long)]
        json: bool,
    },
}

fn main() -> Result<()> {
    let args = Cli::parse();

    // Env vars come from the NixOS module; flags win over them.
    let splash = !args.no_splash && std::env::var("WARROOM_SPLASH").as_deref() != Ok("0");
    let theme_sync =
        !args.no_theme_sync && std::env::var("WARROOM_THEME_SYNC").as_deref() != Ok("0");

    match args.command {
        Some(Command::Status { json }) => cli::status(json),
        Some(Command::Doctor) => cli::doctor(),
        Some(Command::Actions { json }) => cli::actions(json),
        None | Some(Command::Tui) => {
            let palette = warroom_core::theme::load(args.theme.as_deref(), theme_sync);
            run_tui(ui::Skin::new(palette), splash, theme_sync)
        }
    }
}

fn run_tui(skin: ui::Skin, splash: bool, theme_sync: bool) -> Result<()> {
    // Without this, a panic leaves the user in an alternate screen with raw
    // mode on — an unusable shell and no error text.
    let default_hook = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        let _ = disable_raw_mode();
        let _ = execute!(stdout(), LeaveAlternateScreen);
        default_hook(info);
    }));

    enable_raw_mode()?;
    let mut out = stdout();
    execute!(out, EnterAlternateScreen)?;
    let mut term = Terminal::new(CrosstermBackend::new(out))?;

    let mut application = app::App::new(skin, splash, theme_sync);
    let result = app::run(&mut application, &mut term);

    disable_raw_mode()?;
    execute!(term.backend_mut(), LeaveAlternateScreen)?;
    term.show_cursor()?;
    result
}
