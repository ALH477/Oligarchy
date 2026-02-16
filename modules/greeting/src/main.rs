use anyhow::Result;
use clap::Parser;
use oligarchy_greeting::{Cli, Config};
use std::path::PathBuf;

#[derive(Parser)]
#[command(
    name = "show-greeting",
    about = "Display Oligarchy welcome greeting with image support",
    version = "1.0.0"
)]
struct Args {
    /// Path to configuration file
    #[arg(short, long, value_name = "FILE")]
    config: Option<PathBuf>,
    
    /// Force ASCII art mode (no images)
    #[arg(long)]
    ascii: bool,
    
    /// Use banner image only
    #[arg(long)]
    banner: bool,
    
    /// Use logo image only
    #[arg(long)]
    logo: bool,
    
    /// Show both banner and logo
    #[arg(long)]
    both: bool,
    
    /// Show system information
    #[arg(short, long)]
    info: bool,
    
    /// Custom welcome message
    #[arg(short, long)]
    message: Option<String>,
    
    /// List available image protocols
    #[arg(long)]
    list_protocols: bool,
}

fn main() -> Result<()> {
    let args = Args::parse();
    
    if args.list_protocols {
        println!("Available image protocols:");
        println!("  - kitty      : Kitty graphics protocol");
        println!("  - iterm2     : iTerm2 inline images");
        println!("  - sixel      : Sixel graphics");
        println!("  - halfblocks : Unicode half-blocks (fallback)");
        println!("  - none       : No image support");
        return Ok(());
    }
    
    // Load configuration
    let mut config = Config::load(args.config.as_deref())?;
    
    // Apply CLI overrides
    if args.ascii {
        config.layout = oligarchy_greeting::config::LayoutMode::AsciiOnly;
    } else if args.banner {
        config.layout = oligarchy_greeting::config::LayoutMode::BannerOnly;
    } else if args.logo {
        config.layout = oligarchy_greeting::config::LayoutMode::LogoOnly;
    } else if args.both {
        config.layout = oligarchy_greeting::config::LayoutMode::Both;
    }
    
    if args.info {
        config.show_system_info = true;
    }
    
    if let Some(msg) = args.message {
        config.welcome_message = msg;
    }
    
    // Check if running in SSH or TMUX
    if is_ssh_or_tmux() {
        // Disable images in SSH/TMUX
        config.images.banner.enabled = false;
        config.images.logo.enabled = false;
    }
    
    // Run CLI
    let cli = Cli::new(config);
    cli.run()?;
    
    Ok(())
}

fn is_ssh_or_tmux() -> bool {
    std::env::var("SSH_CONNECTION").is_ok() || 
    std::env::var("TMUX").is_ok()
}
