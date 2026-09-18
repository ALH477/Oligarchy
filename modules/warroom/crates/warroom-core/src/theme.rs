//! Palette: the built-in DeMoD colors, plus an opportunistic read of the
//! Home-Manager-exported `palette.json`.
//!
//! This crate carries no ratatui dependency, so colors are plain RGB triples.
//! `warroom-tui`'s `Skin` converts them, honoring [`ColorMode`].
//!
//! Values transcribed from `home/themes/default.nix` (`palettes.demod`), which
//! is ground truth. `docs/architecture.md`'s palette table is a stale snapshot
//! (#00D4AA/#FF6B6B/#1A1A2E) and must not be used.

use serde::Deserialize;
use std::path::PathBuf;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Rgb(pub u8, pub u8, pub u8);

impl Rgb {
    pub const fn hex(v: u32) -> Self {
        Rgb(((v >> 16) & 0xFF) as u8, ((v >> 8) & 0xFF) as u8, (v & 0xFF) as u8)
    }

    fn parse(s: &str) -> Option<Rgb> {
        let s = s.trim().strip_prefix('#')?;
        if s.len() != 6 {
            return None;
        }
        u32::from_str_radix(s, 16).ok().map(Rgb::hex)
    }

    /// Interpolate toward `other`. Used for the splash gradient.
    pub fn lerp(self, other: Rgb, t: f32) -> Rgb {
        let t = t.clamp(0.0, 1.0);
        let mix = |a: u8, b: u8| (a as f32 + (b as f32 - a as f32) * t).round() as u8;
        Rgb(mix(self.0, other.0), mix(self.1, other.1), mix(self.2, other.2))
    }

    /// Nearest of the 16 ANSI colors, for terminals without truecolor.
    /// Returns an index usable as `ratatui::style::Color::Indexed`.
    pub fn nearest_ansi(self) -> u8 {
        // Standard xterm values for indices 0-15.
        const ANSI: [(u8, u8, u8); 16] = [
            (0, 0, 0),
            (128, 0, 0),
            (0, 128, 0),
            (128, 128, 0),
            (0, 0, 128),
            (128, 0, 128),
            (0, 128, 128),
            (192, 192, 192),
            (128, 128, 128),
            (255, 0, 0),
            (0, 255, 0),
            (255, 255, 0),
            (0, 0, 255),
            (255, 0, 255),
            (0, 255, 255),
            (255, 255, 255),
        ];
        let mut best = 0u8;
        let mut best_d = u32::MAX;
        for (i, &(r, g, b)) in ANSI.iter().enumerate() {
            let d = sq(self.0, r) + sq(self.1, g) + sq(self.2, b);
            if d < best_d {
                best_d = d;
                best = i as u8;
            }
        }
        best
    }
}

