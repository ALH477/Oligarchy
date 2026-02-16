// Blipply Assistant
// Copyright (c) 2026 DeMoD LLC
// Licensed under the MIT License

use anyhow::{Result, bail};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use crate::config::{Config, ProfileConfig};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VoiceProfile {
    pub name: String,
    pub model: String,
    pub personality: String,
    pub avatar_path: String,
    pub avatar_size_px: u32,
    pub voice_model: String,
    pub tts_speed: f32,
    pub tts_enabled: bool,
}

impl From<ProfileConfig> for VoiceProfile {
    fn from(config: ProfileConfig) -> Self {
        Self {
            name: config.name,
            model: config.model,
            personality: config.personality,
            avatar_path: config.avatar_path,
            avatar_size_px: config.avatar_size_px,
            voice_model: config.voice_model,
            tts_speed: config.tts_speed,
            tts_enabled: config.tts_enabled,
        }
    }
}

impl From<VoiceProfile> for ProfileConfig {
    fn from(profile: VoiceProfile) -> Self {
        Self {
            name: profile.name,
            model: profile.model,
            personality: profile.personality,
            avatar_path: profile.avatar_path,
            avatar_size_px: profile.avatar_size_px,
            voice_model: profile.voice_model,
            tts_speed: profile.tts_speed,
            tts_enabled: profile.tts_enabled,
        }
    }
}

pub struct ProfileManager {
    pub active: String,
    pub profiles: HashMap<String, VoiceProfile>,
}

impl ProfileManager {
    pub fn from_config(config: &Config) -> Self {
        let profiles = config.profiles
            .iter()
            .map(|(k, v)| (k.clone(), v.clone().into()))
            .collect();

        Self {
            active: config.general.active_profile.clone(),
            profiles,
        }
    }

    pub fn into_config_map(self) -> HashMap<String, ProfileConfig> {
        self.profiles
            .into_iter()
            .map(|(k, v)| (k, v.into()))
            .collect()
    }

    pub fn create_profile(&mut self, name: String, base: Option<&str>) -> Result<()> {
        if self.profiles.contains_key(&name) {
            bail!("Profile '{}' already exists", name);
        }

        let template = if let Some(base_name) = base {
            self.profiles
                .get(base_name)
                .cloned()
                .ok_or_else(|| anyhow::anyhow!("Base profile '{}' not found", base_name))?
        } else {
            VoiceProfile {
                name: name.clone(),
                model: "llama3.2:3b".to_string(),
                personality: "helpful".to_string(),
                avatar_path: "/usr/share/blipply/clippy.gif".to_string(),
                avatar_size_px: 96,
                voice_model: "en_US-lessac-medium".to_string(),
                tts_speed: 1.0,
                tts_enabled: true,
            }
        };

        self.profiles.insert(name.clone(), VoiceProfile {
            name: name.clone(),
            ..template
        });

        Ok(())
    }

    pub fn switch_profile(&mut self, name: &str) -> Result<&VoiceProfile> {
        if !self.profiles.contains_key(name) {
            bail!("Profile '{}' not found", name);
        }
        self.active = name.to_string();
        Ok(&self.profiles[name])
    }

    pub fn active_profile(&self) -> Result<&VoiceProfile> {
        self.profiles
            .get(&self.active)
            .ok_or_else(|| anyhow::anyhow!("Active profile '{}' not found", self.active))
    }

    pub fn update_profile(&mut self, name: &str, profile: VoiceProfile) -> Result<()> {
        if !self.profiles.contains_key(name) {
            bail!("Profile '{}' not found", name);
        }
        self.profiles.insert(name.to_string(), profile);
        Ok(())
    }

    pub fn delete_profile(&mut self, name: &str) -> Result<()> {
        if name == "default" {
            bail!("Cannot delete default profile");
        }
        if name == self.active {
            bail!("Cannot delete active profile");
        }
        if !self.profiles.contains_key(name) {
            bail!("Profile '{}' not found", name);
        }
        self.profiles.remove(name);
        Ok(())
    }

    pub fn get_system_prompt(&self, profile: &VoiceProfile) -> String {
        match profile.personality.as_str() {
            "helpful" => {
                "You are Blipply – a friendly, concise desktop assistant for NixOS. \
                 Be accurate, use markdown for formatting, and keep answers short unless \
                 asked for detail. You have access to the user's desktop context.".to_string()
            }
            "sassy" => {
                "You are a sassy, witty desktop assistant. Be helpful but don't be afraid \
                 to add some personality. Keep it fun but professional.".to_string()
            }
            "technical" => {
                "You are a technical assistant specializing in NixOS, Linux systems, and \
                 programming. Provide detailed, accurate technical information with code \
                 examples when relevant.".to_string()
            }
            "concise" => {
                "You are a minimalist assistant. Provide the most direct, concise answers \
                 possible. No fluff, just facts.".to_string()
            }
            _ => {
                "You are a helpful desktop assistant.".to_string()
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_create_profile() {
        let config = Config::default();
        let mut manager = ProfileManager::from_config(&config);
        
        assert!(manager.create_profile("test".to_string(), None).is_ok());
        assert!(manager.profiles.contains_key("test"));
        assert!(manager.create_profile("test".to_string(), None).is_err());
    }

    #[test]
    fn test_switch_profile() {
        let config = Config::default();
        let mut manager = ProfileManager::from_config(&config);
        
        manager.create_profile("test".to_string(), None).unwrap();
        assert!(manager.switch_profile("test").is_ok());
        assert_eq!(manager.active, "test");
    }
}
