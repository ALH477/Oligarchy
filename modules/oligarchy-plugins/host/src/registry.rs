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
use std::fs::File;
use std::os::unix::fs::OpenOptionsExt;
use std::os::unix::io::AsRawFd;
use std::path::{Path, PathBuf};
use std::process::Command;

use crate::manifest::{Manifest, Tier};
use crate::policy::{Policy, SigVerdict};

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
    /// Held for as long as this Store exists, so a mutation is atomic against
    /// every other plugind in the system.
    ///
    /// Without it two concurrent socket requests interleave, and the worst
    /// interleaving is not a lost update: `enable` writes the drop-in, reloads,
    /// then starts the unit, while a concurrent `disable` deletes the drop-in
    /// in between — so the instance starts under the *template alone*. The
    /// template deliberately omits MemoryDenyWriteExecute (it cannot express
    /// the per-instance exception), and also omits DevicePolicy, MemoryMax and
    /// PrivateNetwork. `DevicePolicy` defaults to `auto`, i.e. unrestricted.
    /// That is the headline invariant of the whole design defeated by two
    /// legitimate requests, so the lock spans the systemctl call too.
    _lock: Option<File>,
}

/// Take the registry lock, creating the lockfile if needed.
///
/// `None` when the caller cannot write the registry directory at all — a
/// reader, which needs no lock. A reader can still see a torn view; the
/// write-rename in `flush` is what makes that impossible.
fn lock_registry(dir: &Path) -> Result<Option<File>> {
    let path = dir.join(".lock");
    let f = match std::fs::OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(false)
        .open(&path)
    {
        Ok(f) => f,
        Err(e) if e.kind() == std::io::ErrorKind::PermissionDenied => return Ok(None),
        Err(e) => return Err(e).with_context(|| format!("opening {}", path.display())),
    };
    // Try without blocking first, so a deadlock is a sentence rather than a
    // silent hang that presents as a client timeout minutes later. Then block:
    // a *queued* install is correct behaviour, a concurrent one is not.
    //
    // SAFETY: plain flock(2) calls on an fd we own.
    if unsafe { libc::flock(f.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
        tracing::info!(
            lock = %path.display(),
            "registry is locked by another plugind; waiting"
        );
        if unsafe { libc::flock(f.as_raw_fd(), libc::LOCK_EX) } != 0 {
            return Err(std::io::Error::last_os_error())
                .with_context(|| format!("locking {}", path.display()));
        }
    }
    Ok(Some(f))
}

impl Store {
    pub fn open(state_dir: &Path) -> Result<Self> {
        let root = state_dir.to_path_buf();
        std::fs::create_dir_all(root.join("registry"))?;
        std::fs::create_dir_all(root.join("state"))?;
        std::fs::create_dir_all(root.join("config"))?;
        std::fs::create_dir_all(root.join("gcroots"))?;

        let lock = lock_registry(&root.join("registry"))?;

        let path = root.join("registry/registry.json");
        let reg = match std::fs::read_to_string(&path) {
            Ok(s) => serde_json::from_str(&s).context("parsing registry.json")?,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Registry::default(),
            Err(e) if e.kind() == std::io::ErrorKind::PermissionDenied => {
                return Err(e).with_context(|| {
                    format!(
                        "cannot read {}. The registry is not world-readable by \
                         design; add this account to custom.plugins.installers \
                         and it will reach the runtime through the control \
                         socket instead.",
                        path.display()
                    )
                })
            }
            Err(e) => return Err(e).context("reading registry.json"),
        };

        // Manifest::validate() runs in Manifest::load(), i.e. only for the TOML
        // inside a store path — so an entry that arrives back through
        // registry.json has never been checked. That matters because the
        // registry is the input to write_dropin(), which root interpolates into
        // a systemd drop-in: an `id` or a device path carrying a newline is a
        // unit-directive injection, and `User=root` in a drop-in beats the
        // template's unprivileged User=. The registry directory is root-owned
        // precisely so this cannot happen, but a generator whose safety rests
        // on one directory mode is a generator waiting for that mode to change.
        let mut reg: Registry = reg;
        reg.entries.retain(|id, e| match e.manifest.validate() {
            Ok(()) => true,
            Err(err) => {
                tracing::error!(
                    plugin = %id,
                    error = %err,
                    "registry entry failed manifest validation; ignoring it. \
                     The registry has been tampered with or written by an older \
                     plugind."
                );
                false
            }
        });
        Ok(Self {
            root,
            reg,
            _lock: lock,
        })
    }

    fn flush(&self) -> Result<()> {
        // Write-rename so a crash mid-write cannot leave a registry that
        // parses as "no plugins are confined".
        let path = self.root.join("registry/registry.json");
        // Unique tmp name: a fixed one is only safe while writers are
        // serialised, and relying on the lock for two separate invariants is
        // how one of them gets lost.
        let tmp = path.with_extension(format!("json.tmp.{}", std::process::id()));
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
    ///
    /// Being local is NOT the same thing as being unverified, and an earlier
    /// version conflated them by demanding `--allow-unsigned` for any bare
    /// store path. A path carrying a signature from a trusted key is exactly
    /// as trustworthy whether it arrived by substitution or was already here —
    /// which is also what makes "an unprivileged user installs a signed
    /// plugin" testable without first standing up a cache.
    pub fn install(&mut self, source: &str, policy: &Policy, allow_unsigned: bool) -> Result<String> {
        let store_path = match local_store_path(source) {
            Some(p) => p,
            None => realise(source, &self.root, policy)?,
        };

        let verified = verify_signature(&store_path, &self.root, policy)?;
        match policy.authorize_signature(verified, allow_unsigned) {
            SigVerdict::Accept => {}
            SigVerdict::PolicyRequiresSignature => bail!(
                "{} has no valid signature from a trusted key, and \
                 custom.plugins.requireSignature is true on this host. \
                 --allow-unsigned cannot override that: sign the path, publish \
                 it through a cache whose key is in \
                 custom.plugins.trustedPublicKeys, or change the option and \
                 rebuild.",
                store_path.display()
            ),
            SigVerdict::NeedsExplicitFlag => bail!(
                "{} has no valid signature from a trusted key. This host's \
                 policy permits unsigned plugins, so pass --allow-unsigned to \
                 say so explicitly.",
                store_path.display()
            ),
        }

        let manifest = Manifest::load(&store_path.join("plugin.toml")).with_context(|| {
            format!("{} does not contain a plugin.toml", store_path.display())
        })?;

        policy
            .authorize(&manifest)
            .with_context(|| format!("host policy refused plugin {}", manifest.id))?;

        // Pin against the garbage collector. Without this, the next `nix
        // store gc` deletes a plugin out from under a running rig.
        add_gc_root(
            &store_path,
            &self.root.join("gcroots").join(&manifest.id),
            &self.root,
            policy,
        )?;

        for kind in ["state", "config"] {
            let parent = self.root.join(kind);
            let dir = parent.join(&manifest.id);
            std::fs::create_dir_all(&dir)
                .with_context(|| format!("creating {}", dir.display()))?;
            inherit_owner(&parent, &dir)?;
        }

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
        // Unrooting is just unlinking: the indirect entry under
        // /nix/var/nix/gcroots/auto is left dangling and Nix prunes it on the
        // next collection.
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

/// Register `link` as a real garbage-collector root for `store_path`.
///
/// A symlink into the store is *not* a GC root, which the first version of
/// this got wrong: Nix protects a path only if the link is registered under
/// /nix/var/nix/gcroots, and `nix-store --add-root` is what performs that
/// registration (as an indirect root pointing back at our link). Without it
/// the comment at the call site was aspirational and `nix store gc` could
/// still delete a plugin out from under a running rig.
fn add_gc_root(
    store_path: &Path,
    link: &Path,
    state_dir: &Path,
    policy: &Policy,
) -> Result<()> {
    if let Some(parent) = link.parent() {
        std::fs::create_dir_all(parent)?;
    }
    // --add-root will not clobber, and re-installing a plugin is normal.
    let _ = std::fs::remove_file(link);
    let out = nix_cmd("nix-store", state_dir, policy)?
        .arg("--realise")
        .arg(store_path)
        .arg("--add-root")
        .arg(link)
        .output()
        .context("running nix-store --add-root")?;
    if !out.status.success() {
        bail!(
            "could not GC-root {}: {}",
            store_path.display(),
            String::from_utf8_lossy(&out.stderr).trim()
        );
    }
    Ok(())
}

/// Give a freshly created per-plugin directory the same owner as the tree it
/// lives in.
///
/// The supervisor runs as root, so a directory it creates is root-owned, and
/// the plugin instance — which does not run as root — could then not write its
/// own state. tmpfiles owns the layout above, so the parent is the authority
/// on who the owner should be. A non-root caller created the directory as
/// itself already and cannot chown anyway, so this is a no-op for them.
fn inherit_owner(parent: &Path, child: &Path) -> Result<()> {
    use std::os::unix::fs::MetadataExt;
    if !nix::unistd::geteuid().is_root() {
        return Ok(());
    }
    let md = std::fs::metadata(parent).with_context(|| format!("stat {}", parent.display()))?;

    // Open with O_NOFOLLOW and chown the descriptor, never the path.
    //
    // `create_dir_all` returns Ok when the target is already a symlink to a
    // directory, and `chown(2)` follows symlinks — so a path-based chown here
    // is an arbitrary-chown primitive for whoever owns this directory's
    // contents. Point `state/<id>` at /etc, wait for a reinstall, and the
    // supervisor hands /etc to the plugin user.
    let dir = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_DIRECTORY)
        .open(child)
        .with_context(|| {
            format!(
                "opening {} without following symlinks — if this is a symlink, \
                 something has tampered with the state directory",
                child.display()
            )
        })?;
    // SAFETY: fchown(2) on an fd we own, obtained with O_NOFOLLOW|O_DIRECTORY,
    // so it cannot have been redirected between the open and here.
    let rc = unsafe { libc::fchown(dir.as_raw_fd(), md.uid(), md.gid()) };
    if rc != 0 {
        return Err(std::io::Error::last_os_error())
            .with_context(|| format!("fchown {}", child.display()));
    }
    Ok(())
}

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
/// A subprocess that talks to Nix. Two things are centralised here on purpose.
///
/// **The CLI it needs.** `nix build` and `nix store verify` are new-CLI
/// subcommands, so on a host that has not opted into `nix-command` every
/// install fails with "experimental Nix feature is disabled" — including the
/// signature check, which is the one thing that must never fail to *run*.
/// Neither feature grants privilege; they gate the interface, not the trust
/// model. Only the `nix` program needs them: `nix-store` is the old CLI, which
/// is why passing the program name here rather than hardcoding it matters.
///
/// **The privilege it does not need.** The supervisor runs as root because it
/// has to write `/run/systemd/system`. Nothing about resolving or verifying a
/// store path does, and `source` is caller-supplied — a member of the install
/// group can name a flake ref, and evaluating an attacker-chosen flake as root
/// is root code execution however narrow the request format is. So drop to the
/// account that owns the state directory. The nix-daemon does the actual
/// building either way, so nothing is lost.
fn nix_cmd(program: &str, state_dir: &Path, policy: &Policy) -> Result<Command> {
    use std::os::unix::fs::MetadataExt;
    use std::os::unix::process::CommandExt;

    let mut c = Command::new(program);
    if program == "nix" {
        c.args(["--extra-experimental-features", "nix-command flakes"]);
    }

    // Pin the accepted key set to the plugin keys — and pin it through
    // NIX_CONFIG rather than --option, because a restricted setting passed on
    // the command line by an untrusted client is ignored with a warning.
    // NIX_CONFIG *replaces* the list and outranks every config file, which does
    // two jobs at once: signature checking stops accepting cache.nixos.org and
    // the flakehub keys that nix.settings legitimately carries, and a nix.conf
    // planted under an attacker-writable HOME cannot widen it back.
    c.env(
        "NIX_CONFIG",
        format!(
            "trusted-public-keys = {}\n",
            policy.trusted_public_keys.join(" ")
        ),
    );
    // Belt and braces: neither of these may reach the child from anywhere.
    c.env_remove("NIX_USER_CONF_FILES");
    c.env("XDG_CONFIG_HOME", "/var/empty");
    // Nix wants a writable HOME for its evaluation cache; the state directory
    // is the one place the dropped-to account is guaranteed to own. Safe now
    // that the config path above no longer depends on HOME.
    c.env("HOME", state_dir);

    if nix::unistd::geteuid().is_root() {
        // Fail closed. If we cannot learn who to become we do NOT continue as
        // root: `source` is caller-supplied and may be a flake ref.
        let md = std::fs::metadata(state_dir)
            .with_context(|| format!("stat {} to drop privileges", state_dir.display()))?;
        let (uid, gid) = (md.uid(), md.gid());

        // The whole drop happens here rather than through Command::uid/gid,
        // because ordering matters and std's is wrong for us: it applies uid and
        // gid *before* running pre_exec closures, so a setgroups() in a closure
        // is already unprivileged and fails with EPERM. Supplementary groups
        // must go first, then gid, then uid last — after setuid there is no
        // privilege left to drop anything with.
        //
        // SAFETY: pre_exec runs in the forked child between fork and exec, where
        // only async-signal-safe calls are permitted. All three are.
        unsafe {
            c.pre_exec(move || {
                if libc::setgroups(0, std::ptr::null()) != 0 {
                    return Err(std::io::Error::last_os_error());
                }
                if libc::setgid(gid) != 0 {
                    return Err(std::io::Error::last_os_error());
                }
                if libc::setuid(uid) != 0 {
                    return Err(std::io::Error::last_os_error());
                }
                Ok(())
            });
        }
    }
    Ok(c)
}

fn realise(installable: &str, state_dir: &Path, policy: &Policy) -> Result<PathBuf> {
    let out = nix_cmd("nix", state_dir, policy)?
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
fn verify_signature(path: &Path, state_dir: &Path, policy: &Policy) -> Result<bool> {
    // `nix store verify` alone is NOT sufficient, and this is the sharpest edge
    // in the imperative path.
    //
    // Nix short-circuits verification for content-addressed paths: upstream
    // does `if (info->isContentAddressed(store)) validSigs = maxSigs;` before
    // consulting a single key. `--sigs-needed 1` does not change that — it only
    // defeats the separate `ultimate` shortcut for locally-built paths. So any
    // account that can run `nix store add-path`, which needs no privilege at
    // all, can produce a path with `signatures: []` that `nix store verify`
    // reports as fine. That made "an unprivileged user cannot install an
    // unsigned plugin" false, and a test whose negative fixture happened to be
    // input-addressed did not notice.
    //
    // So require BOTH:
    //   1. a signature is actually present, naming a key policy pinned; and
    //   2. `nix store verify` accepts it, with the key set pinned.
    // (1) alone would accept a forged signature bearing a trusted key's name;
    // (2) alone accepts any content-addressed path. Together they are sound.
    if !has_pinned_signature(path, state_dir, policy)? {
        return Ok(false);
    }
    let out = nix_cmd("nix", state_dir, policy)?
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

/// Is there a signature on `path` whose key name policy pinned?
///
/// Name-matching only. The cryptography is `nix store verify`'s job; this
/// exists solely to establish that a signature is *there*, which the
/// content-addressed short-circuit would otherwise let a caller skip.
fn has_pinned_signature(path: &Path, state_dir: &Path, policy: &Policy) -> Result<bool> {
    // A pinned key name is the part before the first ':' of a key spec.
    let pinned: Vec<&str> = policy
        .trusted_public_keys
        .iter()
        .filter_map(|k| k.split(':').next())
        .filter(|n| !n.is_empty())
        .collect();
    if pinned.is_empty() {
        // Nothing is pinned, so nothing can be verified. Answering here rather
        // than letting `nix store verify` answer is what stops a host with no
        // keys being talked into accepting a content-addressed path.
        return Ok(false);
    }

    // No --json-format: it does not exist before Nix 2.32, and omitting it only
    // costs a deprecation warning on stderr (which we do not read) on versions
    // that have it. The shape it selects is exactly why the walk below is
    // structural rather than typed — see collect_signatures.
    let out = nix_cmd("nix", state_dir, policy)?
        .args(["path-info", "--json"])
        .arg(path)
        .output()
        .context("running nix path-info")?;
    if !out.status.success() {
        bail!(
            "nix path-info {} failed: {}",
            path.display(),
            String::from_utf8_lossy(&out.stderr).trim()
        );
    }

    let doc: serde_json::Value =
        serde_json::from_slice(&out.stdout).context("parsing nix path-info output")?;
    let mut sigs = Vec::new();
    collect_signatures(&doc, &mut sigs);
    Ok(sigs
        .iter()
        .filter_map(|sig| sig.split(':').next())
        .any(|name| pinned.contains(&name)))
}

/// Gather every string under a `"signatures"` array, wherever it sits.
///
/// Deliberately structural rather than a typed struct. `nix path-info --json`
/// has two wire formats — v1 keys the object by store path, v2 wraps it — and
/// which one you get depends on the Nix version and on a flag that does not
/// exist on older ones. A typed deserialization would silently produce an empty
/// signature list on the shape it did not expect, and an empty list here means
/// "refuse", so the failure would be safe but the diagnosis baffling. Walking
/// for the key is version-proof and, since we then match against a pinned name
/// and hand the path to `nix store verify` anyway, no less sound.
fn collect_signatures(v: &serde_json::Value, out: &mut Vec<String>) {
    match v {
        serde_json::Value::Object(map) => {
            for (k, val) in map {
                if k == "signatures" {
                    if let Some(arr) = val.as_array() {
                        out.extend(arr.iter().filter_map(|s| s.as_str().map(str::to_owned)));
                    }
                } else {
                    collect_signatures(val, out);
                }
            }
        }
        serde_json::Value::Array(items) => items.iter().for_each(|i| collect_signatures(i, out)),
        _ => {}
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn signature_walk_handles_both_path_info_shapes() {
        // v1: object keyed by store path.
        let v1 = serde_json::json!({
            "/nix/store/x-p": { "signatures": ["k1:AAA", "k2:BBB"], "ca": null }
        });
        // v2: wrapped, and with a null entry for an unknown path.
        let v2 = serde_json::json!({
            "version": 2,
            "paths": { "/nix/store/x-p": { "signatures": ["k1:AAA"] },
                       "/nix/store/y-q": null }
        });
        for (doc, want) in [(v1, 2), (v2, 1)] {
            let mut out = Vec::new();
            collect_signatures(&doc, &mut out);
            assert_eq!(out.len(), want, "{doc}");
            assert!(out.iter().all(|s| s.starts_with("k")), "{out:?}");
        }
        // The case that must yield nothing: content-addressed, no signatures.
        let ca = serde_json::json!({
            "/nix/store/z-r": { "signatures": [], "ca": "fixed:r:sha256:deadbeef" }
        });
        let mut out = Vec::new();
        collect_signatures(&ca, &mut out);
        assert!(out.is_empty());
    }



    #[test]
    fn only_store_paths_are_local_sources() {
        assert!(local_store_path("oligarchy-fx#tape").is_none());
        assert!(local_store_path("github:ALH477/fx#gain").is_none());
        // Relative paths are not sources either; `nix build` can say why.
        assert!(local_store_path("./result").is_none());
        // A real store path resolves; /nix/store itself is always present.
        assert_eq!(
            local_store_path("/nix/store"),
            Some(PathBuf::from("/nix/store"))
        );
        // Outside the store, even if it exists.
        assert!(local_store_path("/etc").is_none());
    }
}
