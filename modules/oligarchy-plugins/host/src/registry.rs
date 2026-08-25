//! The imperative half: a mutable registry over immutable store paths.
//!
//! THE SEAM. This is the file that reconciles "NixOS is declarative" with
//! "the user wants to install a plugin at 2am without a rebuild".
//!
//! What stays declarative (in the flake, reviewed, reproducible):
//!   - the policy (policy.json)
//!   - the plugind binary and its closure
//!   - the systemd template unit oligarchy-plugin@.service
//!   - the state directory layout (tmpfiles)
//!   - the set of trusted public keys
//!
//! What is imperative (mutable, at runtime, no rebuild):
//!   - which plugins exist
//!   - which are enabled
//!   - their config
//!
//! The trick that makes per-plugin sandboxing work with a *template* unit:
//! MemoryDenyWriteExecute has to vary per instance, and a systemd template
//! cannot express that. So on enable we write a drop-in to
//! /run/systemd/system/oligarchy-plugin@<id>.service.d/10-jit.conf and
//! daemon-reload. /run is tmpfs, so the drop-ins evaporate on reboot and are
//! regenerated from the registry by plugind's own startup — which means the
//! registry, not /run, is the source of truth, and a corrupted drop-in cannot
//! survive a reboot to silently grant W^X.
//!
//! TRUST MODEL, stated plainly because it is the easiest thing to get wrong:
//! we never add anyone to nix.settings.trusted-users. Per the Nix manual,
//! that is equivalent to giving root. Instead the FX Bazaar is a *signed*
//! binary cache listed in trusted-substituters, its key is in
//! trusted-public-keys, and every path is verified before it is registered.
//! An unprivileged user can therefore install a signed plugin and cannot
//! install anything else.

use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::process::Command;

use crate::manifest::{Manifest, Tier};
use crate::policy::Policy;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Entry {
    pub manifest: Manifest,
    /// Absolute /nix/store path. Content-addressed, immutable, GC-rooted.
    pub store_path: PathBuf,
    pub enabled: bool,
    pub installed_at: String,
    /// Where it came from, for `plugind list` and for audit.
    pub source: String,
    pub signature_verified: bool,
}

#[derive(Debug, Default, Serialize, Deserialize)]
pub struct Registry {
    #[serde(default)]
    pub entries: BTreeMap<String, Entry>,
}

pub struct Store {
    pub root: PathBuf,
    reg: Registry,
}

impl Store {
    pub fn open(state_dir: &Path) -> Result<Self> {
        let root = state_dir.to_path_buf();
        std::fs::create_dir_all(root.join("registry"))?;
        std::fs::create_dir_all(root.join("state"))?;
        std::fs::create_dir_all(root.join("config"))?;
        std::fs::create_dir_all(root.join("gcroots"))?;

        let path = root.join("registry/registry.json");
        let reg = match std::fs::read_to_string(&path) {
            Ok(s) => serde_json::from_str(&s).context("parsing registry.json")?,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Registry::default(),
            Err(e) => return Err(e).context("reading registry.json"),
        };
        Ok(Self { root, reg })
    }

    fn flush(&self) -> Result<()> {
        // Write-rename so a crash mid-write cannot leave a registry that
        // parses as "no plugins are confined".
        let path = self.root.join("registry/registry.json");
        let tmp = path.with_extension("json.tmp");
        std::fs::write(&tmp, serde_json::to_vec_pretty(&self.reg)?)?;
        std::fs::rename(&tmp, &path)?;
        Ok(())
    }

    pub fn entries(&self) -> impl Iterator<Item = &Entry> {
        self.reg.entries.values()
    }

    pub fn get(&self, id: &str) -> Option<&Entry> {
        self.reg.entries.get(id)
    }

    // --- install ---------------------------------------------------------

