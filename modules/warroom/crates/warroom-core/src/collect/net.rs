//! NET collector — `nmcli` + strict-egress summary
//!
//! OWNER: work stream S1. This file is a stub: `probe()` is real, `collect()`
//! is not. Fill it in without touching any file outside `collect/`.

use crate::model::{Availability, Panel};
use std::time::Duration;

pub struct NetCollector {
    _priv: (),
}

impl NetCollector {
    pub fn new() -> Self {
        NetCollector { _priv: () }
    }
}

impl Default for NetCollector {
    fn default() -> Self {
        Self::new()
    }
}

impl super::Collector for NetCollector {
    fn id(&self) -> &'static str {
        "net"
    }

    fn title(&self) -> &'static str {
        "NET"
    }

    fn interval(&self) -> Duration {
        Duration::from_secs(10)
    }

    fn probe(&self) -> Availability {
        match crate::exec::which("nmcli") {
            Some(_) => Availability::Present,
            None => Availability::Missing("nmcli not installed"),
        }
    }

    fn collect(&mut self) -> anyhow::Result<Panel> {
        // Stubs bail rather than `todo!()`: a panicking collector thread would
        // take its pane down silently, and the skeleton is meant to render an
        // honest "Failed" state instead.
        anyhow::bail!("net collector not implemented")
    }
}
