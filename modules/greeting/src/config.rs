use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Config {
    #[serde(default)]
    pub ascii_art: String,
    
    #[serde(default)]
    pub welcome_message: String,
    
    #[serde(default = "default_true")]
    pub show_system_info: bool,
    
    #[serde(default)]
    pub custom_links: Vec<Link>,
    
    #[serde(default)]
    pub tips: Vec<String>,
    
    #[serde(default)]
    pub images: ImageConfig,
    
    #[serde(default)]
    pub layout: LayoutMode,
    
    #[serde(default = "default_true")]
    pub fallback_to_ascii: bool,
    
    #[serde(default)]
    pub tui: TuiConfig,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct Link {
    pub name: String,
    pub url: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct ImageConfig {
    #[serde(default)]
    pub banner: BannerConfig,
    
    #[serde(default)]
    pub logo: LogoConfig,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BannerConfig {
    #[serde(default = "default_banner_path")]
    pub path: PathBuf,
    
    #[serde(default = "default_true")]
    pub enabled: bool,
    
    #[serde(default = "default_position")]
    pub position: String,
    
    #[serde(default = "default_aspect_ratio")]
    pub aspect_ratio: String,
    
    #[serde(default = "default_max_height")]
    pub max_height: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LogoConfig {
    #[serde(default = "default_logo_path")]
    pub path: PathBuf,
    
    #[serde(default = "default_true")]
    pub enabled: bool,
    
    #[serde(default = "default_logo_position")]
    pub position: String,
    
    #[serde(default = "default_logo_aspect_ratio")]
    pub aspect_ratio: String,
    
    #[serde(default = "default_max_size")]
    pub max_size: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum LayoutMode {
    #[default]
    Adaptive,
    BannerOnly,
    LogoOnly,
    Both,
    AsciiOnly,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TuiConfig {
    #[serde(default = "default_true")]
    pub enabled: bool,
    
    #[serde(default = "default_true")]
    pub show_launcher: bool,
    
    #[serde(default = "default_launch_command")]
    pub launch_command: String,
}

fn default_true() -> bool {
    true
}

fn default_banner_path() -> PathBuf {
    PathBuf::from("/etc/oligarchy/banner.jpg")
}

fn default_logo_path() -> PathBuf {
    PathBuf::from("/etc/oligarchy/logo.png")
}

fn default_position() -> String {
    "header".to_string()
}

fn default_logo_position() -> String {
    "sidebar".to_string()
}

fn default_aspect_ratio() -> String {
    "16:9".to_string()
}

fn default_logo_aspect_ratio() -> String {
    "1:1".to_string()
}

fn default_max_height() -> u32 {
    20
}

fn default_max_size() -> u32 {
    15
}

fn default_launch_command() -> String {
    "hyprctl dispatch exec kitty".to_string()
}

impl Default for BannerConfig {
    fn default() -> Self {
        Self {
            path: default_banner_path(),
            enabled: true,
            position: default_position(),
            aspect_ratio: default_aspect_ratio(),
            max_height: default_max_height(),
        }
    }
}

impl Default for LogoConfig {
    fn default() -> Self {
        Self {
            path: default_logo_path(),
            enabled: true,
            position: default_logo_position(),
            aspect_ratio: default_logo_aspect_ratio(),
            max_size: default_max_size(),
        }
    }
}

impl Default for TuiConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            show_launcher: true,
            launch_command: default_launch_command(),
        }
    }
}

impl Config {
    pub fn load(path: Option<&std::path::Path>) -> anyhow::Result<Self> {
        if let Some(path) = path {
            let content = std::fs::read_to_string(path)?;
            let config: Config = serde_json::from_str(&content)?;
            Ok(config)
        } else {
            // Try default locations
            let locations = [
                std::path::PathBuf::from("/etc/oligarchy/greeting.json"),
                std::path::PathBuf::from("/etc/oligarchy/welcome-tui-config.json"),
            ];
            
            for location in &locations {
                if location.exists() {
                    let content = std::fs::read_to_string(location)?;
                    return Ok(serde_json::from_str(&content)?);
                }
            }
            
            // Check home directory
            if let Ok(home) = std::env::var("HOME") {
                let home_config = std::path::PathBuf::from(&home).join(".config/oligarchy/greeting.json");
                if home_config.exists() {
                    let content = std::fs::read_to_string(home_config)?;
                    return Ok(serde_json::from_str(&content)?);
                }
            }
            
            Ok(Config::default())
        }
    }
    
    pub fn should_show_banner(&self, term_width: u16) -> bool {
        if !self.images.banner.enabled {
            return false;
        }
        
        match self.layout {
            LayoutMode::BannerOnly | LayoutMode::Both => true,
            LayoutMode::Adaptive => term_width >= 80,
            _ => false,
        }
    }
    
    pub fn should_show_logo(&self, term_width: u16) -> bool {
        if !self.images.logo.enabled {
            return false;
        }
        
        match self.layout {
            LayoutMode::LogoOnly => true,
            LayoutMode::Both => true,
            LayoutMode::Adaptive => term_width < 80 || self.images.banner.enabled,
            _ => false,
        }
    }
}

impl Default for Config {
    fn default() -> Self {
        Self {
            ascii_art: default_ascii_art(),
            welcome_message: default_welcome_message(),
            show_system_info: true,
            custom_links: Vec::new(),
            tips: default_tips(),
            images: ImageConfig::default(),
            layout: LayoutMode::default(),
            fallback_to_ascii: true,
            tui: TuiConfig::default(),
        }
    }
}

fn default_ascii_art() -> String {
    r#".d88b. 8    888 .d88b     db    888b. .d88b 8   8 Yb  dP
8P  Y8 8     8  8P www   dPYb   8  .8 8P    8www8  YbdP
8b  d8 8     8  8b  d8  dPwwYb  8wwK' 8b    8   8   YP
`Y88P' 8888 888 `Y88P' dP    Yb 8  Yb `Y88P 8   8   88"#.to_string()
}

fn default_welcome_message() -> String {
    "Welcome to Oligarchy — The War Machine".to_string()
}

fn default_tips() -> Vec<String> {
    vec![
        "Press Super+L to lock screen".to_string(),
    ]
}
