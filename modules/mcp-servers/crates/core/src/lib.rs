//! Shared core for every Oligarchy MCP server.
//!
//! - [`audit`] — per-aspect audit log; never panics.
//! - [`allowlist`] — compile-time-checked CLI allowlists per aspect.
//! - [`sandbox`] — sandboxed reads confined to the flake directory.
//! - [`runner`] — stdio runner wrapping the MCP server entry point.
//! - [`error`] — shared error types.

pub mod allowlist;
pub mod audit;
pub mod error;
pub mod runner;
pub mod runner_mcp;
pub mod sandbox;

pub use error::{Error, Result};