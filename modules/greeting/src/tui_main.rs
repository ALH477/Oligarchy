use anyhow::Result;
use clap::Parser;
use oligarchy_greeting::Config;
use std::io::{self, Write};
use std::path::PathBuf;
use std::time::Duration;

#[derive(Parser)]
#[command(
    name = "welcome-tui",
    about = "Interactive Oligarchy Welcome TUI",
    version = "1.0.0"
)]
struct Args {
    /// Path to configuration file
    #[arg(value_name = "FILE")]
    config: Option<PathBuf>,
}

fn main() -> Result<()> {
    let args = Args::parse();
    
    // Load configuration
    let config = Config::load(args.config.as_deref())?;
    
    // Check if TUI is enabled
    if !config.tui.enabled {
        println!("TUI is disabled in configuration");
        return Ok(());
    }
    
    // Clear screen
    print!("\x1b[2J\x1b[H");
    io::stdout().flush()?;
    
    // Show greeting first
    let cli = oligarchy_greeting::Cli::new(config.clone());
    cli.run()?;
    
    // Show menu if enabled
    if config.tui.show_launcher {
        show_menu(&config)?;
    }
    
    Ok(())
}

fn show_menu(config: &Config) -> Result<()> {
    let mut stdout = io::stdout();
    
    writeln!(stdout, "\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")?;
    writeln!(stdout, "Press any key to launch the War Room TUI, or wait 3 seconds...")?;
    writeln!(stdout, "\nOr press:")?;
    writeln!(stdout, "  [b] Open browser")?;
    writeln!(stdout, "  [d] Open documentation")?;
    writeln!(stdout, "  [t] Open terminal")?;
    writeln!(stdout, "  [q] Quit")?;
    stdout.flush()?;
    
    // Try to read with timeout
    let result = read_with_timeout(Duration::from_secs(3));
    
    match result {
        Some('b') | Some('B') => {
            // Open browser
            if let Some(link) = config.custom_links.first() {
                let _ = std::process::Command::new("xdg-open")
                    .arg(&link.url)
                    .spawn();
            }
        }
        Some('d') | Some('D') => {
            // Open documentation
            let _ = std::process::Command::new("xdg-open")
                .arg("https://github.com/ALH477/Oligarchy")
                .spawn();
        }
        Some('t') | Some('T') => {
            // Launch terminal
            let _ = std::process::Command::new("sh")
                .arg("-c")
                .arg(&config.tui.launch_command)
                .spawn();
        }
        Some('q') | Some('Q') => {
            // Quit
        }
        Some(_) | None => {
            // Any key or timeout - launch TUI
            if !config.tui.launch_command.is_empty() {
                let _ = std::process::Command::new("sh")
                    .arg("-c")
                    .arg(&config.tui.launch_command)
                    .spawn();
            }
        }
    }
    
    Ok(())
}

fn read_with_timeout(timeout: Duration) -> Option<char> {
    use std::io::Read;
    
    // Set non-blocking mode
    let mut stdin = io::stdin();
    let start = std::time::Instant::now();
    
    loop {
        if start.elapsed() >= timeout {
            return None;
        }
        
        let mut buf = [0u8; 1];
        match stdin.read(&mut buf) {
            Ok(1) => return Some(buf[0] as char),
            Ok(_) => return None,
            Err(_) => {
                std::thread::sleep(Duration::from_millis(100));
                continue;
            }
        }
    }
}
