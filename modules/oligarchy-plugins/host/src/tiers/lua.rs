//! Tier 1: Lua, via mlua with the LuaJIT backend.
//!
//! LuaJIT is the interesting case for this whole design, because LuaJIT is
//! itself a JIT: it wants writable-then-executable memory for its trace
//! compiler. So a Lua plugin is the cheapest possible way to exercise the
//! `jit = "self"` path, and the cheapest way to get it wrong.
//!
//!   jit = "none"  -> the W^X filter is installed. LuaJIT's mcode allocator
//!                    gets EPERM from mprotect and falls back to the
//!                    interpreter. Correct, ~3-5x slower, and it will not
//!                    tell you it happened unless you ask (see `jit.status`).
//!   jit = "self"  -> the filter is omitted; traces compile; full speed.
//!
//! We check `jit.status()` after load and log the discrepancy, because a
//! silently-deoptimised DSP script is a support ticket that takes a week to
//! diagnose.
//!
//! The Lua environment is a *whitelist*: `io`, `os`, `package`, `require`,
//! `load`, `loadstring`, `dofile` and `debug` are all removed. A Lua plugin
//! reaches the outside world through the `host` table or not at all. That is
//! the same capability posture as Tier 0, enforced in userspace rather than
//! by the runtime, which is exactly why Lua plugins are `trusted` at best and
//! never `first-party`-equivalent on the strength of the sandbox alone.

use anyhow::{bail, Context, Result};
use mlua::{Function, Lua, LuaOptions, StdLib, Table, Value};
use std::collections::BTreeMap;
use std::path::Path;
use std::sync::{Arc, Mutex};

use crate::manifest::{Jit, Manifest};
use crate::plugin::{AudioConfig, ParamInfo, Plugin, Processor};

pub struct LuaPlugin {
    manifest: Manifest,
    lua: Arc<Mutex<Lua>>,
    /// Registry key for the table the module returned.
    module: mlua::RegistryKey,
}

impl LuaPlugin {
    pub fn load(m: Manifest, store_path: &Path, config: BTreeMap<String, String>) -> Result<Self> {
        // Deliberately narrow stdlib. No IO, no OS, no PACKAGE (which would
        // bring `require` and with it arbitrary .so loading, defeating the
        // whole tier distinction).
        let libs = StdLib::TABLE | StdLib::STRING | StdLib::MATH | StdLib::BIT | StdLib::JIT;
        let lua = Lua::new_with(libs, LuaOptions::default()).context("creating lua state")?;

        Self::report_jit_status(&lua, &m);
        Self::install_host_table(&lua, &m, config)?;
        Self::strip_dangerous_globals(&lua)?;

        let entry = store_path.join(&m.entry);
        let src = std::fs::read_to_string(&entry)
            .with_context(|| format!("reading {}", entry.display()))?;

        let value: Value = lua
            .load(&src)
            .set_name(format!("@{}", m.id))
            .eval()
            .with_context(|| format!("evaluating {}", entry.display()))?;

        let table = match value {
            Value::Table(t) => t,
            other => bail!(
                "plugin {} must return a table, got {}",
                m.id,
                other.type_name()
            ),
        };

        for required in ["init", "create"] {
            if !matches!(table.get::<Value>(required)?, Value::Function(_)) {
                bail!("plugin {} is missing required function `{required}`", m.id);
            }
        }

        let module = lua.create_registry_value(table)?;
        Ok(Self {
            manifest: m,
            lua: Arc::new(Mutex::new(lua)),
            module,
        })
    }

    /// LuaJIT reports whether the compiler is live. If the manifest said
    /// jit=self but the compiler is off, something in the sandbox is stricter
    /// than we think and the plugin is quietly running 4x slow.
    fn report_jit_status(lua: &Lua, m: &Manifest) {
        let compiled = (|| -> Result<bool> {
            let jit: Table = lua.globals().get("jit")?;
            let status: Function = jit.get("status")?;
            Ok(status.call::<bool>(())?)
        })()
        .unwrap_or(false);

        match (m.jit, compiled) {
            (Jit::SelfJit, false) => tracing::error!(
                plugin = %m.id,
                "manifest declares jit=self but LuaJIT reports the compiler is OFF. \
                 Either the W^X filter was installed anyway, or the kernel/SELinux \
                 policy is denying executable mappings. Expect ~4x slower DSP."
            ),
            (Jit::None, true) => tracing::warn!(
                plugin = %m.id,
                "LuaJIT compiler is ON despite jit=none; the W^X filter did not take"
            ),
            (Jit::SelfJit, true) => {
                tracing::info!(plugin = %m.id, "LuaJIT trace compiler active")
            }
            _ => tracing::debug!(plugin = %m.id, "LuaJIT interpreter mode (jit=none)"),
        }
    }

