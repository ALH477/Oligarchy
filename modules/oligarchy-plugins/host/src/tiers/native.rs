//! Tier 1: native `.so` behind the C vtable in include/oligarchy_plugin.h.
//!
//! Runs inside the bwrap namespace, after Landlock and seccomp have been
//! applied by the shim. By the time `dlopen` happens here, the process can
//! already only see the Nix store, /state, /config and whatever the manifest
//! named — so a malicious plugin's constructor has nothing interesting to
//! reach for.
//!
//! This tier exists for one reason: the Wasm boundary is measurable on a
//! sub-millisecond guitar path, and existing native DSP (CLAP, LV2, Faust's
//! C++ backend) already exists and works.

use anyhow::{bail, Context, Result};
use libloading::{Library, Symbol};
use std::ffi::{c_char, c_void, CStr, CString};
use std::path::Path;

use crate::manifest::Manifest;
use crate::plugin::{AudioConfig, ParamInfo, Plugin, Processor};

pub const ABI_MAJOR: u32 = 1;

#[repr(C)]
struct CHost {
    abi_major: u32,
    abi_minor: u32,
    host_data: *mut c_void,
    log: extern "C" fn(*const CHost, u32, *const c_char),
    now_ns: extern "C" fn(*const CHost) -> u64,
    read_config: extern "C" fn(*const CHost, *const c_char) -> *const c_char,
    has_capability: extern "C" fn(*const CHost, *const c_char) -> bool,
}

#[repr(C)]
struct CAudioConfig {
    sample_rate: u32,
    block_size: u32,
    channels: u8,
}

#[repr(C)]
struct CParamInfo {
    id: u32,
    name: *const c_char,
    min: f32,
    max: f32,
    def: f32,
}

#[repr(C)]
struct CProcessor {
    plugin_data: *mut c_void,
    process: extern "C" fn(*const CProcessor, *const f32, *mut f32, u32) -> bool,
    set_param: extern "C" fn(*const CProcessor, u32, f32),
    get_param: extern "C" fn(*const CProcessor, u32) -> f32,
    reset: extern "C" fn(*const CProcessor),
}

#[repr(C)]
struct CPlugin {
    abi_major: u32,
    abi_minor: u32,
    id: *const c_char,
    version: *const c_char,
    init: extern "C" fn(*const CHost) -> bool,
    shutdown: extern "C" fn(),
    create: extern "C" fn(*const CAudioConfig) -> *mut CProcessor,
    destroy: extern "C" fn(*mut CProcessor),
    param_count: extern "C" fn() -> u32,
    param_info: extern "C" fn(u32, *mut CParamInfo) -> bool,
    get_extension: extern "C" fn(*const c_char) -> *const c_void,
}

#[repr(C)]
struct CEntry {
    abi_major: u32,
    abi_minor: u32,
    get: extern "C" fn() -> *const CPlugin,
}

// --- host callbacks exposed to C -----------------------------------------
struct HostData {
    plugin_id: String,
    config: std::collections::BTreeMap<String, String>,
    caps: Vec<String>,
    start: std::time::Instant,
    scratch: std::cell::RefCell<Option<CString>>,
}

extern "C" fn cb_log(h: *const CHost, lvl: u32, msg: *const c_char) {
    let d = unsafe { &*((*h).host_data as *const HostData) };
    let s = unsafe { CStr::from_ptr(msg) }.to_string_lossy();
    match lvl {
        0 => tracing::trace!(plugin = %d.plugin_id, "{s}"),
        1 => tracing::debug!(plugin = %d.plugin_id, "{s}"),
        2 => tracing::info!(plugin = %d.plugin_id, "{s}"),
        3 => tracing::warn!(plugin = %d.plugin_id, "{s}"),
        _ => tracing::error!(plugin = %d.plugin_id, "{s}"),
    }
}

extern "C" fn cb_now_ns(h: *const CHost) -> u64 {
    let d = unsafe { &*((*h).host_data as *const HostData) };
    d.start.elapsed().as_nanos() as u64
}

extern "C" fn cb_read_config(h: *const CHost, key: *const c_char) -> *const c_char {
    let d = unsafe { &*((*h).host_data as *const HostData) };
    let k = unsafe { CStr::from_ptr(key) }.to_string_lossy().into_owned();
    match d.config.get(&k) {
        Some(v) => {
            let c = CString::new(v.as_str()).unwrap_or_default();
            let ptr = c.as_ptr();
            *d.scratch.borrow_mut() = Some(c);
            ptr
        }
        None => std::ptr::null(),
    }
}

extern "C" fn cb_has_capability(h: *const CHost, name: *const c_char) -> bool {
    let d = unsafe { &*((*h).host_data as *const HostData) };
    let n = unsafe { CStr::from_ptr(name) }.to_string_lossy();
    d.caps.iter().any(|c| *c == n)
}

// --- the adapter ----------------------------------------------------------
pub struct NativePlugin {
    manifest: Manifest,
    plugin: *const CPlugin,
    host: Box<CHost>,
    _host_data: Box<HostData>,
    /// LAST. Fields drop in declaration order, so the library must be the
    /// final one: `plugin` points into it and `host` is handed to code inside
    /// it. Declaring it first (as the first version did) ran dlclose while
    /// both were still live.
    _lib: Library,
}

unsafe impl Send for NativePlugin {}

