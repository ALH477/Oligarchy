//! Read-only dashboard for `oligarchy-forge`: a session list of every
//! project ever built on this machine (discovered from
//! `forge_core::process::known_project_dirs`) plus a live `nix build` log
//! pane. "Read-only" relative to `oligarchy-forge.toml` — it doesn't edit
//! config or offer the extension picker (that's Stage 2); it does let you
//! trigger a build and watch it stream.

mod app;
mod edit;
mod project;

pub use app::{run, run_edit};
