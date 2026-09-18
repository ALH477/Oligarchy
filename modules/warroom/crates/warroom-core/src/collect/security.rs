//! PERIMETER collector — /run/oligarchy-security/status.json (file read only)
//!
//! OWNER: work stream S1. This file is a stub: `probe()` is real, `collect()`
//! is not. Fill it in without touching any file outside `collect/`.

use crate::model::{Availability, Panel};
use std::time::Duration;

/// Written atomically (tmp + rename) by `oligarchy-security-status.timer`,
/// every 5 minutes. Already read directly by dcf-tray and the greeter.
pub const SECURITY_CACHE: &str = "/run/oligarchy-security/status.json";

pub struct SecurityCollector {
    _priv: (),
}

impl SecurityCollector {
    pub fn new() -> Self {
        SecurityCollector { _priv: () }
    }
}

impl Default for SecurityCollector {
    fn default() -> Self {
        Self::new()
    }
}

impl super::Collector for SecurityCollector {
    fn id(&self) -> &'static str {
        "security"
    }

    fn title(&self) -> &'static str {
        "PERIMETER"
    }

    fn interval(&self) -> Duration {
        Duration::from_secs(5)
    }

    fn probe(&self) -> Availability {
        // The cache, not the CLI: re-forking `oligarchy-security status` would
        // defeat the entire reason the timer writes this file.
        if std::path::Path::new(SECURITY_CACHE).is_file() {
            Availability::Present
        } else {
            Availability::Missing(
                "no security status cache — enable custom.hardening",
            )
        }
    }

    fn collect(&mut self) -> anyhow::Result<Panel> {
        // Stubs bail rather than `todo!()`: a panicking collector thread would
        // take its pane down silently, and the skeleton is meant to render an
        // honest "Failed" state instead.
        anyhow::bail!("security collector not implemented")
    }
}
