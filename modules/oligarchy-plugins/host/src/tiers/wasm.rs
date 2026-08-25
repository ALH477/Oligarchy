//! Tier 0: wasmtime component model.
//!
//! This is the default tier and the one the FX Bazaar should insist on for
//! anything unsigned. The security argument is simple: the only JIT in the
//! picture is Cranelift, and Cranelift runs in *our* address space with *our*
//! privileges, compiling code already proven type-safe by validation. The
//! guest never asks the kernel for executable memory.
//!
//! IMPORTANT, and the thing this file exists to document: the unit hosting a
//! Tier 0 plugin runs with MemoryDenyWriteExecute=no. That is not a weakening.
//! Cranelift must be able to mprotect(PROT_EXEC) to publish compiled code, so
//! MDWE here would break Tier 0 outright while hardening nothing — a wasm
//! guest cannot issue a syscall at all except through host functions we wrote.
//! See Manifest::wx_enforced().
//!
//! Config notes, all deliberate:
//!   - pooling allocator + memory_init_cow: instantiation becomes an mmap of a
//!     copy-on-write image, deallocation a single madvise. This is what makes
//!     per-block plugin reloads viable.
//!   - signals_based_traps(true): keeps the 2 GiB guard region and lets
//!     Cranelift elide explicit bounds checks. Turning it off silently
//!     switches to explicit checks AND changes the Spectre posture.
//!   - epoch interruption: a runaway guest loop must not wedge the audio
//!     thread. Fuel would work too but costs more per instruction.
//!   - no wasi:sockets, no filesystem preopens unless the manifest asks. WASI
//!     capabilities are additive from nothing, which is the right default.

use anyhow::{Context, Result};
use std::collections::BTreeMap;
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use wasmtime::component::{Component, Linker, ResourceAny, ResourceTable};
use wasmtime::{Config, Engine, Store, StoreLimits, StoreLimitsBuilder};
use wasmtime_wasi::{WasiCtx, WasiCtxBuilder, WasiCtxView};

use crate::manifest::Manifest;
use crate::plugin::{AudioConfig, ParamInfo, Plugin, Processor};

/// Adapt a `wasmtime::Error` into an `anyhow::Error` so `.context()` applies.
///
/// wasmtime 43's error type deliberately does not implement
/// `std::error::Error`, and `anyhow::Context` is bounded on it — so `?` still
/// works (there is a `From` impl) but every `.context()` on a wasmtime result
/// silently stops compiling. Convert first rather than drop the messages.
fn wt(e: wasmtime::Error) -> anyhow::Error {
    e.into()
}

/// The generated world type is named after the WIT world (`plugin`), which
/// collides with our own `crate::plugin::Plugin` trait. Keep the generated
/// code in its own module and alias it rather than renaming the ABI.
mod bindings {
    wasmtime::component::bindgen!({
        path: "../wit",
        world: "plugin",
        // Keep the audio path synchronous. WASI 0.3's async is attractive for
        // control-plane work but inserts a poll loop between process() and
        // the DAC. On wasmtime 43 `async: false` and `trappable_imports: true`
        // are gone: async and trappability are per-function flags set through
        // an `imports`/`exports` config block, and sync is the default, so
        // simply not asking for `async` is how you stay synchronous.
        imports: { default: trappable },
    });
}

use bindings::exports::oligarchy::plugin::{control, dsp};
use bindings::oligarchy::plugin::host as wit_host;
use bindings::Plugin as PluginWorld;

pub struct HostState {
    ctx: WasiCtx,
    table: ResourceTable,
    limits: StoreLimits,
    plugin_id: String,
    config: BTreeMap<String, String>,
    caps: Vec<String>,
    start: std::time::Instant,
}

// NOTE ON VERSION CHURN: wasmtime split `table()` out of `WasiView` into
// `IoView` around 27.x and merged it back in before 43, where `IoView` no
// longer exists at all. `WasiView::ctx` now hands out a `WasiCtxView` holding
// both borrows at once, which is also what lets the cli/clocks/filesystem
// sub-views be blanket-implemented for us.
impl wasmtime_wasi::WasiView for HostState {
    fn ctx(&mut self) -> WasiCtxView<'_> {
        WasiCtxView {
            ctx: &mut self.ctx,
            table: &mut self.table,
        }
    }
}