    /// Resolve a source to a store path, verify it, validate the manifest
    /// against policy, and record it. Does NOT start anything.
    ///
    /// `source` is a flake ref (`github:...#pkg`), an installable
    /// (`oligarchy-fx#tape`), or a local path for development.
    ///
    /// A local path is accepted only if it resolves into /nix/store — a
    /// symlink such as /etc/oligarchy/plugins/foo counts, a plain directory
    /// under /home does not. That is not a convenience check: everything below
    /// (signature verification, the GC root, immutability of the artifact
    /// while the plugin runs) assumes the artifact is a store path, and a
    /// mutable source directory would quietly invalidate all three.
    pub fn install(&mut self, source: &str, policy: &Policy, allow_unsigned: bool) -> Result<String> {
        let store_path = match local_store_path(source) {
            Some(p) => {
                if !allow_unsigned {
                    bail!(
                        "refusing a bare store path without --allow-unsigned; this \
                         bypasses signature verification and is for development only"
                    );
                }
                p
            }
            None => realise(source)?,
        };

        let verified = verify_signature(&store_path)?;
        if policy.require_signature && !verified && !allow_unsigned {
            bail!(
                "{} has no valid signature from a trusted key. Either publish it \
                 through the signed cache or pass --allow-unsigned on a machine \
                 where policy permits it.",
                store_path.display()
            );
        }

        let manifest = Manifest::load(&store_path.join("plugin.toml")).with_context(|| {
            format!("{} does not contain a plugin.toml", store_path.display())
        })?;

        policy
            .authorize(&manifest)
            .with_context(|| format!("host policy refused plugin {}", manifest.id))?;

        // Pin against the garbage collector. Without this, the next `nix
        // store gc` deletes a plugin out from under a running rig.
        let root = self.root.join("gcroots").join(&manifest.id);
        let _ = std::fs::remove_file(&root);
        std::os::unix::fs::symlink(&store_path, &root)
            .with_context(|| format!("creating GC root {}", root.display()))?;

        std::fs::create_dir_all(self.root.join("state").join(&manifest.id))?;
        std::fs::create_dir_all(self.root.join("config").join(&manifest.id))?;

        let id = manifest.id.clone();
        self.reg.entries.insert(
            id.clone(),
            Entry {
                manifest,
                store_path,
                enabled: false,
                installed_at: now_stamp(),
                source: source.to_string(),
                signature_verified: verified,
            },
        );
        self.flush()?;
        Ok(id)
    }

    pub fn remove(&mut self, id: &str) -> Result<()> {
        self.disable(id).ok();
        self.reg
            .entries
            .remove(id)
            .with_context(|| format!("no such plugin {id}"))?;
        let _ = std::fs::remove_file(self.root.join("gcroots").join(id));
        // State is deliberately NOT deleted. Removing a plugin should not
        // destroy the user's presets. `plugind purge` does that, loudly.
        self.flush()
    }

    pub fn purge(&mut self, id: &str) -> Result<()> {
        self.remove(id)?;
        let _ = std::fs::remove_dir_all(self.root.join("state").join(id));
        let _ = std::fs::remove_dir_all(self.root.join("config").join(id));
        Ok(())
    }

    // --- enable / disable -------------------------------------------------

    /// Write the drop-in, reload, record the plugin as enabled, and — unless
    /// `start` is false — start it.
    pub fn enable(&mut self, id: &str, start: bool) -> Result<()> {
        let e = self
            .reg
            .entries
            .get_mut(id)
            .with_context(|| format!("no such plugin {id}"))?;
        write_dropin(&e.manifest)?;
        daemon_reload()?;

        // Persist BEFORE starting, not after. Once the drop-in is on disk and
        // the manager has been reloaded, this plugin IS enabled; returning
        // early on a start failure would leave the registry claiming otherwise,
        // so the next reconcile would not regenerate the drop-in and the state
        // in /run and the state on disk would disagree about a W^X grant. A
        // plugin that cannot start is still an enabled plugin — that is what
        // Restart= and StartLimitBurst on the template unit are for. The start
        // error is still returned, so `plugind enable` exits non-zero.
        e.enabled = true;
        self.flush()?;
        if start {
            systemctl(&["start", &unit_name(id)])
        } else {
            Ok(())
        }
    }