fn sq(a: u8, b: u8) -> u32 {
    let d = a as i32 - b as i32;
    (d * d) as u32
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ColorMode {
    TrueColor,
    Ansi16,
}

/// This distro really does put people in a bare TTY (tuigreet), so the fallback
/// is not hypothetical.
pub fn color_mode() -> ColorMode {
    match std::env::var("COLORTERM").as_deref() {
        Ok("truecolor") | Ok("24bit") => ColorMode::TrueColor,
        _ => ColorMode::Ansi16,
    }
}

#[derive(Debug, Clone, Copy)]
pub struct Palette {
    pub name: &'static str,
    pub bg: Rgb,
    pub bg_alt: Rgb,
    pub surface: Rgb,
    pub surface_alt: Rgb,
    pub overlay: Rgb,
    pub border: Rgb,
    pub border_focus: Rgb,
    pub border_hover: Rgb,
    pub accent: Rgb,
    pub accent_alt: Rgb,
    pub accent_dim: Rgb,
    pub gradient_start: Rgb,
    pub gradient_end: Rgb,
    pub text: Rgb,
    pub text_alt: Rgb,
    pub text_dim: Rgb,
    pub text_on_accent: Rgb,
    pub success: Rgb,
    pub warning: Rgb,
    pub error: Rgb,
    pub info: Rgb,
    pub purple: Rgb,
    pub pink: Rgb,
}

/// The house palette. Compiled in so the War Room is correct on a fresh system
/// with no Home Manager applied — an installer/TTY/recovery context, which is
/// exactly when a cockpit matters most.
pub const DEMOD: Palette = Palette {
    name: "demod",
    bg: Rgb::hex(0x080810),
    bg_alt: Rgb::hex(0x0C0C14),
    surface: Rgb::hex(0x101018),
    surface_alt: Rgb::hex(0x161620),
    overlay: Rgb::hex(0x1C1C28),
    border: Rgb::hex(0x252530),
    border_focus: Rgb::hex(0x00F5D4),
    border_hover: Rgb::hex(0x8B5CF6),
    accent: Rgb::hex(0x00F5D4),
    accent_alt: Rgb::hex(0x00E5C7),
    accent_dim: Rgb::hex(0x00B89F),
    gradient_start: Rgb::hex(0x00F5D4),
    gradient_end: Rgb::hex(0x8B5CF6),
    text: Rgb::hex(0xFFFFFF),
    text_alt: Rgb::hex(0xE0E0E0),
    text_dim: Rgb::hex(0x808080),
    text_on_accent: Rgb::hex(0x080810),
    success: Rgb::hex(0x39FF14),
    warning: Rgb::hex(0xFFE814),
    error: Rgb::hex(0xFF3B5C),
    info: Rgb::hex(0x00F5D4),
    purple: Rgb::hex(0x8B5CF6),
    pink: Rgb::hex(0xA78BFA),
};

/// Every key optional: a palette missing one falls back to DEMOD's rather than
/// failing the whole load.
#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawPalette {
    bg: Option<String>,
    bg_alt: Option<String>,
    surface: Option<String>,
    surface_alt: Option<String>,
    overlay: Option<String>,
    border: Option<String>,
    border_focus: Option<String>,
    border_hover: Option<String>,
    accent: Option<String>,
    accent_alt: Option<String>,
    accent_dim: Option<String>,
    gradient_start: Option<String>,
    gradient_end: Option<String>,
    text: Option<String>,
    text_alt: Option<String>,
    text_dim: Option<String>,
    text_on_accent: Option<String>,
    success: Option<String>,
    warning: Option<String>,
    error: Option<String>,
    info: Option<String>,
    purple: Option<String>,
    pink: Option<String>,
}

/// Load the active theme's palette, falling back to [`DEMOD`] on any failure.
///
/// Silent by design: a themed cockpit that refuses to start because a JSON file
/// moved would be strictly worse than a turquoise one that does.
pub fn load(explicit: Option<&str>, sync: bool) -> Palette {
    if !sync && explicit.is_none() {
        return DEMOD;
    }
    let id = match explicit {
        Some(id) => id.to_string(),
        None => match active_theme_id() {
            Some(id) => id,
            None => return DEMOD,
        },
    };
    load_id(&id).unwrap_or(DEMOD)
}

/// The id of the theme the user has switched to, per `theme-switch.sh`.
pub fn active_theme_id() -> Option<String> {
    let home = std::env::var_os("HOME").map(PathBuf::from)?;

    // theme-switch.sh writes this for kitty/OSC consumers.
    let demod = home.join(".config/demod/theme.json");
    if let Ok(text) = std::fs::read_to_string(&demod) {
        if let Ok(v) = serde_json::from_str::<serde_json::Value>(&text) {
            for key in ["id", "name", "theme", "active"] {
                if let Some(s) = v.get(key).and_then(|x| x.as_str()) {
                    return Some(s.to_string());
                }
            }
        }
    }

    let manifest = home.join(".config/oligarchy/themes/manifest.json");
    let text = std::fs::read_to_string(manifest).ok()?;
    let v: serde_json::Value = serde_json::from_str(&text).ok()?;
    for key in ["active", "current", "default"] {
        if let Some(s) = v.get(key).and_then(|x| x.as_str()) {
            return Some(s.to_string());
        }
    }
    None
}

