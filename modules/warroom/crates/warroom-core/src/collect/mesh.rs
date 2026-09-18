//! MESH collector — `dcf status` / `dcf list-peers` (JSON)
//!
//! OWNER: work stream S1. This file is a stub: `probe()` is real, `collect()`
//! is not. Fill it in without touching any file outside `collect/`.

use crate::model::{Availability, Panel};
use std::time::Duration;

pub struct MeshCollector {
    _priv: (),
}

impl MeshCollector {
    pub fn new() -> Self {
        MeshCollector { _priv: () }
    }
}

impl Default for MeshCollector {
    fn default() -> Self {
        Self::new()
    }
}

impl super::Collector for MeshCollector {
    fn id(&self) -> &'static str {
        "mesh"
    }

    fn title(&self) -> &'static str {
        "MESH"
    }

    fn interval(&self) -> Duration {
        Duration::from_secs(5)
    }

    fn probe(&self) -> Availability {
        match crate::exec::which("dcf") {
            Some(_) => Availability::Present,
            None => Availability::Missing("dcf not installed — enable custom.hydramesh"),
        }
    }

    fn collect(&mut self) -> anyhow::Result<Panel> {
        // Stubs bail rather than `todo!()`: a panicking collector thread would
        // take its pane down silently, and the skeleton is meant to render an
        // honest "Failed" state instead.
        anyhow::bail!("mesh collector not implemented")
    }
}
