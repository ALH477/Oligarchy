//! `oligarchy-forge` — plain CLI verbs (`build`/`run`/`shell`) over
//! `forge-core`, plus a Ratatui dashboard (`forge-tui`) launched when no
//! subcommand is given — the k9s/lazydocker convention: just run the tool
//! name to get the dashboard.

use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use forge_core::ForgeConfig;
use std::process::ExitCode;

#[derive(Parser)]
#[command(name = "oligarchy-forge", about = "Sandboxed coding-agent runner", version)]
struct Cli {
    #[command(subcommand)]
    command: Option<Command>,
}

#[derive(Subcommand)]
enum Command {
    /// Render oligarchy-forge.toml into a flake.nix, `nix build` it, and
    /// `podman load` the resulting image.
    Build {
        /// Rebuild even if an image with this name already exists.
        #[arg(long)]
        rebuild: bool,
    },
    /// Run a command inside the sandbox (building first if needed).
    Run {
        #[arg(long)]
        rebuild: bool,
        /// Command to run, e.g. `oligarchy-forge run -- claude "fix the bug"`.
        #[arg(last = true)]
        cmd: Vec<String>,
    },
    /// Open an interactive shell inside the sandbox (building first if needed).
    Shell {
        #[arg(long)]
        rebuild: bool,
    },
    /// Open the session-list + build-log dashboard (also the default when
    /// no subcommand is given).
    Tui,
    /// Open the interactive extension picker for the current directory's
    /// oligarchy-forge.toml (bootstraps one if it doesn't exist yet).
    Edit,
    /// Print the generated flake.nix to stdout and exit, without building
    /// anything or touching Podman.
    ///
    /// Exists so the generated flake can be checked without the two things
    /// `build` needs and CI cannot always have: a container runtime, and
    /// network access to fetch an agent's upstream flake. `nix build
    /// .#forge-catalog` renders one project per catalogued agent and parses
    /// each result, which catches the failure mode the unit tests cannot —
    /// a template that produces well-formed-looking text that is not valid
    /// Nix, or an `inputs` block that disagrees with the `outputs` signature.
    Render,
}

fn load_config() -> Result<ForgeConfig> {
    let toml_str = std::fs::read_to_string("oligarchy-forge.toml")
        .context("reading oligarchy-forge.toml in the current directory")?;
    ForgeConfig::parse(&toml_str)
}

fn main() -> ExitCode {
    match run(Cli::parse()) {
        Ok(code) => ExitCode::from(code.clamp(0, 255) as u8),
        Err(err) => {
            eprintln!("oligarchy-forge: {err:#}");
            ExitCode::FAILURE
        }
    }
}

fn run(cli: Cli) -> Result<i32> {
    match cli.command {
        None | Some(Command::Tui) => {
            forge_tui::run()?;
            Ok(0)
        }
        Some(Command::Edit) => {
            forge_tui::run_edit()?;
            Ok(0)
        }
        Some(Command::Build { rebuild }) => {
            let cfg = load_config()?;
            forge_core::process::ensure_image(&cfg, rebuild)?;
            println!("built {}:latest", cfg.image_name());
            Ok(0)
        }
        Some(Command::Run { rebuild, cmd }) => {
            let cfg = load_config()?;
            forge_core::process::ensure_image(&cfg, rebuild)?;
            forge_core::process::container_run(&cfg, &cmd)
        }
        Some(Command::Shell { rebuild }) => {
            let cfg = load_config()?;
            forge_core::process::ensure_image(&cfg, rebuild)?;
            forge_core::process::container_run(&cfg, &[])
        }
        Some(Command::Render) => {
            let cfg = load_config()?;
            print!("{}", forge_core::render::render_flake(&cfg)?);
            Ok(0)
        }
    }
}