impl NativePlugin {
    pub fn load(
        m: Manifest,
        store_path: &Path,
        config: std::collections::BTreeMap<String, String>,
    ) -> Result<Self> {
        let so = store_path.join(&m.entry);

        // RTLD_NOW: resolve everything up front so a missing symbol fails
        // here, loudly, rather than mid-solo. RTLD_LOCAL so the plugin cannot
        // interpose on the host's symbols.
        let lib = unsafe {
            libloading::os::unix::Library::open(
                Some(&so),
                libc::RTLD_NOW | libc::RTLD_LOCAL,
            )
        }
        .with_context(|| format!("dlopen {}", so.display()))?;
        let lib: Library = lib.into();

        let entry: Symbol<*const CEntry> = unsafe { lib.get(b"oligarchy_plugin_entry_v1\0") }
            .context("plugin does not export oligarchy_plugin_entry_v1")?;
        let entry = unsafe { &**entry };

        if entry.abi_major != ABI_MAJOR {
            bail!(
                "plugin {} built against ABI {}.x, host implements {}.x",
                m.id,
                entry.abi_major,
                ABI_MAJOR
            );
        }

        let plugin = (entry.get)();
        anyhow::ensure!(!plugin.is_null(), "plugin entry returned NULL");

        // Cross-check the manifest against the binary. A mismatch means the
        // manifest was swapped after signing, which is exactly the attack the
        // capability model has to resist.
        let declared = unsafe { CStr::from_ptr((*plugin).id) }.to_string_lossy();
        anyhow::ensure!(
            declared == m.id,
            "manifest id {:?} does not match binary id {:?}",
            m.id,
            declared
        );

        let host_data = Box::new(HostData {
            plugin_id: m.id.clone(),
            config,
            caps: m.caps.host_services.clone(),
            start: std::time::Instant::now(),
            scratch: std::cell::RefCell::new(None),
        });

        let host = Box::new(CHost {
            abi_major: ABI_MAJOR,
            abi_minor: 0,
            host_data: &*host_data as *const HostData as *mut c_void,
            log: cb_log,
            now_ns: cb_now_ns,
            read_config: cb_read_config,
            has_capability: cb_has_capability,
        });

        Ok(Self {
            manifest: m,
            plugin,
            host,
            _host_data: host_data,
            _lib: lib,
        })
    }
}

impl Plugin for NativePlugin {
    fn manifest(&self) -> &Manifest {
        &self.manifest
    }

    fn init(&mut self) -> Result<()> {
        // If the plugin declared jit=self, this is where its code generator
        // runs and where the absent W^X filter matters.
        let ok = unsafe { ((*self.plugin).init)(&*self.host as *const CHost) };
        anyhow::ensure!(ok, "plugin {} init() returned false", self.manifest.id);
        Ok(())
    }

    fn create_processor(&mut self, cfg: AudioConfig) -> Result<Box<dyn Processor>> {
        let c = CAudioConfig {
            sample_rate: cfg.sample_rate,
            block_size: cfg.block_size,
            channels: cfg.channels,
        };
        let p = unsafe { ((*self.plugin).create)(&c) };
        anyhow::ensure!(!p.is_null(), "create() returned NULL");
        Ok(Box::new(NativeProcessor {
            proc_: p,
            destroy: unsafe { (*self.plugin).destroy },
            channels: cfg.channels as usize,
        }))
    }

    fn params(&mut self) -> Result<Vec<ParamInfo>> {
        let n = unsafe { ((*self.plugin).param_count)() };
        let mut out = Vec::with_capacity(n as usize);
        for i in 0..n {
            let mut ci = CParamInfo {
                id: 0,
                name: std::ptr::null(),
                min: 0.0,
                max: 0.0,
                def: 0.0,
            };
            if unsafe { ((*self.plugin).param_info)(i, &mut ci) } && !ci.name.is_null() {
                out.push(ParamInfo {
                    id: ci.id,
                    name: unsafe { CStr::from_ptr(ci.name) }
                        .to_string_lossy()
                        .into_owned(),
                    min: ci.min,
                    max: ci.max,
                    default: ci.def,
                });
            }
        }
        Ok(out)
    }

    fn handle_command(&mut self, verb: &str, _args: &[String]) -> Result<String> {
        let id = CString::new("oligarchy.control/1")?;
        let ext = unsafe { ((*self.plugin).get_extension)(id.as_ptr()) };
        if ext.is_null() {
            bail!("plugin {} does not implement the control extension", self.manifest.id);
        }
        // Extension vtable dispatch omitted for brevity; the shape mirrors
        // CPlugin above.
        Ok(format!("{verb}: ok"))
    }

    fn save_state(&mut self) -> Result<Vec<u8>> {
        Ok(Vec::new())
    }
    fn load_state(&mut self, _blob: &[u8]) -> Result<()> {
        Ok(())
    }

    fn shutdown(&mut self) {
        unsafe { ((*self.plugin).shutdown)() };
    }
}

struct NativeProcessor {
    proc_: *mut CProcessor,
    destroy: extern "C" fn(*mut CProcessor),
    channels: usize,
}

unsafe impl Send for NativeProcessor {}

impl Processor for NativeProcessor {
    fn process(&mut self, input: &[f32], output: &mut [f32]) -> Result<()> {
        let frames = (input.len() / self.channels.max(1)) as u32;
        let ok = unsafe {
            ((*self.proc_).process)(self.proc_, input.as_ptr(), output.as_mut_ptr(), frames)
        };
        anyhow::ensure!(ok, "native process() signalled fault");
        Ok(())
    }
    fn set_param(&mut self, id: u32, v: f32) {
        unsafe { ((*self.proc_).set_param)(self.proc_, id, v) };
    }
    fn get_param(&mut self, id: u32) -> f32 {
        unsafe { ((*self.proc_).get_param)(self.proc_, id) }
    }
    fn reset(&mut self) {
        unsafe { ((*self.proc_).reset)(self.proc_) };
    }
}

impl Drop for NativeProcessor {
    fn drop(&mut self) {
        (self.destroy)(self.proc_);
    }
}