// Every one of these is a policy decision point; none touch the filesystem.
impl wit_host::Host for HostState {
    fn log(&mut self, level: wit_host::LogLevel, msg: String) -> wasmtime::Result<()> {
        use wit_host::LogLevel as L;
        match level {
            L::Trace => tracing::trace!(plugin = %self.plugin_id, "{msg}"),
            L::Debug => tracing::debug!(plugin = %self.plugin_id, "{msg}"),
            L::Info => tracing::info!(plugin = %self.plugin_id, "{msg}"),
            L::Warn => tracing::warn!(plugin = %self.plugin_id, "{msg}"),
            L::Error => tracing::error!(plugin = %self.plugin_id, "{msg}"),
        }
        Ok(())
    }

    fn now_ns(&mut self) -> wasmtime::Result<u64> {
        // Monotonic since load, not wall clock. A plugin wanting real time
        // must request wasi:clocks in its manifest and get that audited.
        Ok(self.start.elapsed().as_nanos() as u64)
    }

    fn read_config(&mut self, key: String) -> wasmtime::Result<Option<String>> {
        Ok(self.config.get(&key).cloned())
    }

    fn has_capability(&mut self, name: String) -> wasmtime::Result<bool> {
        Ok(self.caps.iter().any(|c| *c == name))
    }

    fn query_extension(&mut self, name: String) -> wasmtime::Result<Option<u32>> {
        Ok(match name.as_str() {
            "oligarchy.control" => Some(1),
            "oligarchy.params" => Some(1),
            _ => None,
        })
    }
}

/// One Engine per host process, shared across plugins. Engines are expensive
/// to build; Stores are cheap.
pub fn engine() -> Result<Engine> {
    let mut c = Config::new();
    c.wasm_component_model(true);
    // No async_support(false) call: as of wasmtime 43 it is deprecated and has
    // no effect. Synchronous is what you get unless the bindings ask for async,
    // and ours (see the bindgen! above) do not.
    c.epoch_interruption(true);

    let mut pool = wasmtime::PoolingAllocationConfig::default();
    pool.total_component_instances(64);
    pool.total_memories(64);
    pool.max_memory_size(256 << 20);
    c.allocation_strategy(wasmtime::InstanceAllocationStrategy::Pooling(pool));
    c.memory_init_cow(true);

    c.signals_based_traps(true);
    c.cranelift_opt_level(wasmtime::OptLevel::Speed);

    Engine::new(&c).map_err(wt).context("constructing wasmtime engine")
}

struct Ticker {
    stop: AtomicBool,
}

pub struct WasmPlugin {
    manifest: Manifest,
    store: Store<HostState>,
    bindings: PluginWorld,
    ticker: Arc<Ticker>,
    /// Handle to the single live processor, if any.
    ///
    /// Enforcing "at most one" is not a limitation, it is a soundness
    /// requirement: every Processor method needs `&mut Store`, so two live
    /// processors would alias it. The previous version handed out as many as
    /// you asked for and relied on nobody noticing.
    processor: Option<ResourceAny>,
}

