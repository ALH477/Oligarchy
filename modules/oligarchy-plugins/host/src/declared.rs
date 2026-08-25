//! Declaratively-pinned plugins: the half of the seam that lives in the flake.
//!
//! This was the missing link, and tier 2 is what made it unavoidable. The
//! module generated a drop-in, a `wants=` entry and a manifest file for every
//! `custom.plugins.declaredPlugins` entry — but `plugind run <id>` resolved ids
//! against the *registry*, which only an imperative install ever writes. So a
//! declared plugin's unit started, failed with "no such plugin", and the
//! declarative path had never worked for any tier. Tier 2 cannot paper over it
//! the way the others could, because a microVM guest needs a closure and
//! building one is a rebuild: declaredPlugins is the *only* way in.
//!
//! The index is read-only, in /etc, and part of the system closure — so it rolls
//! back with everything else, which is exactly the property the declarative half
//! is supposed to have. Nothing here can write it.

use anyhow::{bail, Context, Result};
use serde::Deserialize;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use crate::manifest::{Jit, Manifest, Tier};

/// What the module decided about a declared plugin.
///
/// Deliberately not the whole manifest. The manifest lives in the artifact,
/// where it was written by whoever built the plugin; these are the fields the
/// *module* is authoritative about, because it generated a systemd drop-in from
/// them before the artifact was ever opened.
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Declared {
    pub store_path: PathBuf,
    /// The tier and jit the drop-in was generated for. Cross-checked against
    /// the artifact's own manifest at load time — see `resolve`.
    pub tier: Tier,
    pub jit: Jit,
    pub autostart: bool,
    /// The guest's vsock context id, for tier 2. Assigned by the module, which
    /// is the only thing in a position to keep them unique.
    ///
    /// The host needs it because how you reach a guest depends on the
    /// hypervisor: firecracker and cloud-hypervisor implement vsock in
    /// userspace behind a unix socket, while qemu uses the kernel's vhost-vsock
    /// and there is no socket file at all — you dial the cid. See
    /// MicrovmPlugin::boot.
    #[serde(default)]
    pub vsock_cid: Option<u32>,
}

pub type Index = BTreeMap<String, Declared>;

/// Load the index. A missing file is not an error: a host may have no declared
/// plugins at all, which is the common case.
pub fn load(path: &Path) -> Result<Index> {
    match std::fs::read_to_string(path) {
        Ok(s) => serde_json::from_str(&s)
            .with_context(|| format!("parsing {}", path.display())),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Index::new()),
        Err(e) => Err(e).with_context(|| format!("reading {}", path.display())),
    }
}

/// Resolve a declared id to a validated manifest and its store path.
///
/// The cross-check is the point of this function. The per-instance sandbox
/// drop-in — including the `MemoryDenyWriteExecute` line — was generated at
/// build time from the module's `tier` and `jit`, while the runtime loads the
/// artifact's own `plugin.toml`. If those disagree, the plugin runs under a
/// sandbox computed for a different plugin: declare `jit = "none"`, ship an
/// artifact saying `jit = "self"`, and the drop-in says MDWE=yes while the
/// manifest asks for W^X to be omitted. Refusing is the only safe answer, and
/// it has to happen here because no build-time check can read a derivation's
/// contents without an import-from-derivation.
pub fn resolve(index: &Index, id: &str) -> Result<Option<(Manifest, PathBuf, Option<u32>)>> {
    let Some(d) = index.get(id) else {
        return Ok(None);
    };

    let manifest = Manifest::load(&d.store_path.join("plugin.toml")).with_context(|| {
        format!(
            "declared plugin {id} points at {}, which has no usable plugin.toml",
            d.store_path.display()
        )
    })?;

    if manifest.id != id {
        bail!(
            "declared plugin {id} points at an artifact whose manifest says {}",
            manifest.id
        );
    }
    if manifest.tier != d.tier || manifest.jit != d.jit {
        bail!(
            "declared plugin {id} disagrees with its artifact: the module says \
             tier={:?} jit={:?} and generated this instance's sandbox drop-in \
             from that, but {} says tier={:?} jit={:?}. Fix \
             custom.plugins.declaredPlugins.{id} to match the artifact and \
             rebuild — running it would confine it as something it is not.",
            d.tier,
            d.jit,
            d.store_path.display(),
            manifest.tier,
            manifest.jit
        );
    }

    Ok(Some((manifest, d.store_path.clone(), d.vsock_cid)))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn index(tier: &str, jit: &str) -> Index {
        serde_json::from_str(&format!(
            r#"{{"p":{{"store_path":"/nix/store/x-p","tier":"{tier}","jit":"{jit}","autostart":true,"vsock_cid":7}}}}"#
        ))
        .unwrap()
    }

    #[test]
    fn tier_and_jit_deserialize_as_the_manifest_spells_them() {
        // The module writes this file, so the two spellings have to agree. If
        // serde renames ever diverge, this fails here rather than at boot on a
        // machine with a declared plugin.
        let i = index("microvm", "self");
        let d = i.get("p").unwrap();
        assert_eq!(d.tier, Tier::Microvm);
        assert_eq!(d.jit, Jit::SelfJit);
        assert!(d.autostart);
        assert_eq!(d.vsock_cid, Some(7));
    }

    #[test]
    fn an_unknown_id_is_not_an_error() {
        assert!(resolve(&index("wasm", "host"), "absent").unwrap().is_none());
    }

    #[test]
    fn a_missing_index_is_not_an_error() {
        assert!(load(Path::new("/nonexistent/declared.json"))
            .unwrap()
            .is_empty());
    }
}
