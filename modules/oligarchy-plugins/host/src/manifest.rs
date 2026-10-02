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

/// The leading variable of a capability and the rest after it, when the
/// variable is a whole component: `"$STATE"` or `"$STATE/..."`.
fn split_var(s: &str) -> Option<(&'static str, &str)> {
    for v in ["$STATE", "$CONFIG", "$STORE"] {
        if let Some(rest) = s.strip_prefix(v) {
            if rest.is_empty() || rest.starts_with('/') {
                return Some((v, rest));
            }
        }
    }
    None
}

fn join_rest(base: PathBuf, rest: &str) -> PathBuf {
    let rest = rest.trim_start_matches('/');
    if rest.is_empty() {
        base
    } else {
        base.join(rest)
    }
}

/// An fs capability names a place: an absolute path, or one expansion
/// variable as its whole first component. `$` appears nowhere else, because
/// `expand` substitutes only that leading variable and the forbidden-path
/// check reads the rest as written.
pub fn anchored(cap: &str) -> bool {
    let rest = match split_var(cap) {
        Some((_, rest)) => rest,
        None if cap.starts_with('/') => cap,
        None => return false,
    };
    !rest.contains('$')
}

/// The plugin id grammar: 1..=64 of `[A-Za-z0-9_-]`.
///
/// An id becomes a systemd instance name (`unit_name`) and a path component
/// (`dropin_dir`, `gcroots/<id>`, `state/<id>`), and root acts on both. So
/// this is checked wherever an id enters, not only where a manifest is
/// loaded: the control socket's `remove`/`enable`/`disable` carry an id
/// typed by an install-group member, and before this was shared,
/// `disable("X.service.d/../../../../etc/systemd/system/sshd")` had root stop
/// a unit and `remove_dir_all` a drop-in directory outside the plugin tree.
pub fn check_id(id: &str) -> Result<()> {
    if id.is_empty() || id.len() > 64 {
        bail!(
            "plugin id {id:?} must be 1..=64 characters (it becomes a systemd \
             instance name, and an empty one would target the template)"
        );
    }
    if !id
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
    {
        bail!("plugin id {id:?} must be [A-Za-z0-9_-]+ (it becomes a systemd instance name)");
    }
    Ok(())
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
        check_id(&self.id)?;
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

        // Fs capabilities must name a place, not a spelling. Every
        // enforcement layer downstream (bwrap binds, Landlock PathFd, WASI
        // preopens) resolves a relative path against the plugin unit's cwd
        // — which for a systemd service is "/". "proc/self/mem" *is*
        // /proc/self/mem there, but policy.rs's forbidden-prefix check can
        // never match a relative spelling, so a cap written relatively
        // silently bypasses forbidden_paths (including the /proc W^X entry).
        // Require an explicit anchor: an absolute path, or exactly one of
        // the three expansion variables -- as a whole leading component, and
        // nowhere else. `expand` used to substitute a variable ANYWHERE, so
        // "/home$STORE" -- one component, `home$STORE`, so not under /home as
        // written -- passed the forbidden-prefix check and opened
        // /home/nix/store/... at launch: the check and the grant saw
        // different paths. See `anchored`.
        for cap in self
            .caps
            .fs_read
            .iter()
            .chain(self.caps.fs_read_write.iter())
        {
            if cap.is_empty() {
                bail!("fs capability must not be empty");
            }
            if !anchored(cap) {
                bail!(
                    "fs capability {cap:?} must be absolute or start with \
                     $STATE/$CONFIG/$STORE; a relative path resolves against \
                     the unit's cwd and bypasses forbidden-prefix policy checks"
                );
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
    /// Does this tier run the plugin under bubblewrap?
    ///
    /// Named because "the bwrap tiers" governs a growing set of decisions —
    /// which systemd directives the drop-in needs, whether AF_NETLINK is
    /// required, which unit gets bubblewrap on its PATH — and it was spelled
    /// out inline in eight places. That is how the two drop-in generators
    /// drifted: `NotifyAccess` and the AF_NETLINK branch each reached the Rust
    /// mirror alone.
    pub fn uses_bwrap(&self) -> bool {
        matches!(self.tier, Tier::Native | Tier::Lua)
    }

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
        self.jit == Jit::SelfJit && self.uses_bwrap()
    }

    /// Expand `$STATE`, `$CONFIG`, `$STORE` in capability paths.
    /// Expand a capability. Only a LEADING variable is expanded (validate()
    /// refuses a `$` anywhere else), so the path checked at install is the
    /// path granted at launch, modulo the variable's own directory.
    pub fn expand(&self, s: &str, state_dir: &Path, store_path: &Path) -> PathBuf {
        match split_var(s) {
            Some(("$STATE", rest)) => join_rest(state_dir.join("state").join(&self.id), rest),
            Some(("$CONFIG", rest)) => join_rest(state_dir.join("config").join(&self.id), rest),
            Some(("$STORE", rest)) => join_rest(store_path.to_path_buf(), rest),
            _ => PathBuf::from(s),
        }
    }

    /// `expand`, for the launch sites (Landlock rules, bwrap binds, WASI
    /// preopens -- each of which FOLLOWS symlinks when it opens the path).
    ///
    /// `$STATE` and `$CONFIG` are the plugin's own writable directories, so
    /// the plugin decides what a name under them is. A cap `"$STATE/x"`
    /// whose `x` the plugin replaced with a symlink to `/proc` passed
    /// `authorize` (it was checked as written) and then had the sandbox
    /// grant `/proc` -- the W^X bypass, and it survives a reinstall because
    /// state is kept. So a cap under a plugin-writable base must still
    /// resolve inside that base; anything else refuses the launch. A path
    /// that does not exist yet is left to the layer that opens it (bwrap's
    /// `-try` binds skip it; Landlock and WASI fail on it).
    pub fn expand_checked(&self, s: &str, state_dir: &Path, store_path: &Path) -> Result<PathBuf> {
        let path = self.expand(s, state_dir, store_path);
        let base = match split_var(s) {
            Some(("$STATE", _)) => state_dir.join("state").join(&self.id),
            Some(("$CONFIG", _)) => state_dir.join("config").join(&self.id),
            _ => return Ok(path),
        };
        let (Ok(real), Ok(real_base)) = (std::fs::canonicalize(&path), std::fs::canonicalize(&base)) else {
            return Ok(path);
        };
        if !real.starts_with(&real_base) {
            bail!(
                "plugin {}: capability {s:?} resolves to {} outside its own directory {}; \
                 refusing to grant it (a symlink planted in plugin-writable state)",
                self.id,
                real.display(),
                real_base.display()
            );
        }
        Ok(path)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The two shapes that passed `authorize` as written and were granted as
    /// something else at launch: a variable inside a path, and a symlink the
    /// plugin planted in its own state directory.
    #[test]
    fn a_variable_only_leads_and_expands_only_there() {
        for ok in ["$STATE", "$STATE/x", "$CONFIG/a/b", "$STORE/share", "/srv/audio"] {
            assert!(anchored(ok), "{ok}");
        }
        for bad in ["/home$STORE", "$STATEX/y", "$STATE/a$STORE", "/proc$STATE", "STATE", "$PATH/x", "x$STATE"] {
            assert!(!anchored(bad), "{bad}");
        }
        let m = plain();
        let st = Path::new("/var/lib/oligarchy/plugins");
        let store = Path::new("/nix/store/aaaa-p");
        assert_eq!(m.expand("$STATE/x", st, store), st.join("state/p/x"));
        assert_eq!(m.expand("$STORE", st, store), store.to_path_buf());
        assert_eq!(m.expand("/srv/a", st, store), PathBuf::from("/srv/a"));
        // validate() refuses a variable inside a path, not just anchored().
        let e = parse(&format!("{}\n[caps]\nfs_read = [\"/home$STORE\"]\n", PLAIN)).unwrap_err();
        assert!(e.to_string().contains("must be absolute"), "{e}");
    }

    const PLAIN: &str = r#"
            id = "p"
            version = "1.0.0"
            tier = "wasm"
            trust = "untrusted"
            entry = "p.wasm"
            abi = "oligarchy:plugin@0.1.0"
        "#;

    fn plain() -> Manifest {
        parse(PLAIN).unwrap()
    }

    #[test]
    fn a_symlink_planted_in_state_is_refused_at_launch() {
        let root = std::env::temp_dir().join(format!("plugind-plant-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join("state/p/data")).unwrap();
        std::os::unix::fs::symlink("/proc", root.join("state/p/x")).unwrap();
        std::os::unix::fs::symlink(root.join("state/p/data"), root.join("state/p/inside")).unwrap();
        let m = plain();
        let store = Path::new("/nix/store/aaaa-p");
        let e = m.expand_checked("$STATE/x", &root, store).unwrap_err();
        assert!(format!("{e:#}").contains("outside its own directory"), "{e:#}");
        assert!(m.expand_checked("$STATE/data", &root, store).is_ok());
        assert!(m.expand_checked("$STATE/inside", &root, store).is_ok(), "a link staying inside is fine");
        assert!(m.expand_checked("$STATE/not-yet", &root, store).is_ok(), "absent: left to the opener");
        let _ = std::fs::remove_dir_all(&root);
    }

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
    fn fs_caps_must_be_anchored() {
        let with_cap = |cap: &str| {
            parse(&format!(
                r#"
                id = "caps"
                version = "1.0.0"
                tier = "native"
                entry = "lib/x.so"
                abi = "oligarchy:plugin@0.1.0"
                [caps]
                fs_read = ["{cap}"]
            "#
            ))
        };
        assert!(with_cap("/usr/share/fonts").is_ok());
        assert!(with_cap("$STATE/ro").is_ok());
        assert!(with_cap("$CONFIG").is_ok());
        assert!(with_cap("$STORE/lib").is_ok());
        // The bypass class: resolved against cwd="/" in every enforcement
        // layer, this names /proc without ever matching the prefix check.
        assert!(with_cap("proc").is_err());
        assert!(with_cap("proc/self/mem").is_err());
        assert!(with_cap("etc/shadow").is_err());
        assert!(with_cap("").is_err());
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
