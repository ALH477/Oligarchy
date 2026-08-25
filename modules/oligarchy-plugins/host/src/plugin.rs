//! The common trait. Everything above this line in the stack — the audio
//! graph, the FX Bazaar UI, the CLI — sees only `dyn Plugin` and never learns
//! which tier a plugin runs in.
//!
//! This is the payoff of the "mixed artifacts, one ABI" requirement: the ABI
//! is this trait, the WIT world is its serialised form, and each tier is an
//! adapter.

use anyhow::Result;
use std::fmt;

use crate::manifest::Manifest;

#[derive(Debug, Clone, Copy)]
pub struct AudioConfig {
    pub sample_rate: u32,
    pub block_size: u32,
    pub channels: u8,
}

#[derive(Debug, Clone)]
pub struct ParamInfo {
    pub id: u32,
    pub name: String,
    pub min: f32,
    pub max: f32,
    pub default: f32,
}

/// A loaded, initialised plugin. Dropping it tears down the tier sandbox.
pub trait Plugin: Send {
    fn manifest(&self) -> &Manifest;

    fn init(&mut self) -> Result<()>;

    fn create_processor(&mut self, cfg: AudioConfig) -> Result<Box<dyn Processor>>;

    fn params(&mut self) -> Result<Vec<ParamInfo>>;

    fn handle_command(&mut self, verb: &str, args: &[String]) -> Result<String>;

    fn save_state(&mut self) -> Result<Vec<u8>>;
    fn load_state(&mut self, blob: &[u8]) -> Result<()>;

    fn shutdown(&mut self);
}

/// The realtime half. Tier 0 and Tier 1 make this an in-process call; Tier 2
/// cannot, which is why Tier 2 is not for the audio hot path — a microVM
/// plugin gets block-rate control, not sample-rate processing.
pub trait Processor: Send {
    /// `input` and `output` are interleaved, `channels * frames` long.
    fn process(&mut self, input: &[f32], output: &mut [f32]) -> Result<()>;
    fn set_param(&mut self, id: u32, value: f32);
    fn get_param(&mut self, id: u32) -> f32;
    fn reset(&mut self);

    /// False for Tier 2. The graph checks this before wiring a plugin into a
    /// realtime path rather than discovering the latency at showtime.
    fn is_realtime_safe(&self) -> bool {
        true
    }
}

impl fmt::Debug for dyn Plugin {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let m = self.manifest();
        write!(f, "Plugin({} v{} tier={:?} jit={:?})", m.id, m.version, m.tier, m.jit)
    }
}