    fn install_host_table(lua: &Lua, m: &Manifest, config: BTreeMap<String, String>) -> Result<()> {
        let host = lua.create_table()?;
        let id = m.id.clone();

        let log_id = id.clone();
        host.set(
            "log",
            lua.create_function(move |_, (level, msg): (String, String)| {
                match level.as_str() {
                    "trace" => tracing::trace!(plugin = %log_id, "{msg}"),
                    "debug" => tracing::debug!(plugin = %log_id, "{msg}"),
                    "warn" => tracing::warn!(plugin = %log_id, "{msg}"),
                    "error" => tracing::error!(plugin = %log_id, "{msg}"),
                    _ => tracing::info!(plugin = %log_id, "{msg}"),
                }
                Ok(())
            })?,
        )?;

        let start = std::time::Instant::now();
        host.set(
            "now_ns",
            lua.create_function(move |_, ()| Ok(start.elapsed().as_nanos() as u64))?,
        )?;

        host.set(
            "read_config",
            lua.create_function(move |_, key: String| Ok(config.get(&key).cloned()))?,
        )?;

        let caps = m.caps.host_services.clone();
        host.set(
            "has_capability",
            lua.create_function(move |_, name: String| Ok(caps.iter().any(|c| *c == name)))?,
        )?;

        lua.globals().set("host", host)?;
        Ok(())
    }

    fn strip_dangerous_globals(lua: &Lua) -> Result<()> {
        // Belt and braces: even though we never loaded these libs, LuaJIT
        // preloads some of them, and `load`/`loadstring` would let a plugin
        // build new chunks at runtime that bypass our source review.
        for g in [
            "io", "os", "package", "require", "dofile", "loadfile", "load", "loadstring", "debug",
            "collectgarbage", "newproxy",
        ] {
            lua.globals().set(g, Value::Nil)?;
        }
        Ok(())
    }
}

impl Plugin for LuaPlugin {
    fn manifest(&self) -> &Manifest {
        &self.manifest
    }

    fn init(&mut self) -> Result<()> {
        let lua = self.lua.lock().unwrap();
        let module: Table = lua.registry_value(&self.module)?;
        let f: Function = module.get("init")?;
        let r: Value = f.call::<Value>(())?;
        if let Value::String(e) = r {
            bail!("plugin {} init refused: {}", self.manifest.id, e.to_str()?);
        }
        Ok(())
    }

    fn exports_dsp(&self) -> bool {
        // The Lua adapter's version of get_extension: a module that processes
        // audio provides `create`. Everything else is control-only, which for a
        // scripting tier is the overwhelmingly common shape — Lua is glue here,
        // not the audio hot path.
        let Ok(lua) = self.lua.lock() else {
            return false;
        };
        let Ok(module) = lua.registry_value::<Table>(&self.module) else {
            return false;
        };
        matches!(module.get::<Value>("create"), Ok(Value::Function(_)))
    }

    fn create_processor(&mut self, cfg: AudioConfig) -> Result<Option<Box<dyn Processor>>> {
        let lua = self.lua.lock().unwrap();
        let module: Table = lua.registry_value(&self.module)?;
        // Absent `create` means a control-only module. Not an error.
        let Value::Function(create) = module.get::<Value>("create")? else {
            return Ok(None);
        };

        let t = lua.create_table()?;
        t.set("sample_rate", cfg.sample_rate)?;
        t.set("block_size", cfg.block_size)?;
        t.set("channels", cfg.channels)?;

        let proc_: Table = create.call::<Table>(t)?;
        let key = lua.create_registry_value(proc_)?;
        drop(lua);

        Ok(Some(Box::new(LuaProcessor {
            lua: self.lua.clone(),
            proc_: key,
            channels: cfg.channels as usize,
            scratch: Vec::with_capacity((cfg.block_size * cfg.channels as u32) as usize),
        })))
    }