    pub fn disable(&mut self, id: &str) -> Result<()> {
        let _ = systemctl(&["stop", &unit_name(id)]);
        remove_dropin(id)?;
        daemon_reload()?;
        if let Some(e) = self.reg.entries.get_mut(id) {
            e.enabled = false;
        }
        self.flush()
    }

    /// Called on plugind startup. /run is tmpfs, so every drop-in is gone
    /// after a reboot; regenerate them from the registry, which is the
    /// authority. Also re-authorizes everything against current policy, so a
    /// `nixos-rebuild` that tightens the policy takes effect on next boot
    /// without anyone having to remember to re-check.
    pub fn reconcile(&mut self, policy: &Policy) -> Result<()> {
        let mut disable = Vec::new();
        for (id, e) in &self.reg.entries {
            if !e.enabled {
                continue;
            }
            if let Err(err) = policy.authorize(&e.manifest) {
                tracing::error!(
                    plugin = %id,
                    error = %err,
                    "policy no longer permits this plugin; disabling"
                );
                disable.push(id.clone());
                continue;
            }
            if !e.store_path.exists() {
                tracing::error!(plugin = %id, "store path vanished (GC?); disabling");
                disable.push(id.clone());
                continue;
            }
            write_dropin(&e.manifest)?;
        }
        for id in disable {
            self.disable(&id)?;
        }
        daemon_reload()?;
        Ok(())
    }

    pub fn config_for(&self, id: &str) -> BTreeMap<String, String> {
        let path = self.root.join("config").join(id).join("config.toml");
        std::fs::read_to_string(path)
            .ok()
            .and_then(|s| toml::from_str(&s).ok())
            .unwrap_or_default()
    }
}

// --- systemd glue ---------------------------------------------------------

fn unit_name(id: &str) -> String {
    format!("oligarchy-plugin@{id}.service")
}

fn dropin_dir(id: &str) -> PathBuf {
    PathBuf::from("/run/systemd/system").join(format!("{}.d", unit_name(id)))
}

/// The per-instance sandbox parameters a template unit cannot express.
///
/// Note what is and is not here. MemoryDenyWriteExecute is the headline, but
/// the memory and CPU caps also have to be per-instance, and so does the
/// device allowlist. Everything else stays in the template so there is one
/// place to audit the common hardening.
fn write_dropin(m: &Manifest) -> Result<()> {
    let dir = dropin_dir(&m.id);
    std::fs::create_dir_all(&dir)?;

    let mut s = String::new();
    s.push_str("# Generated by oligarchy-plugind. Do not edit.\n");
    s.push_str(&format!("# plugin={} tier={:?} jit={:?}\n", m.id, m.tier, m.jit));
    s.push_str("[Service]\n");

    // THE LINE THIS WHOLE DESIGN EXISTS TO GET RIGHT.
    s.push_str(&format!(
        "MemoryDenyWriteExecute={}\n",
        if m.wx_enforced() { "yes" } else { "no" }
    ));
    if m.tier == Tier::Wasm {
        s.push_str("# tier=wasm: MDWE is off because THIS process runs Cranelift.\n");
        s.push_str("# The guest is confined by wasmtime, not by seccomp; setting\n");
        s.push_str("# MDWE here would break compilation without hardening anything.\n");
    }
    if m.grants_wx_to_plugin() {
        // systemd's MDWE does not cover memfd_create, so when we turn MDWE
        // off we are also implicitly allowing the dual-mapping path. Make the
        // grant explicit in the unit so `systemctl cat` shows an auditor the
        // truth rather than an absence.
        s.push_str("# jit=self: W^X intentionally disabled for this instance.\n");
        s.push_str("# Confinement for executable memory is delegated to\n");
        s.push_str("# landlock + cgroups + namespaces.\n");
    }

    if let Some(bytes) = m.caps.memory_max {
        s.push_str(&format!("MemoryMax={bytes}\nMemorySwapMax=0\n"));
    }
    if let Some(pct) = m.caps.cpu_quota {
        s.push_str(&format!("CPUQuota={pct}%\n"));
    }

    if m.caps.devices.is_empty() {
        s.push_str("DevicePolicy=closed\n");
    } else {
        s.push_str("DevicePolicy=closed\n");
        for d in &m.caps.devices {
            s.push_str(&format!("DeviceAllow={d} rw\n"));
        }
    }

    if !m.caps.network {
        s.push_str("PrivateNetwork=yes\nRestrictAddressFamilies=AF_UNIX\n");
    }

    let path = dir.join("10-sandbox.conf");
    std::fs::write(&path, s).with_context(|| format!("writing {}", path.display()))?;
    tracing::debug!(plugin = %m.id, path = %path.display(), "wrote sandbox drop-in");
    Ok(())
}

