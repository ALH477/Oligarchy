//! FORGE collector — oligarchy-forge session state (rollup only in v1)
//!
//! OWNER: work stream S1. This file is a stub: `probe()` is real, `collect()`
//! is not. Fill it in without touching any file outside `collect/`.

use crate::model::{Availability, Panel};
use std::time::Duration;

pub struct ForgeCollector {
    _priv: (),
}

impl ForgeCollector {
    pub fn new() -> Self {
        ForgeCollector { _priv: () }
    }
}

impl Default for ForgeCollector {
    fn default() -> Self {
        Self::new()
    }
}

impl super::Collector for ForgeCollector {
    fn id(&self) -> &'static str {
        "forge"
    }

    fn title(&self) -> &'static str {
        "FORGE"
    }

    fn interval(&self) -> Duration {
        Duration::from_secs(15)
    }

    fn probe(&self) -> Availability {
        match crate::exec::which("oligarchy-forge") {
            Some(_) => Availability::Present,
            None => Availability::Missing("oligarchy-forge not installed — enable custom.oligarchyForge"),
        }
    }

    fn collect(&mut self) -> anyhow::Result<Panel> {
        // Stubs bail rather than `todo!()`: a panicking collector thread would
        // take its pane down silently, and the skeleton is meant to render an
        // honest "Failed" state instead.
        anyhow::bail!("forge collector not implemented")
    }
}