    fn params(&mut self) -> Result<Vec<ParamInfo>> {
        let lua = self.lua.lock().unwrap();
        let module: Table = lua.registry_value(&self.module)?;
        let mut out = Vec::new();
        if let Ok(Value::Function(f)) = module.get::<Value>("params") {
            let list: Table = f.call::<Table>(())?;
            for pair in list.sequence_values::<Table>() {
                let t = pair?;
                out.push(ParamInfo {
                    id: t.get("id")?,
                    name: t.get("name")?,
                    min: t.get("min").unwrap_or(0.0),
                    max: t.get("max").unwrap_or(1.0),
                    default: t.get("default").unwrap_or(0.0),
                });
            }
        }
        Ok(out)
    }

    fn handle_command(&mut self, verb: &str, args: &[String]) -> Result<String> {
        let lua = self.lua.lock().unwrap();
        let module: Table = lua.registry_value(&self.module)?;
        let f: Function = module.get("handle_command")?;
        Ok(f.call::<String>((verb, args.to_vec()))?)
    }

    fn save_state(&mut self) -> Result<Vec<u8>> {
        let lua = self.lua.lock().unwrap();
        let module: Table = lua.registry_value(&self.module)?;
        match module.get::<Value>("save_state")? {
            Value::Function(f) => Ok(f.call::<mlua::String>(())?.as_bytes().to_vec()),
            _ => Ok(Vec::new()),
        }
    }

    fn load_state(&mut self, blob: &[u8]) -> Result<()> {
        let lua = self.lua.lock().unwrap();
        let module: Table = lua.registry_value(&self.module)?;
        if let Value::Function(f) = module.get::<Value>("load_state")? {
            f.call::<()>(lua.create_string(blob)?)?;
        }
        Ok(())
    }

    fn shutdown(&mut self) {
        if let Ok(lua) = self.lua.lock() {
            if let Ok(module) = lua.registry_value::<Table>(&self.module) {
                if let Ok(Value::Function(f)) = module.get::<Value>("shutdown") {
                    let _ = f.call::<()>(());
                }
            }
        }
    }
}

struct LuaProcessor {
    lua: Arc<Mutex<Lua>>,
    proc_: mlua::RegistryKey,
    channels: usize,
    scratch: Vec<f32>,
}

impl Processor for LuaProcessor {
    fn process(&mut self, input: &[f32], output: &mut [f32]) -> Result<()> {
        // Not allocation-free: crossing into Lua costs a table build. This is
        // why Lua is a *control and glue* tier, not a hot-path tier. The graph
        // should run Lua plugins at block rate, not sample rate.
        let lua = self.lua.lock().unwrap();
        let proc_: Table = lua.registry_value(&self.proc_)?;
        let f: Function = proc_.get("process")?;
        let inp = lua.create_sequence_from(input.iter().copied())?;
        let out: Table = f.call::<Table>((proc_.clone(), inp))?;
        self.scratch.clear();
        for v in out.sequence_values::<f32>() {
            self.scratch.push(v?);
        }
        anyhow::ensure!(
            self.scratch.len() == output.len(),
            "lua plugin returned {} samples, expected {}",
            self.scratch.len(),
            output.len()
        );
        output.copy_from_slice(&self.scratch);
        Ok(())
    }

    fn set_param(&mut self, id: u32, value: f32) {
        if let Ok(lua) = self.lua.lock() {
            if let Ok(p) = lua.registry_value::<Table>(&self.proc_) {
                if let Ok(f) = p.get::<Function>("set_param") {
                    let _ = f.call::<()>((p.clone(), id, value));
                }
            }
        }
    }

    fn get_param(&mut self, id: u32) -> f32 {
        (|| -> Result<f32> {
            let lua = self.lua.lock().unwrap();
            let p: Table = lua.registry_value(&self.proc_)?;
            let f: Function = p.get("get_param")?;
            Ok(f.call::<f32>((p.clone(), id))?)
        })()
        .unwrap_or(0.0)
    }

    fn reset(&mut self) {
        if let Ok(lua) = self.lua.lock() {
            if let Ok(p) = lua.registry_value::<Table>(&self.proc_) {
                if let Ok(f) = p.get::<Function>("reset") {
                    let _ = f.call::<()>(p.clone());
                }
            }
        }
    }

    fn is_realtime_safe(&self) -> bool {
        false
    }
}
