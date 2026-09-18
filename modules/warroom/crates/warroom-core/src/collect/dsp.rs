//! DSP collector — `dsp-ctl status`
//!
//! OWNER: work stream S1. This file is a stub: `probe()` is real, `collect()`
//! is not. Fill it in without touching any file outside `collect/`.

use crate::model::{Availability, Panel};
use std::time::Duration;

pub struct DspCollector {
    _priv: (),
}

impl DspCollector {
    pub fn new() -> Self {
        DspCollector { _priv: () }
    }
}

impl Default for DspCollector {
    fn default() -> Self {
        Self::new()
    }
}

impl super::Collector for DspCollector {
    fn id(&self) -> &'static str {
        "dsp"
    }

    fn title(&self) -> &'static str {
        "DSP"
    }

    fn interval(&self) -> Duration {
        Duration::from_secs(2)
    }

    fn probe(&self) -> Availability {
        match crate::exec::which("dsp-ctl") {
            Some(_) => Availability::Present,
            None => Availability::Missing("dsp-ctl not installed — enable custom.dsp"),
        }
    }

    fn collect(&mut self) -> anyhow::Result<Panel> {
        // Stubs bail rather than `todo!()`: a panicking collector thread would
        // take its pane down silently, and the skeleton is meant to render an
        // honest "Failed" state instead.
        anyhow::bail!("dsp collector not implemented")
    }
}