impl WasmPlugin {
    pub fn load(
        engine: &Engine,
        m: Manifest,
        store_path: &Path,
        state_dir: &Path,
        config: BTreeMap<String, String>,
    ) -> Result<Self> {
        let artifact = store_path.join(&m.entry);
        let component = Component::from_file(engine, &artifact)
            .map_err(wt)
            .with_context(|| format!("loading component {}", artifact.display()))?;

        let mut linker: Linker<HostState> = Linker::new(engine);
        wasmtime_wasi::p2::add_to_linker_sync(&mut linker)
            .map_err(wt)
            .context("linking wasi")?;
        // wasmtime 43 made the linker's host-state projection a type
        // parameter (`D: HasData`) instead of inferring it from the closure.
        // `HasSelf<T>` is the identity projection: the store data *is* the
        // host state.
        wit_host::add_to_linker::<_, wasmtime::component::HasSelf<HostState>>(
            &mut linker,
            |s: &mut HostState| s,
        )
        .map_err(wt)
        .context("linking oligarchy:plugin/host")?;

        // WASI capabilities start from nothing: no inherited stdio, no
        // inherited env, no preopens except what the manifest named.
        let mut wasi = WasiCtxBuilder::new();
        wasi.stderr(wasmtime_wasi::p2::pipe::MemoryOutputPipe::new(64 << 10));
        for dir in &m.caps.fs_read {
            // Was passing store_path for BOTH state_dir and store_path here,
            // so `$STATE` expanded into the read-only store. It needs the real
            // state dir.
            let host_path = m.expand(dir, state_dir, store_path);
            wasi.preopened_dir(
                &host_path,
                dir,
                wasmtime_wasi::DirPerms::READ,
                wasmtime_wasi::FilePerms::READ,
            )
            .map_err(wt)
            .with_context(|| format!("preopening {}", host_path.display()))?;
        }

        let limits = StoreLimitsBuilder::new()
            .memory_size(m.caps.memory_max.unwrap_or(64 << 20) as usize)
            .instances(1)
            .tables(64)
            .build();

        let state = HostState {
            ctx: wasi.build(),
            table: ResourceTable::new(),
            limits,
            plugin_id: m.id.clone(),
            config,
            caps: m.caps.host_services.clone(),
            start: std::time::Instant::now(),
        };

        let mut store = Store::new(engine, state);
        store.limiter(|s| &mut s.limits);
        store.set_epoch_deadline(1);

        let bindings = PluginWorld::instantiate(&mut store, &component, &linker)
            .map_err(wt)
            .context("instantiating component")?;

        let ticker = Arc::new(Ticker {
            stop: AtomicBool::new(false),
        });
        spawn_ticker(engine.clone(), ticker.clone());

        Ok(Self {
            manifest: m,
            store,
            bindings,
            ticker,
            processor: None,
        })
    }

    fn processor_handle(&self) -> Result<ResourceAny> {
        self.processor
            .ok_or_else(|| anyhow::anyhow!("no processor constructed yet"))
    }
}

/// Bumps the epoch on a timer so a wedged guest traps instead of spinning on
/// the audio thread.
fn spawn_ticker(engine: Engine, ticker: Arc<Ticker>) {
    std::thread::Builder::new()
        .name("oligarchy-epoch".into())
        .spawn(move || {
            while !ticker.stop.load(Ordering::Relaxed) {
                std::thread::sleep(Duration::from_millis(5));
                engine.increment_epoch();
            }
        })
        .ok();
}

impl Drop for WasmPlugin {
    fn drop(&mut self) {
        // Without this the ticker thread outlives every plugin and keeps a
        // clone of the Engine alive with it.
        self.ticker.stop.store(true, Ordering::Relaxed);
    }
}

impl Plugin for WasmPlugin {
    fn manifest(&self) -> &Manifest {
        &self.manifest
    }

    fn init(&mut self) -> Result<()> {
        self.store.set_epoch_deadline(200); // ~1s at 5ms ticks, for setup
        self.bindings
            .call_init(&mut self.store)
            .map_err(wt)
            .context("calling init")?
            .map_err(|e| anyhow::anyhow!("plugin init refused: {e}"))?;
        self.store.set_epoch_deadline(2); // ~10ms in steady state
        Ok(())
    }