fn load_id(id: &str) -> Option<Palette> {
    // Reject anything that could escape the themes directory.
    if id.is_empty() || id.contains('/') || id.contains("..") {
        return None;
    }
    let home = std::env::var_os("HOME").map(PathBuf::from)?;
    let path = home.join(".config/oligarchy/themes").join(id).join("palette.json");
    let text = std::fs::read_to_string(path).ok()?;
    let raw: RawPalette = serde_json::from_str(&text).ok()?;

    let mut p = DEMOD;
    let set = |slot: &mut Rgb, v: &Option<String>| {
        if let Some(rgb) = v.as_deref().and_then(Rgb::parse) {
            *slot = rgb;
        }
    };
    set(&mut p.bg, &raw.bg);
    set(&mut p.bg_alt, &raw.bg_alt);
    set(&mut p.surface, &raw.surface);
    set(&mut p.surface_alt, &raw.surface_alt);
    set(&mut p.overlay, &raw.overlay);
    set(&mut p.border, &raw.border);
    set(&mut p.border_focus, &raw.border_focus);
    set(&mut p.border_hover, &raw.border_hover);
    set(&mut p.accent, &raw.accent);
    set(&mut p.accent_alt, &raw.accent_alt);
    set(&mut p.accent_dim, &raw.accent_dim);
    set(&mut p.gradient_start, &raw.gradient_start);
    set(&mut p.gradient_end, &raw.gradient_end);
    set(&mut p.text, &raw.text);
    set(&mut p.text_alt, &raw.text_alt);
    set(&mut p.text_dim, &raw.text_dim);
    set(&mut p.text_on_accent, &raw.text_on_accent);
    set(&mut p.success, &raw.success);
    set(&mut p.warning, &raw.warning);
    set(&mut p.error, &raw.error);
    set(&mut p.info, &raw.info);
    set(&mut p.purple, &raw.purple);
    set(&mut p.pink, &raw.pink);
    Some(p)
}

/// Theme ids available to cycle through with `t`.
pub fn available_themes() -> Vec<String> {
    let Some(home) = std::env::var_os("HOME").map(PathBuf::from) else {
        return Vec::new();
    };
    let Ok(dir) = std::fs::read_dir(home.join(".config/oligarchy/themes")) else {
        return Vec::new();
    };
    let mut ids: Vec<String> = dir
        .flatten()
        .filter(|e| e.path().join("palette.json").is_file())
        .filter_map(|e| e.file_name().into_string().ok())
        .collect();
    ids.sort();
    ids
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hex_parses_both_ways() {
        assert_eq!(Rgb::parse("#00F5D4"), Some(Rgb(0x00, 0xF5, 0xD4)));
        assert_eq!(Rgb::parse("00F5D4"), None);
        assert_eq!(Rgb::parse("#fff"), None);
        assert_eq!(DEMOD.accent, Rgb(0x00, 0xF5, 0xD4));
    }

    #[test]
    fn a_traversing_theme_id_is_refused() {
        assert!(load_id("../../etc").is_none());
        assert!(load_id("a/b").is_none());
        assert!(load_id("").is_none());
    }

    #[test]
    fn gradient_endpoints_are_exact() {
        let a = Rgb::hex(0x00F5D4);
        let b = Rgb::hex(0x8B5CF6);
        assert_eq!(a.lerp(b, 0.0), a);
        assert_eq!(a.lerp(b, 1.0), b);
    }

    #[test]
    fn nearest_ansi_picks_something_sane() {
        assert_eq!(Rgb::hex(0x000000).nearest_ansi(), 0);
        assert_eq!(Rgb::hex(0xFFFFFF).nearest_ansi(), 15);
        assert_eq!(Rgb::hex(0xFF0000).nearest_ansi(), 9);
    }
}
