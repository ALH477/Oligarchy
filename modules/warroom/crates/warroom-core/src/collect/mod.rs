//! The collector trait, the registry, and the thread scheduler.
//!
//! One thread per collector, each on its own interval, all writing into a
//! single channel. The UI thread only ever drains that channel, so a hung
//! subprocess can never block a keypress or a redraw — which is the concrete
//! defect in `oligarchy-warroom.sh` that this whole design exists to fix.

pub mod ai;
pub mod dsp;
pub mod forge;
pub mod mesh;
pub mod net;
pub mod security;
pub mod system;

use crate::model::{Availability, CollectorMsg, Panel};
use std::sync::mpsc::{channel, Receiver, RecvTimeoutError, Sender};
use std::time::{Duration, Instant};

pub trait Collector: Send {
    /// Stable key. Must match the id used in the UI's panel map.
    fn id(&self) -> &'static str;
    /// Display name, uppercase, war-room register.
    fn title(&self) -> &'static str;
    fn interval(&self) -> Duration;
    /// Cheap check that the backing binary or file exists at all. A collector
    /// reporting `Missing` is never polled.
    fn probe(&self) -> Availability;
    fn collect(&mut self) -> anyhow::Result<Panel>;
}

/// Every collector, in SITREP display order.
pub fn all() -> Vec<Box<dyn Collector>> {
    vec![
        Box::new(system::SystemCollector::new()),
        Box::new(dsp::DspCollector::new()),
        Box::new(mesh::MeshCollector::new()),
        Box::new(security::SecurityCollector::new()),
        Box::new(net::NetCollector::new()),
        Box::new(ai::AiCollector::new()),
        Box::new(forge::ForgeCollector::new()),
    ]
}

/// Handles for the running collector threads.
pub struct Scheduler {
    pub rx: Receiver<CollectorMsg>,
    wake: Vec<(&'static str, Sender<()>)>,
}

impl Scheduler {
    /// Ask one collector to re-run now instead of waiting out its interval.
    /// Used after an action that changes the thing being measured.
    pub fn refresh(&self, id: &str) {
        for (cid, tx) in &self.wake {
            if *cid == id {
                let _ = tx.send(());
            }
        }
    }

    pub fn refresh_all(&self) {
        for (_, tx) in &self.wake {
            let _ = tx.send(());
        }
    }
}

/// Spawn one thread per collector. Threads are detached: they end when their
/// wake channel closes, which happens when the `Scheduler` drops at exit.
pub fn spawn(collectors: Vec<Box<dyn Collector>>) -> Scheduler {
    let (tx, rx) = channel();
    let mut wake = Vec::new();

    for mut c in collectors {
        let id = c.id();
        let (wake_tx, wake_rx) = channel::<()>();
        wake.push((id, wake_tx));
        let tx = tx.clone();

        std::thread::Builder::new()
            .name(format!("warroom-{id}"))
            .spawn(move || {
                if let Availability::Missing(why) = c.probe() {
                    let _ = tx.send(CollectorMsg::Unavailable { id, why });
                    return;
                }
                let interval = c.interval();
                loop {
                    let at = Instant::now();
                    let msg = match c.collect() {
                        Ok(panel) => CollectorMsg::Update { id, panel, at },
                        Err(e) => CollectorMsg::Failed { id, err: e.to_string(), at },
                    };
                    if tx.send(msg).is_err() {
                        return; // UI is gone
                    }
                    match wake_rx.recv_timeout(interval) {
                        Ok(()) | Err(RecvTimeoutError::Timeout) => {}
                        Err(RecvTimeoutError::Disconnected) => return,
                    }
                }
            })
            .expect("spawn collector thread");
    }

    Scheduler { rx, wake }
}
