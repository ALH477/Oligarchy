//! Non-blocking variant of `process::ensure_image` that reports progress as
//! it happens, for `forge-tui`'s live build-log pane. Plain OS threads +
//! `mpsc`, not async — this is a small, bounded fan-in (two log streams
//! into one channel), and a background thread reading lines is the
//! simplest thing that's still fully non-blocking for the caller. No tokio
//! dependency needed for that (see docs/oligarchy-forge-roadmap.md
//! Changelog for why Stage 1 skipped the tokio-process-stream route the
//! source research suggested).

use crate::process::{container_load, persist_config, state_dir, write_flake};
use crate::render::render_flake;
use crate::schema::ForgeConfig;
use anyhow::{Context, Result};
use std::io::{BufRead, BufReader};
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::mpsc::{self, Receiver};
use std::thread;

pub enum BuildEvent {
    /// One line of `nix build -v` progress (stderr) or a status message
    /// this module injects (e.g. "loading image into podman...").
    Line(String),
    /// Terminal event — build+load succeeded, or failed with a message.
    Done(Result<(), String>),
}

/// Renders, `nix build`s, and `<backend> load`s `cfg`, streaming progress
/// lines to the returned channel from background threads. Returns
/// immediately; the caller polls the receiver (e.g. once per UI tick).
pub fn build_and_load_streaming(cfg: ForgeConfig) -> Result<Receiver<BuildEvent>> {
    let dir = state_dir(&cfg.project.name)?;
    persist_config(&dir, &cfg)?;
    let flake_nix = render_flake(&cfg)?;
    write_flake(&dir, &flake_nix)?;

    let flake_ref = format!("path:{}#default", dir.display());
    let mut child = Command::new("nix")
        .args(["build", &flake_ref, "--no-link", "--print-out-paths", "-v"])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .context("spawning `nix build` — is nix on PATH?")?;

    let (tx, rx) = mpsc::channel();
    let stdout = child.stdout.take().context("capturing nix build stdout")?;
    let stderr = child.stderr.take().context("capturing nix build stderr")?;

    // stderr carries `-v` progress; stream it line-by-line as the log.
    let tx_err = tx.clone();
    thread::spawn(move || {
        for line in BufReader::new(stderr).lines().map_while(std::result::Result::ok) {
            if tx_err.send(BuildEvent::Line(line)).is_err() {
                return; // receiver dropped (TUI exited) — stop reading
            }
        }
    });

    // stdout carries only the final `--print-out-paths` line; collect it
    // (not streamed as a log line) rather than draining it inline below,
    // since both pipes must be drained concurrently to avoid the child
    // blocking on a full OS pipe buffer.
    let (out_tx, out_rx) = mpsc::channel();
    thread::spawn(move || {
        let mut last = String::new();
        for line in BufReader::new(stdout).lines().map_while(std::result::Result::ok) {
            last = line;
        }
        let _ = out_tx.send(last);
    });

    let backend = cfg.runtime.backend;
    thread::spawn(move || {
        let wait_result = child.wait();
        let out_path = out_rx.recv().unwrap_or_default();

        let build_result: Result<PathBuf> = match wait_result {
            Ok(status) if status.success() && !out_path.is_empty() => Ok(PathBuf::from(out_path)),
            Ok(status) => Err(anyhow::anyhow!("nix build exited with status {status}")),
            Err(e) => Err(anyhow::anyhow!("waiting on nix build: {e}")),
        };

        let final_result = match build_result {
            Ok(path) => {
                let _ = tx.send(BuildEvent::Line(format!(
                    "loading image into {}...",
                    backend.binary()
                )));
                container_load(backend, &path)
            }
            Err(e) => Err(e),
        };

        let _ = tx.send(BuildEvent::Done(final_result.map_err(|e| format!("{e:#}"))));
    });

    Ok(rx)
}
