//! Discovers known projects by scanning `forge_core::process::state_root()`
//! rather than the caller's CWD — each project's config snapshot was
//! written there by `forge_core::process::persist_config` on its last build.

use anyhow::Result;
use forge_core::ForgeConfig;

pub struct KnownProject {
    pub cfg: ForgeConfig,
    pub built: bool,
}

impl KnownProject {
    pub fn extensions_summary(&self) -> String {
        self.cfg
            .project
            .extensions
            .iter()
            .map(|e| format!("{e:?}").to_lowercase())
            .collect::<Vec<_>>()
            .join(", ")
    }

    pub fn agents_summary(&self) -> String {
        if self.cfg.project.agents.is_empty() {
            return "(none)".to_string();
        }
        self.cfg
            .project
            .agents
            .iter()
            .map(|a| format!("{a:?}").to_lowercase())
            .collect::<Vec<_>>()
            .join(", ")
    }
}

/// Best-effort: a project directory that's missing or has an unparseable
/// config snapshot is silently skipped rather than failing the whole scan —
/// one broken project shouldn't blank the dashboard.
pub fn discover() -> Result<Vec<KnownProject>> {
    let mut out = Vec::new();
    for dir in forge_core::process::known_project_dirs()? {
        let toml_path = dir.join("oligarchy-forge.toml");
        let Ok(raw) = std::fs::read_to_string(&toml_path) else {
            continue;
        };
        let Ok(cfg) = ForgeConfig::parse(&raw) else {
            continue;
        };
        let built = forge_core::process::image_exists(&cfg).unwrap_or(false);
        out.push(KnownProject { cfg, built });
    }
    out.sort_by(|a, b| a.cfg.project.name.cmp(&b.cfg.project.name));
    Ok(out)
}
