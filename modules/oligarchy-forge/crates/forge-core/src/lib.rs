//! `forge-core` — the UI-agnostic engine behind `oligarchy-forge`. Parses
//! `oligarchy-forge.toml`, renders it into a `flake.nix`, and drives
//! `nix build` / `podman`. Stage 1's TUI reuses this crate directly instead
//! of duplicating any of this logic — see docs/oligarchy-forge-roadmap.md.

pub mod process;
pub mod render;
pub mod schema;

pub use render::render_flake;
pub use schema::{Backend, Extension, ForgeConfig, Project, Runtime, VolumeMode};
