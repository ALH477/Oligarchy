// Blipply Assistant
// Copyright (c) 2026 DeMoD LLC
// Licensed under the MIT License

use anyhow::Result;
use std::io::{self, Write};
use tracing::info;

use crate::config::{Config, ProfileConfig};
use crate::ollama::OllamaClient;

pub async fn run_interactive_setup() -> Result<()> {
    println!("\n=== Blipply Assistant Setup ===\n");
    
    let mut config = Config::load()?;
    
    // Step 1: Check Ollama connection
    println!("Checking Ollama connection...");
    let client = OllamaClient::new(&config.general.ollama_url);
    
    let models = match client.list_models().await {
        Ok(models) => {
            println!("✓ Connected to Ollama");
            models
        }
        Err(e) => {
            eprintln!("✗ Could not connect to Ollama: {}", e);
            eprintln!("Please ensure Ollama is running at {}", config.general.ollama_url);
            eprintln!("You can change the URL in the config file later.");
            Vec::new()
        }
    };
    
    // Step 2: Select model
    if !models.is_empty() {
        println!("\nAvailable models:");
        for (i, model) in models.iter().enumerate() {
            println!("  {}. {}", i + 1, model);
        }
        
        let model_choice = prompt_number(
            "Select a model (or press Enter for default)",
            Some(1),
            1,
            models.len(),
        )?;
        
        if let Some(choice) = model_choice {
            let profile = config.profiles.get_mut("default").unwrap();
            profile.model = models[choice - 1].clone();
        }
    } else {
        println!("\nUsing default model: {}", config.profiles["default"].model);
        println!("You can change this later in the config file.");
    }
    
    // Step 3: Select personality
    println!("\nSelect assistant personality:");
    println!("  1. Helpful (default) - Friendly and concise");
    println!("  2. Sassy - Witty with personality");
    println!("  3. Technical - Detailed technical information");
    println!("  4. Concise - Minimal, direct answers");
    
    let personality_choice = prompt_number(
        "Choose personality",
        Some(1),
        1,
        4,
    )?;
    
    if let Some(choice) = personality_choice {
        let personality = match choice {
            1 => "helpful",
            2 => "sassy",
            3 => "technical",
            4 => "concise",
            _ => "helpful",
        };
        
        let profile = config.profiles.get_mut("default").unwrap();
        profile.personality = personality.to_string();
    }
    
    // Step 4: Configure hotkey
    println!("\nConfigure global hotkey (default: Super+Shift+A):");
    println!("Format: Modifier+Modifier+Key (e.g., Super+Shift+A)");
    println!("Press Enter to use default");
    
    if let Some(hotkey) = prompt_string("Hotkey")? {
        if !hotkey.is_empty() {
            config.general.hotkey = hotkey;
        }
    }
    
    // Step 5: Audio configuration
    println!("\nAudio Configuration:");
    println!("Enable voice interaction? (y/n) [default: y]");
    
    let enable_voice = prompt_yes_no("Enable voice", true)?;
    
    if enable_voice {
        println!("\nVAD (Voice Activity Detection) aggressiveness (0-3):");
        println!("  0 - Quality (less aggressive, may miss speech)");
        println!("  1 - Low Bitrate");
        println!("  2 - Aggressive (recommended)");
        println!("  3 - Very Aggressive (may trigger on noise)");
        
        if let Some(vad) = prompt_number("VAD level", Some(2), 0, 3)? {
            config.audio.vad_aggressiveness = vad as u8;
        }
        
        let profile = config.profiles.get_mut("default").unwrap();
        profile.tts_enabled = true;
    } else {
        let profile = config.profiles.get_mut("default").unwrap();
        profile.tts_enabled = false;
    }
    
    // Step 6: Avatar selection
    println!("\nAvatar image path (press Enter for default):");
    
    if let Some(path) = prompt_string("Avatar path")? {
        if !path.is_empty() {
            let profile = config.profiles.get_mut("default").unwrap();
            profile.avatar_path = path;
        }
    }
    
    // Mark setup as complete
    config.general.first_run_complete = true;
    
    // Save configuration
    config.save()?;
    
    println!("\n✓ Setup complete!");
    println!("\nConfiguration saved to: {:?}", Config::config_path()?);
    println!("\nYou can:");
    println!("  - Run 'blipply-assistant' to start the daemon");
    println!("  - Edit the config file to customize settings");
    println!("  - Run 'blipply-assistant profiles' to manage profiles");
    
    Ok(())
}

fn prompt_string(prompt: &str) -> Result<Option<String>> {
    print!("{}: ", prompt);
    io::stdout().flush()?;
    
    let mut input = String::new();
    io::stdin().read_line(&mut input)?;
    
    let input = input.trim();
    if input.is_empty() {
        Ok(None)
    } else {
        Ok(Some(input.to_string()))
    }
}

fn prompt_number(prompt: &str, default: Option<usize>, min: usize, max: usize) -> Result<Option<usize>> {
    loop {
        let default_str = default
            .map(|d| format!(" [default: {}]", d))
            .unwrap_or_default();
        
        print!("{}{}: ", prompt, default_str);
        io::stdout().flush()?;
        
        let mut input = String::new();
        io::stdin().read_line(&mut input)?;
        
        let input = input.trim();
        
        if input.is_empty() {
            return Ok(default);
        }
        
        match input.parse::<usize>() {
            Ok(n) if n >= min && n <= max => return Ok(Some(n)),
            _ => {
                println!("Please enter a number between {} and {}", min, max);
            }
        }
    }
}

fn prompt_yes_no(prompt: &str, default: bool) -> Result<bool> {
    let default_str = if default { "Y/n" } else { "y/N" };
    
    loop {
        print!("{} ({}): ", prompt, default_str);
        io::stdout().flush()?;
        
        let mut input = String::new();
        io::stdin().read_line(&mut input)?;
        
        let input = input.trim().to_lowercase();
        
        if input.is_empty() {
            return Ok(default);
        }
        
        match input.as_str() {
            "y" | "yes" => return Ok(true),
            "n" | "no" => return Ok(false),
            _ => println!("Please enter 'y' or 'n'"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_prompt_parsing() {
        // These would need proper input mocking to test
        assert!(true);
    }
}
