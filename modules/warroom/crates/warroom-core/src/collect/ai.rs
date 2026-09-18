//! AI collector — `ai-stack status`
//!
//! OWNER: work stream S1. This file is a stub: `probe()` is real, `collect()`
//! is not. Fill it in without touching any file outside `collect/`.

use crate::model::{Availability, Panel};
use std::time::Duration;

pub struct AiCollector {
    _priv: (),
}

impl AiCollector {
    pub fn new() -> Self {
        AiCollector { _priv: () }
    }
}

impl Default for AiCollector {
    fn default() -> Self {
        Self::new()
    }
}

impl super::Collector for AiCollector {
    fn id(&self) -> &'static str {
        "ai"
    }

    fn title(&self) -> &'static str {
        "AI"
    }

    fn interval(&self) -> Duration {
        Duration::from_secs(10)
    }

    fn probe(&self) -> Availability {
        match crate::exec::which("ai-stack") {
            Some(_) => Availability::Present,
            None => Availability::Missing("ai-stack not installed — enable services.ollamaAgentic"),
        }
    }

    fn collect(&mut self) -> anyhow::Result<Panel> {
        // Stubs bail rather than `todo!()`: a panicking collector thread would
        // take its pane down silently, and the skeleton is meant to render an
        // honest "Failed" state instead.
        anyhow::bail!("ai collector not implemented")
    }
}
