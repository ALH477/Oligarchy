//! `plugin.toml` — the capability declaration that drives every sandbox
//! decision. Parsed once at install time, re-validated at every enable.
//!
//! The manifest is the *only* input to tier routing. There is no heuristic,
//! no sniffing of the artifact, no "try it and see". If the manifest lies
//! about needing W^X, the plugin gets EPERM on mprotect and dies loudly.

use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Tier {
    /// wasmtime component. Host JITs via Cranelift; guest never sees PROT_EXEC.
    Wasm,
    /// dlopen'd .so behind the C vtable, under bwrap+Landlock+seccomp.
    Native,
    /// mlua/LuaJIT, same sandbox as Native (LuaJIT itself needs W^X).
    Lua,
    /// Firecracker/cloud-hypervisor guest, vsock transport.
    Microvm,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Jit {
    /// Interpreted or AOT. W^X seccomp filter installed, memfd_create denied.
    None,
    /// The *host* JITs the plugin (Cranelift). Guest still gets the W^X filter.
    Host,
    /// The plugin carries its own code generator. Needs writable-then-
    /// executable memory. The W^X filter is NOT installed for this unit.
    #[serde(rename = "self")]
    SelfJit,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Trust {
    /// Built in this repo, signed by us, reviewed.
    FirstParty,
    /// Signed by a key in trustedPublicKeys, from a known author.
    Trusted,
    /// Anything off the FX Bazaar. Assume hostile.
    Untrusted,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields, default)]
pub struct Caps {
    /// Landlock read-only allowlist. `$STATE`, `$CONFIG`, `$STORE` expand.
    pub fs_read: Vec<String>,
    /// Landlock read-write allowlist.
    pub fs_read_write: Vec<String>,
    /// Any outbound TCP at all. False => Landlock net rules deny everything
    /// (kernel >= 6.7) and the bwrap netns has no route regardless.
    pub network: bool,
    /// Specific TCP ports the plugin may connect to. Empty + network=true
    /// means "all ports", which the module can forbid via policy.
    pub tcp_connect: Vec<u16>,
    /// Device nodes to bind into the sandbox, e.g. "/dev/snd/seq".
    pub devices: Vec<String>,
    /// Named host services from the WIT `host` interface.
    pub host_services: Vec<String>,
    /// Hard memory ceiling, bytes. Enforced by cgroup v2 memory.max and,
    /// for Tier 0, by wasmtime StoreLimits.
    pub memory_max: Option<u64>,
    /// CPU ceiling as a percentage of one core. 100 = one full core.
    pub cpu_quota: Option<u32>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Manifest {
    pub id: String,
    pub version: String,
    pub tier: Tier,
    #[serde(default = "default_jit")]
    pub jit: Jit,
    #[serde(default = "default_trust")]
    pub trust: Trust,
    /// Path to the artifact, relative to the plugin's store path.
    pub entry: String,
    /// Must match the WIT package version the host was built against.
    pub abi: String,
    #[serde(default)]
    pub caps: Caps,
    #[serde(default)]
    pub meta: BTreeMap<String, String>,
}

fn default_jit() -> Jit {
    Jit::None
}
fn default_trust() -> Trust {
    // Fail safe. An omitted trust field is the most suspicious possible input.
    Trust::Untrusted
}

pub const SUPPORTED_ABI: &str = "oligarchy:plugin@0.1.0";

impl Manifest {
    pub fn load(path: &Path) -> Result<Self> {
        let raw = std::fs::read_to_string(path)
            .with_context(|| format!("reading manifest {}", path.display()))?;
        let m: Manifest = toml::from_str(&raw)
            .with_context(|| format!("parsing manifest {}", path.display()))?;
        m.validate()?;
        Ok(m)
    }

    /// Structural validation. Policy validation (does *this host* allow
    /// self-JIT at all?) happens in policy.rs against the NixOS module.
    pub fn validate(&self) -> Result<()> {
        if self.abi != SUPPORTED_ABI {
            bail!(
                "plugin {} targets ABI {}, host implements {}",
                self.id,
                self.abi,
                SUPPORTED_ABI
            );
        }
        // Non-empty is not pedantry: `id = ""` makes unit_name() produce
        // "oligarchy-plugin@.service" and dropin_dir() produce that unit's .d
        // directory — a drop-in on the TEMPLATE, i.e. MemoryDenyWriteExecute=no
        // for every instance on the machine, and /run beats /etc so it would
        // also outrank a declared plugin's. Today the install happens to abort
        // later when nix-store cannot unlink a directory; that is luck, not a
        // control.
        if self.id.is_empty() || self.id.len() > 64 {
            bail!(
                "plugin id {:?} must be 1..=64 characters (it becomes a systemd \
                 instance name, and an empty one would target the template)",
                self.id
            );
        }
        if !self
            .id
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
        {
            bail!("plugin id {:?} must be [A-Za-z0-9_-]+ (it becomes a systemd instance name)", self.id);
        }
        if self.entry.starts_with('/') || self.entry.contains("..") {
            bail!("entry {:?} must be relative and must not escape the store path", self.entry);
        }

        // Device capabilities are interpolated into a systemd drop-in
        // (`DeviceAllow=<dev> rw`) that root writes and systemd parses, so an
        // unconstrained string here is unit-directive injection: a newline
        // followed by `User=root` in the drop-in would override the template's
        // unprivileged User= and start the plugin as root. Validated HERE
        // rather than only in bwrap.rs, because bwrap runs at launch — long
        // after the drop-in was written — and only for tier 1, while the
        // drop-in is written for every tier.
        for dev in &self.caps.devices {
            if !dev.starts_with("/dev/") {
                bail!("device capability {dev:?} must be under /dev");
            }
            if !dev
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || matches!(c, '/' | '-' | '_' | '.'))
            {
                bail!(
                    "device capability {dev:?} may contain only [A-Za-z0-9/._-]; \
                     it is written into a systemd unit drop-in"
                );
            }
            if dev.contains("..") {
                bail!("device capability {dev:?} must not contain ..");
            }
        }

        // The core invariant of the whole design.
        match (self.tier, self.jit) {
            (Tier::Wasm, Jit::SelfJit) => bail!(
                "tier=wasm cannot use jit=self: the guest has no way to obtain \
                 executable pages. Use jit=host (Cranelift compiles it) or move \
                 to tier=native."
            ),
            (Tier::Lua, Jit::None) => {
                // LuaJIT always wants W^X. Interpreter-only Lua is fine, but
                // it must say so explicitly rather than inherit the default.
                tracing::warn!(
                    plugin = %self.id,
                    "tier=lua with jit=none forces the LuaJIT interpreter fallback; \
                     set jit=self for compiled traces"
                );
            }
            _ => {}
        }

        if self.jit == Jit::SelfJit && self.trust == Trust::Untrusted && self.tier != Tier::Microvm {
            bail!(
                "plugin {}: untrusted + jit=self must run in tier=microvm. \
                 Granting W^X to unreviewed code on the host is the one thing \
                 this design refuses to do.",
                self.id
            );
        }

        if self.caps.network && self.caps.tcp_connect.is_empty() {
            tracing::warn!(
                plugin = %self.id,
                "network=true with no tcp_connect allowlist grants all ports"
            );
        }
        Ok(())
    }

    /// Whether the systemd unit hosting this plugin gets
    /// MemoryDenyWriteExecute, and whether the shim installs the W^X seccomp
    /// filter.
    ///
    /// This is deliberately NOT just `jit != self`. The unit hosts *plugind*,
    /// not the plugin in isolation, and for tier=wasm plugind is running
    /// Cranelift — which needs mprotect(PROT_EXEC) to publish compiled code.
    /// Setting MDWE on a Tier 0 unit does not harden the guest at all (a wasm
    /// guest cannot issue syscalls except through host functions we wrote); it
    /// just stops the host compiling, and Tier 0 silently stops working.
    ///
    /// So W^X is enforced exactly where the plugin's own machine code shares
    /// the host process's address space AND its syscall access:
    ///
    ///   wasm    -> not enforced. wasmtime's linear memory + guard pages are
    ///              the boundary; seccomp has nothing to protect here.
    ///   microvm -> enforced. The host side is a vsock proxy that never JITs;
    ///              the guest's W+X pages are in the guest's kernel.
    ///   native  -> enforced unless the manifest declares jit=self. THIS is
    ///   lua        the case the whole design exists to get right.
    pub fn wx_enforced(&self) -> bool {
        match self.tier {
            Tier::Wasm => false,
            Tier::Microvm => true,
            Tier::Native | Tier::Lua => self.jit != Jit::SelfJit,
        }
    }

    /// True when W^X is off *because the plugin asked for it*, as opposed to
    /// off because the tier does its own confinement. Only this case is a
    /// concession that needs auditing; `plugind lint` keys off it.
    pub fn grants_wx_to_plugin(&self) -> bool {
        self.jit == Jit::SelfJit && matches!(self.tier, Tier::Native | Tier::Lua)
    }

    /// Expand `$STATE`, `$CONFIG`, `$STORE` in capability paths.
    pub fn expand(&self, s: &str, state_dir: &Path, store_path: &Path) -> PathBuf {
        let config = state_dir.join("config").join(&self.id);
        PathBuf::from(
            s.replace("$STATE", &state_dir.join("state").join(&self.id).to_string_lossy())
                .replace("$CONFIG", &config.to_string_lossy())
                .replace("$STORE", &store_path.to_string_lossy()),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(s: &str) -> Result<Manifest> {
        let m: Manifest = toml::from_str(s)?;
        m.validate()?;
        Ok(m)
    }

    #[test]
    fn rejects_untrusted_self_jit_on_host() {
        let e = parse(
            r#"
            id = "evil"
            version = "1.0.0"
            tier = "native"
            jit = "self"
            trust = "untrusted"
            entry = "lib/evil.so"
            abi = "oligarchy:plugin@0.1.0"
        "#,
        )
        .unwrap_err();
        assert!(e.to_string().contains("microvm"));
    }

    #[test]
    fn rejects_wasm_self_jit() {
        assert!(parse(
            r#"
            id = "confused"
            version = "1.0.0"
            tier = "wasm"
            jit = "self"
            trust = "first-party"
            entry = "module.wasm"
            abi = "oligarchy:plugin@0.1.0"
        "#
        )
        .is_err());
    }

    #[test]
    fn defaults_to_paranoid() {
        // Every field the manifest is allowed to omit must default to the
        // least-privileged answer.
        let m = parse(
            r#"
            id = "plain"
            version = "1.0.0"
            tier = "wasm"
            entry = "module.wasm"
            abi = "oligarchy:plugin@0.1.0"
        "#,
        )
        .unwrap();
        assert_eq!(m.trust, Trust::Untrusted);
        assert_eq!(m.jit, Jit::None);
        assert!(!m.caps.network);

        // ...but W^X is NOT one of those fields, and this test used to claim
        // it was. On tier=wasm the unit hosts Cranelift, so enforcing W^X
        // there breaks Tier 0 outright while hardening nothing. See
        // wx_enforced(); checks.wx-enforcement asserts the same thing against
        // a real kernel, and modules/plugins.nix mirrors it as `wxEnforced`.
        assert!(!m.wx_enforced());
        assert!(!m.grants_wx_to_plugin());
    }

    #[test]
    fn wx_is_enforced_where_it_means_something() {
        // The mirror of the above: a native plugin that does not ask for a
        // JIT gets the filter, and one that does gets it withdrawn — and only
        // the latter counts as a concession the auditor needs to see.
        let plain = parse(
            r#"
            id = "np"
            version = "1.0.0"
            tier = "native"
            entry = "lib/libnp.so"
            abi = "oligarchy:plugin@0.1.0"
        "#,
        )
        .unwrap();
        assert!(plain.wx_enforced());
        assert!(!plain.grants_wx_to_plugin());

        let jitty = parse(
            r#"
            id = "jp"
            version = "1.0.0"
            tier = "native"
            jit = "self"
            trust = "trusted"
            entry = "lib/libjp.so"
            abi = "oligarchy:plugin@0.1.0"
        "#,
        )
        .unwrap();
        assert!(!jitty.wx_enforced());
        assert!(jitty.grants_wx_to_plugin());
    }

    #[test]
    fn rejects_empty_and_overlong_id() {
        let with_id = |id: &str| {
            parse(&format!(
                r#"
                id = "{id}"
                version = "1.0.0"
                tier = "wasm"
                entry = "module.wasm"
                abi = "oligarchy:plugin@0.1.0"
            "#
            ))
        };
        // An empty id addresses the template unit, not an instance.
        assert!(with_id("").is_err());
        assert!(with_id(&"a".repeat(65)).is_err());
        assert!(with_id(&"a".repeat(64)).is_ok());
    }

    #[test]
    fn rejects_device_injection() {
        // The drop-in writer interpolates devices into a file systemd parses as
        // root, so a newline here would be a unit-directive injection. The
        // nastiest form is the one that wins outright: User=root.
        let evil = |dev: &str| {
            parse(&format!(
                r#"
                id = "dev"
                version = "1.0.0"
                tier = "native"
                entry = "lib/x.so"
                abi = "oligarchy:plugin@0.1.0"
                [caps]
                devices = ["{dev}"]
            "#
            ))
        };
        assert!(evil("/dev/snd/seq").is_ok());
        assert!(evil("/dev/null rw\nUser=root").is_err());
        assert!(evil("/dev/null\nExecStartPre=/bin/sh").is_err());
        assert!(evil("/etc/shadow").is_err());
        assert!(evil("/dev/../etc/shadow").is_err());
        assert!(evil("/dev/$(id)").is_err());
    }

    #[test]
    fn rejects_traversal_entry() {
        assert!(parse(
            r#"
            id = "esc"
            version = "1.0.0"
            tier = "native"
            entry = "../../../../bin/sh"
            abi = "oligarchy:plugin@0.1.0"
        "#
        )
        .is_err());
    }
}
