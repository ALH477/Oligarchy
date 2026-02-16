// Blipply Assistant
// Copyright (c) 2026 DeMoD LLC
// Licensed under the MIT License

use anyhow::{Result, Context};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::PathBuf;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Config {
    pub general: GeneralConfig,
    pub audio: AudioConfig,
    pub pipewire: PipewireConfig,
    pub profiles: HashMap<String, ProfileConfig>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GeneralConfig {
    pub ollama_url: String,
    pub hotkey: String,
    pub first_run_complete: bool,
    pub active_profile: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AudioConfig {
    pub stt_model: String,
    pub vad_enabled: bool,
    pub vad_aggressiveness: u8,
    pub sample_rate: u32,
    pub push_to_talk: bool,
    pub silence_duration_ms: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PipewireConfig {
    pub input_device: String,
    pub output_device: String,
    pub buffer_size: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProfileConfig {
    pub name: String,
    pub model: String,
    pub personality: String,
    pub avatar_path: String,
    pub avatar_size_px: u32,
    pub voice_model: String,
    pub tts_speed: f32,
    pub tts_enabled: bool,
}

impl Default for Config {
    fn default() -> Self {
        let mut profiles = HashMap::new();
        profiles.insert(
            "default".to_string(),
            ProfileConfig {
                name: "Blipply Classic".to_string(),
                model: "llama3.2:3b".to_string(),
                personality: "helpful".to_string(),
                avatar_path: "/usr/share/blipply/clippy.gif".to_string(),
                avatar_size_px: 96,
                voice_model: "en_US-lessac-medium".to_string(),
                tts_speed: 1.0,
                tts_enabled: true,
            },
        );

        Self {
            general: GeneralConfig {
                ollama_url: "http://127.0.0.1:11434".to_string(),
                hotkey: "Super+Shift+A".to_string(),
                first_run_complete: false,
                active_profile: "default".to_string(),
            },
            audio: AudioConfig {
                stt_model: "base.en".to_string(),
                vad_enabled: true,
                vad_aggressiveness: 2,
                sample_rate: 16000,
                push_to_talk: false,
                silence_duration_ms: 1000,
            },
            pipewire: PipewireConfig {
                input_device: "auto".to_string(),
                output_device: "auto".to_string(),
                buffer_size: 480,
            },
            profiles,
        }
    }
}

impl Config {
    pub fn config_path() -> Result<PathBuf> {
        let config_dir = dirs::config_dir()
            .context("Could not determine config directory")?;
        Ok(config_dir.join("blipply-assistant").join("config.toml"))
    }

    pub fn load() -> Result<Self> {
        let path = Self::config_path()?;
        
        if !path.exists() {
            let config = Self::default();
            config.save()?;
            return Ok(config);
        }

        let contents = std::fs::read_to_string(&path)
            .context("Failed to read config file")?;
        
        let config: Config = toml::from_str(&contents)
            .context("Failed to parse config file")?;
        
        Ok(config)
    }

    pub fn save(&self) -> Result<()> {
        let path = Self::config_path()?;
        
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }

        let contents = toml::to_string_pretty(self)
            .context("Failed to serialize config")?;
        
        std::fs::write(&path, contents)
            .context("Failed to write config file")?;
        
        Ok(())
    }

    pub fn active_profile(&self) -> Result<&ProfileConfig> {
        self.profiles
            .get(&self.general.active_profile)
            .context("Active profile not found")
    }

    pub fn data_dir() -> Result<PathBuf> {
        let data_dir = dirs::data_local_dir()
            .context("Could not determine data directory")?;
        Ok(data_dir.join("blipply-assistant"))
    }

    pub fn whisper_model_path(&self) -> Result<PathBuf> {
        Ok(Self::data_dir()?.join("models").join("whisper").join(format!("{}.bin", self.audio.stt_model)))
    }

    pub fn piper_voice_path(&self, voice: &str) -> Result<PathBuf> {
        Ok(Self::data_dir()?.join("models").join("piper").join(format!("{}.onnx", voice)))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_default_config() {
        let config = Config::default();
        assert_eq!(config.general.active_profile, "default");
        assert!(config.profiles.contains_key("default"));
    }

    #[test]
    fn test_serialization() {
        let config = Config::default();
        let serialized = toml::to_string(&config).unwrap();
        let deserialized: Config = toml::from_str(&serialized).unwrap();
        assert_eq!(config.general.ollama_url, deserialized.general.ollama_url);
    }
}
