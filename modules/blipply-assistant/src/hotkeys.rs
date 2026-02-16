// Blipply Assistant
// Copyright (c) 2026 DeMoD LLC
// Licensed under the MIT License

use anyhow::{Result, Context};
use std::sync::Arc;
use tracing::{debug, info, warn};

use crate::state::AppState;

pub async fn run_listener(state: Arc<AppState>) -> Result<()> {
    info!("Starting hotkey listener");

    // Try different backends in order of preference
    if let Ok(()) = try_portal_backend(state.clone()).await {
        return Ok(());
    }

    warn!("Portal backend failed, falling back to evdev");
    try_evdev_backend(state).await
}

async fn try_portal_backend(state: Arc<AppState>) -> Result<()> {
    use zbus::Connection;

    debug!("Attempting to use xdg-desktop-portal GlobalShortcuts");

    let connection = Connection::session().await
        .context("Failed to connect to session bus")?;

    // Check if portal is available
    let proxy = zbus::fdo::DBusProxy::new(&connection).await?;
    let has_portal = proxy.name_has_owner("org.freedesktop.portal.Desktop").await?;

    if !has_portal {
        return Err(anyhow::anyhow!("GlobalShortcuts portal not available"));
    }

    info!("Using xdg-desktop-portal for global shortcuts");
    
    // In a real implementation, you would:
    // 1. Create a session with the portal
    // 2. Register the shortcut
    // 3. Listen for activation signals
    // For now, this is a placeholder

    // Simulate hotkey press for demo
    loop {
        tokio::time::sleep(std::time::Duration::from_secs(60)).await;
    }
}

async fn try_evdev_backend(state: Arc<AppState>) -> Result<()> {
    use evdev::{Device, Key, InputEventKind};
    use std::path::PathBuf;

    debug!("Attempting to use evdev for hotkeys");

    // Find keyboard devices
    let devices = evdev::enumerate()
        .filter(|(_, device)| {
            device.supported_keys()
                .map_or(false, |keys| keys.contains(Key::KEY_A))
        })
        .collect::<Vec<_>>();

    if devices.is_empty() {
        return Err(anyhow::anyhow!("No keyboard devices found. Are you in the 'input' group?"));
    }

    info!("Monitoring {} keyboard device(s)", devices.len());

    // Parse hotkey configuration
    let hotkey = {
        let config = state.config.read();
        parse_hotkey(&config.general.hotkey)?
    };

    debug!("Listening for hotkey: {:?}", hotkey);

    // Monitor all keyboard devices
    let mut streams = Vec::new();
    for (_, mut device) in devices {
        let state = state.clone();
        let hotkey = hotkey.clone();
        
        let stream = tokio::spawn(async move {
            let mut super_pressed = false;
            let mut shift_pressed = false;
            
            loop {
                match device.fetch_events() {
                    Ok(events) => {
                        for event in events {
                            if let InputEventKind::Key(key) = event.kind() {
                                match key {
                                    Key::KEY_LEFTMETA | Key::KEY_RIGHTMETA => {
                                        super_pressed = event.value() == 1;
                                    }
                                    Key::KEY_LEFTSHIFT | Key::KEY_RIGHTSHIFT => {
                                        shift_pressed = event.value() == 1;
                                    }
                                    k if k == hotkey.key && event.value() == 1 => {
                                        if super_pressed == hotkey.super_mod 
                                            && shift_pressed == hotkey.shift_mod {
                                            info!("Hotkey triggered!");
                                            state.toggle_visibility();
                                        }
                                    }
                                    _ => {}
                                }
                            }
                        }
                    }
                    Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
                    }
                    Err(e) => {
                        warn!("Device read error: {}", e);
                        break;
                    }
                }
            }
        });
        
        streams.push(stream);
    }

    // Wait for all streams
    for stream in streams {
        stream.await?;
    }

    Ok(())
}

#[derive(Debug, Clone)]
struct Hotkey {
    super_mod: bool,
    shift_mod: bool,
    ctrl_mod: bool,
    alt_mod: bool,
    key: evdev::Key,
}

fn parse_hotkey(hotkey_str: &str) -> Result<Hotkey> {
    let parts: Vec<&str> = hotkey_str.split('+').collect();
    
    if parts.is_empty() {
        return Err(anyhow::anyhow!("Empty hotkey string"));
    }

    let mut super_mod = false;
    let mut shift_mod = false;
    let mut ctrl_mod = false;
    let mut alt_mod = false;
    let mut key = None;

    for (i, part) in parts.iter().enumerate() {
        let part = part.trim();
        let is_last = i == parts.len() - 1;

        match part.to_lowercase().as_str() {
            "super" | "meta" | "win" => super_mod = true,
            "shift" => shift_mod = true,
            "ctrl" | "control" => ctrl_mod = true,
            "alt" => alt_mod = true,
            _ if is_last => {
                key = Some(parse_key_name(part)?);
            }
            _ => return Err(anyhow::anyhow!("Unknown modifier: {}", part)),
        }
    }

    Ok(Hotkey {
        super_mod,
        shift_mod,
        ctrl_mod,
        alt_mod,
        key: key.ok_or_else(|| anyhow::anyhow!("No key specified"))?,
    })
}

fn parse_key_name(name: &str) -> Result<evdev::Key> {
    use evdev::Key;
    
    let key = match name.to_lowercase().as_str() {
        "a" => Key::KEY_A,
        "b" => Key::KEY_B,
        "c" => Key::KEY_C,
        "d" => Key::KEY_D,
        "e" => Key::KEY_E,
        "f" => Key::KEY_F,
        "g" => Key::KEY_G,
        "h" => Key::KEY_H,
        "i" => Key::KEY_I,
        "j" => Key::KEY_J,
        "k" => Key::KEY_K,
        "l" => Key::KEY_L,
        "m" => Key::KEY_M,
        "n" => Key::KEY_N,
        "o" => Key::KEY_O,
        "p" => Key::KEY_P,
        "q" => Key::KEY_Q,
        "r" => Key::KEY_R,
        "s" => Key::KEY_S,
        "t" => Key::KEY_T,
        "u" => Key::KEY_U,
        "v" => Key::KEY_V,
        "w" => Key::KEY_W,
        "x" => Key::KEY_X,
        "y" => Key::KEY_Y,
        "z" => Key::KEY_Z,
        "space" => Key::KEY_SPACE,
        "enter" | "return" => Key::KEY_ENTER,
        "esc" | "escape" => Key::KEY_ESC,
        _ => return Err(anyhow::anyhow!("Unknown key: {}", name)),
    };

    Ok(key)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_hotkey() {
        let hotkey = parse_hotkey("Super+Shift+A").unwrap();
        assert!(hotkey.super_mod);
        assert!(hotkey.shift_mod);
        assert!(!hotkey.ctrl_mod);
    }

    #[test]
    fn test_parse_key_name() {
        assert!(matches!(parse_key_name("A").unwrap(), evdev::Key::KEY_A));
        assert!(matches!(parse_key_name("space").unwrap(), evdev::Key::KEY_SPACE));
    }
}