fn remove_dropin(id: &str) -> Result<()> {
    let dir = dropin_dir(id);
    if dir.exists() {
        std::fs::remove_dir_all(&dir)?;
    }
    Ok(())
}

fn daemon_reload() -> Result<()> {
    systemctl(&["daemon-reload"])
}

fn systemctl(args: &[&str]) -> Result<()> {
    let out = Command::new("systemctl")
        .args(args)
        .output()
        .context("running systemctl")?;
    if !out.status.success() {
        bail!(
            "systemctl {:?} failed: {}",
            args,
            String::from_utf8_lossy(&out.stderr).trim()
        );
    }
    Ok(())
}

// --- nix glue -------------------------------------------------------------

/// Resolve `source` to a store path if it is a local path that lands in the
/// store, following symlinks. Returns None for anything that should go through
/// `nix build` instead — including a local path that is *not* in the store,
/// which is a user error `nix build` will report better than we can.
fn local_store_path(source: &str) -> Option<PathBuf> {
    if !source.starts_with('/') {
        return None;
    }
    let real = std::fs::canonicalize(source).ok()?;
    real.starts_with("/nix/store").then_some(real)
}

/// Build/fetch an installable and return its output path. Runs as the calling
/// user; the daemon does the actual substitution, which is why an
/// unprivileged user can do this at all without being trusted.
fn realise(installable: &str) -> Result<PathBuf> {
    let out = Command::new("nix")
        .args([
            "build",
            "--no-link",
            "--print-out-paths",
            // Stop a plugin's own flake.nix from adding substituters or
            // relaxing settings via its nixConfig block. `extra-substituters
            // ""` (the first attempt here) does not do this; accept-flake-config
            // is the setting that actually governs it.
            "--option",
            "accept-flake-config",
            "false",
            installable,
        ])
        .output()
        .context("running nix build")?;
    if !out.status.success() {
        bail!(
            "nix build {installable} failed: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        );
    }
    let path = String::from_utf8(out.stdout)?.trim().to_string();
    anyhow::ensure!(!path.is_empty(), "nix build produced no output path");
    Ok(PathBuf::from(path))
}

/// `nix store verify --sigs-needed 1` against the configured trusted keys.
/// Returns false rather than erroring so the caller can decide based on
/// policy whether an unsigned path is fatal.
fn verify_signature(path: &Path) -> Result<bool> {
    let out = Command::new("nix")
        .args(["store", "verify", "--sigs-needed", "1"])
        .arg(path)
        .output()
        .context("running nix store verify")?;
    if out.status.success() {
        Ok(true)
    } else {
        tracing::warn!(
            path = %path.display(),
            detail = %String::from_utf8_lossy(&out.stderr).trim(),
            "signature verification failed"
        );
        Ok(false)
    }
}

fn now_stamp() -> String {
    // Avoid pulling chrono for one call.
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    format!("@{secs}")
}
