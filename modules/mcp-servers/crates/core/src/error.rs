//! Shared error types.

use thiserror::Error;

pub type Result<T, E = Error> = std::result::Result<T, E>;

#[derive(Debug, Error)]
pub enum Error {
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),

    #[error("path escapes flake directory: {0}")]
    PathEscape(String),

    #[error("not a file: {0}")]
    NotAFile(String),

    #[error("command unavailable on PATH: {0}")]
    Unavailable(String),

    #[error("command timed out after {timeout}s: {cmd}")]
    Timeout { cmd: String, timeout: u64 },

    #[error("command failed (exit {code}): {stderr}")]
    Exit { code: i32, stderr: String },
}