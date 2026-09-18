//! Data layer for the Oligarchy War Room.
//!
//! Deliberately free of any TUI dependency: everything here is equally usable
//! by the Ratatui front-end, by `warroom status --json`, and by whatever reads
//! that JSON later.

pub mod actions;
pub mod collect;
pub mod exec;
pub mod model;
pub mod theme;

pub use collect::{Collector, Scheduler};
pub use model::{
    Availability, CollectorMsg, Freshness, Health, Panel, PanelState, Row, Snapshot, SnapshotPanel,
    Table,
};
