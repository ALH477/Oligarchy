//! Tier routing: the one place a manifest becomes an execution strategy.
//!
//! There is no fallback, no "try native and drop to wasm if it fails", no
//! sniffing. The manifest says what it is, policy says whether that is
//! allowed here, and the router either produces a plugin or an error. Any
//! ambiguity in this file is a security bug.

#[cfg(feature = "lua-tier")]
pub mod lua;
pub mod microvm;
#[cfg(feature = "native-tier")]
pub mod native;
pub mod wasm;

use anyhow::{bail, Context, Result};
use std::collections::BTreeMap;
use std::path::Path;

use crate::manifest::{Jit, Manifest, Tier, Trust};
use crate::plugin::Plugin;
use crate::policy::Policy;

pub struct Ctx<'a> {
    /// Only Tier 0 needs one.
    pub engine: Option<&'a wasmtime::Engine>,
    pub store_path: &'a Path,
    pub state_dir: &'a Path,
    pub runtime_dir: &'a Path,
    pub policy: &'a Policy,
    pub config: BTreeMap<String, String>,
}

pub fn load(m: Manifest, ctx: Ctx<'_>) -> Result<Box<dyn Plugin>> {
    ctx.policy.authorize(&m)?;

    tracing::info!(
        plugin = %m.id,
        version = %m.version,
        tier = ?m.tier,
        jit = ?m.jit,
        trust = ?m.trust,
        wx = m.wx_enforced(),
        "loading"
    );

    match m.tier {
        Tier::Wasm => {
            let engine = ctx
                .engine
                .context("tier=wasm requires a wasmtime Engine in Ctx")?;
            Ok(Box::new(wasm::WasmPlugin::load(
                engine,
                m,
                ctx.store_path,
                ctx.state_dir,
                ctx.config,
            )?))
        }
        #[cfg(feature = "native-tier")]
        Tier::Native => Ok(Box::new(native::NativePlugin::load(
            m,
            ctx.store_path,
            ctx.config,
        )?)),
        #[cfg(not(feature = "native-tier"))]
        Tier::Native => bail!("this plugind was built without the native tier"),

        #[cfg(feature = "lua-tier")]
        Tier::Lua => Ok(Box::new(lua::LuaPlugin::load(m, ctx.store_path, ctx.config)?)),
        #[cfg(not(feature = "lua-tier"))]
        Tier::Lua => bail!("this plugind was built without the lua tier"),
        Tier::Microvm => {
            // microvm.nix installs a per-VM runner at this path for both
            // declarative and imperative VMs.
            let runner = Path::new("/var/lib/microvms")
                .join(&m.id)
                .join("current/bin/microvm-run");
            if !runner.exists() {
                bail!(
                    "no microvm runner at {}. Add this plugin to \
                     custom.plugins.declaredPlugins with tier = \"microvm\" and \
                     rebuild; microvm.nix generates the guest.",
                    runner.display()
                );
            }
            Ok(Box::new(microvm::MicrovmPlugin::boot(
                m,
                &runner,
                ctx.runtime_dir,
            )?))
        }
    }
}

/// What the router *would* do, without doing it. Used by `plugind explain`
/// and by the NixOS module's assertions at build time.
pub fn explain(m: &Manifest, policy: &Policy) -> String {
    let mut s = String::new();
    s.push_str(&format!("{} v{}\n", m.id, m.version));
    s.push_str(&format!("  tier    {:?}\n", m.tier));
    s.push_str(&format!("  jit     {:?}\n", m.jit));
    s.push_str(&format!("  trust   {:?}\n", m.trust));
    s.push_str(&format!(
        "  W^X     {}\n",
        match (m.wx_enforced(), m.tier) {
            (true, _) => "enforced (mmap/mprotect PROT_EXEC -> EPERM, memfd_create denied)",
            (false, Tier::Wasm) => "n/a (host runs Cranelift; wasmtime confines the guest)",
            (false, _) => "NOT enforced (jit=self)",
        }
    ));
    s.push_str(&format!(
        "  isolate {}\n",
        match m.tier {
            Tier::Wasm => "wasmtime linear memory + guard pages; host-side Cranelift",
            Tier::Native | Tier::Lua => "bwrap namespaces + landlock + seccomp + cgroup v2",
            Tier::Microvm => "separate guest kernel; vsock transport only",
        }
    ));
    s.push_str(&format!(
        "  network {}\n",
        if !m.caps.network {
            "denied".to_string()
        } else if m.caps.tcp_connect.is_empty() {
            "ALL TCP".to_string()
        } else {
            format!("tcp connect {:?}", m.caps.tcp_connect)
        }
    ));
    s.push_str(&format!(
        "  rt-safe {}\n",
        matches!(m.tier, Tier::Wasm | Tier::Native)
    ));
    match policy.authorize(m) {
        Ok(()) => s.push_str("  policy  PERMITTED\n"),
        Err(e) => s.push_str(&format!("  policy  REFUSED: {e}\n")),
    }
    s
}

/// Suggest the tier a manifest *should* declare, for `plugind lint`. Advisory
/// only — we never silently rewrite what an author declared.
pub fn recommend(m: &Manifest) -> Option<(Tier, &'static str)> {
    match (m.tier, m.jit, m.trust) {
        (Tier::Native, Jit::SelfJit, Trust::Trusted) => Some((
            Tier::Microvm,
            "trusted + self-JIT on the host grants W^X to code you did not \
             write; microvm costs ~125ms of boot and removes the question",
        )),
        (Tier::Native, Jit::None, Trust::Untrusted) => Some((
            Tier::Wasm,
            "untrusted native code gains nothing from being native if it is \
             not JITing; wasm gives you the same speed class with a real \
             memory-safety boundary",
        )),
        _ => None,
    }
}