    fn create_processor(&mut self, cfg: AudioConfig) -> Result<Box<dyn Processor>> {
        anyhow::ensure!(
            self.processor.is_none(),
            "plugin {} already has a live processor; every Processor call needs \
             &mut Store, so a second one would alias it. Drop the first.",
            self.manifest.id
        );

        let wcfg = dsp::AudioConfig {
            sample_rate: cfg.sample_rate,
            block_size: cfg.block_size,
            channels: cfg.channels,
        };
        let res = self
            .bindings
            .oligarchy_plugin_dsp()
            .processor()
            .call_constructor(&mut self.store, wcfg)
            .map_err(wt)
            .context("constructing processor")?;
        self.processor = Some(res);

        Ok(Box::new(WasmProcessor {
            res,
            // The Box<dyn Plugin> holding this WasmPlugin is heap-pinned, and
            // the registry drops processors before plugins. The `processor`
            // field above enforces the one-at-a-time half of the invariant.
            owner: self as *mut WasmPlugin,
        }))
    }

    fn params(&mut self) -> Result<Vec<ParamInfo>> {
        // Params hang off a processor handle in the WIT, so this needs one to
        // exist. Taking &mut self (rather than &self, as before) is what lets
        // this work at all without casting the borrow away.
        let res = self.processor_handle()?;
        let list = self
            .bindings
            .oligarchy_plugin_dsp()
            .processor()
            .call_params(&mut self.store, res)
            .map_err(wt)
            .context("querying params")?;
        Ok(list
            .into_iter()
            .map(|p| ParamInfo {
                id: p.id,
                name: p.name,
                min: p.min,
                max: p.max,
                default: p.default,
            })
            .collect())
    }

    fn handle_command(&mut self, verb: &str, args: &[String]) -> Result<String> {
        match self
            .bindings
            .oligarchy_plugin_control()
            .call_handle_command(&mut self.store, verb, args)?
        {
            control::CommandResult::Ok(s) => Ok(s),
            control::CommandResult::Err(e) => Err(anyhow::anyhow!(e)),
        }
    }

    fn save_state(&mut self) -> Result<Vec<u8>> {
        Ok(self
            .bindings
            .oligarchy_plugin_control()
            .call_save_state(&mut self.store)?)
    }

    fn load_state(&mut self, blob: &[u8]) -> Result<()> {
        self.bindings
            .oligarchy_plugin_control()
            .call_load_state(&mut self.store, blob)?
            .map_err(|e| anyhow::anyhow!(e))
    }

    fn shutdown(&mut self) {
        let _ = self.bindings.call_shutdown(&mut self.store);
        self.ticker.stop.store(true, Ordering::Relaxed);
    }
}

struct WasmProcessor {
    res: ResourceAny,
    owner: *mut WasmPlugin,
}

// Dereferenced only from the thread owning the Store; the registry guarantees
// the plugin outlives the processor and WasmPlugin::processor guarantees
// there is only ever one.
unsafe impl Send for WasmProcessor {}

impl Drop for WasmProcessor {
    fn drop(&mut self) {
        let p = unsafe { &mut *self.owner };
        p.processor = None;
    }
}

impl Processor for WasmProcessor {
    fn process(&mut self, input: &[f32], output: &mut [f32]) -> Result<()> {
        let p = unsafe { &mut *self.owner };
        let out = p
            .bindings
            .oligarchy_plugin_dsp()
            .processor()
            .call_process(&mut p.store, self.res, input)
            .map_err(wt)
            .context("guest process() trapped")?;
        anyhow::ensure!(
            out.len() == output.len(),
            "plugin returned {} samples, expected {}",
            out.len(),
            output.len()
        );
        output.copy_from_slice(&out);
        Ok(())
    }

    fn set_param(&mut self, id: u32, value: f32) {
        let p = unsafe { &mut *self.owner };
        let _ = p
            .bindings
            .oligarchy_plugin_dsp()
            .processor()
            .call_set_param(&mut p.store, self.res, id, value);
    }

    fn get_param(&mut self, id: u32) -> f32 {
        let p = unsafe { &mut *self.owner };
        p.bindings
            .oligarchy_plugin_dsp()
            .processor()
            .call_get_param(&mut p.store, self.res, id)
            .unwrap_or(0.0)
    }

    fn reset(&mut self) {
        let p = unsafe { &mut *self.owner };
        let _ = p
            .bindings
            .oligarchy_plugin_dsp()
            .processor()
            .call_reset(&mut p.store, self.res);
    }
}
