//! Interactive extension picker for the project in the current directory.
//! Toggling an extension: (1) runs `ForgeConfig::conflicts()` — a plain
//! Rust check, no Nix involved — and if the just-toggled extension shares a
//! provided binary with something already selected, blocks the toggle
//! behind a chooser instead of silently producing a broken config; (2) on
//! a clean toggle, writes `oligarchy-forge.toml` in place and kicks off a
//! background `nix eval` sanity check (`forge_core::stream::eval_check_streaming`).

use anyhow::Result;
use forge_core::schema::{Extension, ForgeConfig};
use forge_core::stream::{eval_check_streaming, EvalEvent};
use std::path::PathBuf;
use std::sync::mpsc::{Receiver, TryRecvError};
use tui_tree_widget::TreeState;

/// Every extension except the implicit, always-on `Base`, in display order.
pub const SELECTABLE: [Extension; 6] = [
    Extension::Rust,
    Extension::Python,
    Extension::Node,
    Extension::NodeLts,
    Extension::Go,
    Extension::FaustJack,
];

pub enum EvalStatus {
    Idle,
    Checking,
    Ok,
    Error(String),
}

/// A toggle that was blocked because it collides with an already-selected
/// extension — shown as a two-choice prompt until the user resolves it.
pub struct PendingConflict {
    pub new: Extension,
    pub existing: Extension,
    pub shared: Vec<&'static str>,
}

pub struct EditState {
    pub cfg: ForgeConfig,
    pub path: PathBuf,
    pub tree_state: TreeState<&'static str>,
    pub pending_conflict: Option<PendingConflict>,
    pub eval_status: EvalStatus,
    eval_rx: Option<Receiver<EvalEvent>>,
    pub status: String,
}

impl EditState {
    pub fn open(path: PathBuf, project_name: &str) -> Result<Self> {
        let cfg = forge_core::process::load_or_default_project_toml(&path, project_name)?;
        let mut tree_state = TreeState::default();
        tree_state.open(vec!["extensions"]);
        Ok(EditState {
            cfg,
            path,
            tree_state,
            pending_conflict: None,
            eval_status: EvalStatus::Idle,
            eval_rx: None,
            status: "space/enter: toggle  esc: back".into(),
        })
    }

    pub fn is_selected(&self, ext: Extension) -> bool {
        self.cfg.project.extensions.contains(&ext)
    }

    /// Currently-highlighted extension, if the tree cursor is on a leaf
    /// (not the "extensions" category node itself).
    pub fn highlighted(&self) -> Option<Extension> {
        let selected = self.tree_state.selected();
        let leaf_id = selected.last()?;
        if selected.len() < 2 {
            return None; // cursor is on the category node, not a leaf
        }
        SELECTABLE.iter().copied().find(|ext| ext.label() == *leaf_id)
    }

    pub fn toggle(&mut self, ext: Extension) {
        if self.pending_conflict.is_some() {
            return; // resolve the pending conflict first
        }
        if self.is_selected(ext) {
            self.cfg.project.extensions.retain(|e| *e != ext);
            self.after_change();
            return;
        }

        let mut trial = self.cfg.clone();
        trial.project.extensions.push(ext);
        let hit = trial.conflicts().into_iter().find(|(a, b, _)| *a == ext || *b == ext);

        match hit {
            Some((a, b, shared)) => {
                let existing = if a == ext { b } else { a };
                self.pending_conflict = Some(PendingConflict { new: ext, existing, shared });
            }
            None => {
                self.cfg.project.extensions.push(ext);
                self.after_change();
            }
        }
    }

    pub fn resolve_conflict_keep_new(&mut self) {
        let Some(conflict) = self.pending_conflict.take() else { return };
        self.cfg.project.extensions.retain(|e| e != &conflict.existing);
        self.cfg.project.extensions.push(conflict.new);
        self.after_change();
    }

    pub fn resolve_conflict_keep_existing(&mut self) {
        self.pending_conflict = None;
    }

    fn after_change(&mut self) {
        match forge_core::process::write_project_toml(&self.path, &self.cfg) {
            Ok(()) => {
                self.status = format!("saved {}", self.path.display());
                self.start_eval_check();
            }
            Err(e) => {
                self.status = format!("write failed: {e:#}");
            }
        }
    }

    fn start_eval_check(&mut self) {
        self.eval_status = EvalStatus::Checking;
        match eval_check_streaming(self.cfg.clone()) {
            Ok(rx) => self.eval_rx = Some(rx),
            Err(e) => self.eval_status = EvalStatus::Error(format!("{e:#}")),
        }
    }

    /// Non-blocking; call once per UI tick.
    pub fn poll_eval(&mut self) {
        let Some(rx) = self.eval_rx.take() else { return };
        match rx.try_recv() {
            Ok(EvalEvent::Done(Ok(()))) => self.eval_status = EvalStatus::Ok,
            Ok(EvalEvent::Done(Err(e))) => self.eval_status = EvalStatus::Error(e),
            Err(TryRecvError::Empty) => self.eval_rx = Some(rx),
            Err(TryRecvError::Disconnected) => {
                self.eval_status = EvalStatus::Error("eval check channel closed unexpectedly".into());
            }
        }
    }
}
