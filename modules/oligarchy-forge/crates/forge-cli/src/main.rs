//! `oligarchy-forge` — plain CLI verbs over `forge-core`. Stage 1 adds a
//! `forge-tui` binary that reuses the same engine crate; this binary and its
//! verbs (`build`/`run`/`shell`) stay as-is once that lands.

use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use forge_core::ForgeConfig;
use std::process::ExitCode;

#[derive(Parser)]
#[command(name = "oligarchy-forge", about = "Sandboxed coding-agent runner", version)]
struct Cli {
    #[command(subcommand)]
    command: Command,
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
        Command::Build { rebuild } => {
            let cfg = load_config()?;
            forge_core::process::ensure_image(&cfg, rebuild)?;
            println!("built {}:latest", cfg.image_name());
            Ok(0)
        }
        Command::Run { rebuild, cmd } => {
            let cfg = load_config()?;
            forge_core::process::ensure_image(&cfg, rebuild)?;
            forge_core::process::container_run(&cfg, &cmd)
        }
        Command::Shell { rebuild } => {
            let cfg = load_config()?;
            forge_core::process::ensure_image(&cfg, rebuild)?;
            forge_core::process::container_run(&cfg, &[])
        }
    }
}
