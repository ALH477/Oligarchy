//! SITREP collector — sysinfo + /etc/oligarchy/persona + powerprofilesctl
//!
//! OWNER: work stream S1. This file is a stub: `probe()` is real, `collect()`
//! is not. Fill it in without touching any file outside `collect/`.

use crate::model::{Availability, Panel};
use std::time::Duration;

pub struct SystemCollector {
    _priv: (),
}

impl SystemCollector {
    pub fn new() -> Self {
        SystemCollector { _priv: () }
    }
}

impl Default for SystemCollector {
    fn default() -> Self {
        Self::new()
    }
}

impl super::Collector for SystemCollector {
    fn id(&self) -> &'static str {
        "system"
    }

    fn title(&self) -> &'static str {
        "SITREP"
    }

    fn interval(&self) -> Duration {
        Duration::from_secs(1)
    }

    fn probe(&self) -> Availability {
        // Always available: /proc and sysinfo need no external binary.
        Availability::Present
    }

    fn collect(&mut self) -> anyhow::Result<Panel> {
        // Stubs bail rather than `todo!()`: a panicking collector thread would
        // take its pane down silently, and the skeleton is meant to render an
        // honest "Failed" state instead.
        anyhow::bail!("system collector not implemented")
    }
}
