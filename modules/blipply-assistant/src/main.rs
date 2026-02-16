// Blipply Assistant - AI-powered desktop assistant with voice interaction
// Copyright (c) 2026 DeMoD LLC
// Licensed under the MIT License

use anyhow::Result;
use clap::{Parser, Subcommand};
use tracing::{info, error};
use std::sync::Arc;
use tokio::sync::RwLock;

mod config;
mod profiles;
mod ollama;
mod audio;
mod ui;
mod hotkeys;
mod state;
mod first_run;

use crate::config::Config;
use crate::profiles::ProfileManager;
use crate::state::AppState;

#[derive(Parser)]
#[command(author, version, about, long_about = None)]
struct Cli {
    #[command(subcommand)]
    command: Option<Commands>,

    /// Enable verbose logging
    #[arg(short, long)]
    verbose: bool,
}

#[derive(Subcommand)]
enum Commands {
    /// Run the assistant daemon
    Daemon,
    
    /// Toggle assistant visibility
    Toggle,
    
    /// Run first-time setup
    Setup,
    
    /// List available profiles
    Profiles,
    
    /// Create a new profile
    CreateProfile {
        /// Profile name
        name: String,
        
        /// Base profile to copy from
        #[arg(short, long)]
        base: Option<String>,
    },
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();
    
    // Initialize logging
    let log_level = if cli.verbose { "debug" } else { "info" };
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| format!("blipply_assistant={}", log_level).into())
        )
        .init();

    match cli.command {
        Some(Commands::Daemon) | None => run_daemon().await,
        Some(Commands::Toggle) => toggle_assistant().await,
        Some(Commands::Setup) => run_setup().await,
        Some(Commands::Profiles) => list_profiles().await,
        Some(Commands::CreateProfile { name, base }) => create_profile(&name, base.as_deref()).await,
    }
}

async fn run_daemon() -> Result<()> {
    info!("Starting Blipply Assistant daemon");
    
    // Load configuration
    let config = Config::load()?;
    
    // Check if first run is needed
    if !config.general.first_run_complete {
        info!("First run detected, launching setup");
        first_run::run_interactive_setup().await?;
        return Ok(());
    }
    
    // Initialize GTK
    gtk::init()?;
    
    // Create application state
    let state = Arc::new(AppState::new(config).await?);
    
    // Start hotkey listener
    let hotkey_state = state.clone();
    tokio::spawn(async move {
        if let Err(e) = hotkeys::run_listener(hotkey_state).await {
            error!("Hotkey listener error: {}", e);
        }
    });
    
    // Create UI
    let window = ui::create_window(state.clone())?;
    window.present();
    
    // Run GTK main loop
    let main_context = glib::MainContext::default();
    main_context.spawn_local(async move {
        state.run().await;
    });
    
    info!("Assistant ready");
    gtk::main();
    
    Ok(())
}

async fn toggle_assistant() -> Result<()> {
    // Send IPC message to daemon to toggle visibility
    use std::os::unix::net::UnixStream;
    use std::io::Write;
    
    let socket_path = dirs::runtime_dir()
        .unwrap_or_else(|| std::env::temp_dir())
        .join("blipply-assistant.sock");
    
    if let Ok(mut stream) = UnixStream::connect(&socket_path) {
        stream.write_all(b"TOGGLE\n")?;
        info!("Toggle command sent");
    } else {
        error!("Could not connect to daemon. Is it running?");
    }
    
    Ok(())
}

async fn run_setup() -> Result<()> {
    info!("Running first-time setup");
    first_run::run_interactive_setup().await?;
    Ok(())
}

async fn list_profiles() -> Result<()> {
    let config = Config::load()?;
    let manager = ProfileManager::from_config(&config);
    
    println!("Available profiles:");
    for (id, profile) in &manager.profiles {
        let active = if id == &manager.active { " (active)" } else { "" };
        println!("  {} - {}{}", id, profile.name, active);
        println!("    Model: {}", profile.model);
        println!("    Voice: {}", profile.voice_model);
    }
    
    Ok(())
}

async fn create_profile(name: &str, base: Option<&str>) -> Result<()> {
    let mut config = Config::load()?;
    let mut manager = ProfileManager::from_config(&config);
    
    manager.create_profile(name.to_string(), base)?;
    
    // Save updated config
    config.profiles = manager.into_config_map();
    config.save()?;
    
    println!("Profile '{}' created successfully", name);
    Ok(())
}
