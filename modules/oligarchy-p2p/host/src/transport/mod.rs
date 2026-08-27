//! Where bytes come from when they do not come from us or from upstream.
//!
//! The trait exists so the BitTorrent work in stage 4 is a file, not a
//! refactor. It is deliberately small, and deliberately **not** async: a
//! transport implementation is free to be a blocking HTTP client, a torrent
//! session with its own runtime, or a subprocess, and forcing all of those
//! through one async signature would be an abstraction that serves the
//! abstraction.
//!
//! Two rules every implementation inherits, and neither is negotiable:
//!
//! 1. **A transport is a source of bytes and nothing else.** It never decides
//!    what is trustworthy. `fetch` is handed a `Verifier` built from the
//!    *signed* `NarHash`, and a `Slot` whose contents only become a named cache
//!    entry if that verifier passes. A lying peer costs a retry.
//! 2. **A transport must be bounded in time.** `discover` and `fetch` take a
//!    deadline because Nix is waiting on the other end of this, and a peer that
//!    accepts a connection and then says nothing is indistinguishable from a
//!    slow one until the clock runs out.

use crate::cache::Slot;
use crate::nixhash::Sha256Digest;
use anyhow::Result;
use std::path::PathBuf;
use std::time::Duration;

/// What a transport is asked to find. Everything here is derived from a narinfo
/// whose signature Nix will check — the transport is not trusted to produce it.
#[derive(Debug, Clone)]
pub struct ArtifactRef {
    /// Store path hash part, e.g. `lcxc2z1h…`. How a narinfo is addressed.
    pub hash_part: String,
    /// The signed NAR hash. The artifact's identity, and the thing verified.
    pub nar_hash: Sha256Digest,
    /// The signed NAR length.
    pub nar_size: u64,
}

impl ArtifactRef {
    pub fn from_narinfo(ni: &crate::narinfo::NarInfo) -> Result<Self> {
        Ok(Self {
            hash_part: ni.hash_part().to_string(),
            nar_hash: ni.nar_hash(),
            nar_size: ni.nar_size()?,
        })
    }
}

/// A place an artifact might be. Opaque to everything but the transport that
/// produced it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PeerRef {
    pub transport: &'static str,
    pub address: String,
}

#[derive(Debug, Clone, Default)]
pub struct TransportStatus {
    pub name: String,
    pub peers_known: usize,
    pub peers_reachable: usize,
    pub detail: String,
}

pub trait ArtifactTransport: Send + Sync {
    fn name(&self) -> &'static str;

    /// Who might have this. Bounded by `deadline`; an empty result is normal
    /// and must not be an error.
    fn discover(&self, art: &ArtifactRef, deadline: Duration) -> Vec<PeerRef>;

    /// Fetch into `slot`, verifying against `art.nar_hash` as the bytes arrive,
    /// and publish it only if that passes. Returns the committed cache path.
    ///
    /// Unlike the upstream path, this verifies **in full before anything is
    /// served** — a peer is on a LAN, so the latency that makes buffering
    /// unacceptable for a WAN download does not apply, and peers are the
    /// untrusted source that most deserves the stronger guarantee.
    fn fetch(
        &self,
        art: &ArtifactRef,
        peers: &[PeerRef],
        slot: Slot,
        deadline: Duration,
    ) -> Result<PathBuf>;

    // NOTE: no `provide`/`remove` yet. For the LAN transport being reachable
    // IS the announcement, so both would be no-ops, and a trait method whose
    // only implementation does nothing teaches the next reader the wrong thing
    // about what a transport owes. They arrive in stage 4, where announcing to
    // a swarm and dropping a torrent on eviction are real operations with real
    // failure modes to design against.

    /// A narinfo from a peer, for a path we have never seen.
    ///
    /// Without this the peer transport is useless offline: a NAR cannot be
    /// verified without the signed `NarHash`, that lives in the narinfo, and
    /// resolving a narinfo went to the network. Returning upstream's narinfo
    /// **verbatim** keeps the signature intact, and the caller re-checks that
    /// the store path it names is the one that was asked for.
    fn narinfo(&self, _hash_part: &str, _deadline: Duration) -> Option<String> {
        None
    }

    fn status(&self) -> TransportStatus;
}

/// The transport that does nothing, and the default.
///
/// Not a placeholder: it is what makes "P2P is an enhancement, never a
/// requirement" a thing the type system says rather than a thing the docs
/// claim. With this selected the daemon behaves exactly as it did at stage 2.
pub struct NullTransport;

impl ArtifactTransport for NullTransport {
    fn name(&self) -> &'static str {
        "none"
    }
    fn discover(&self, _: &ArtifactRef, _: Duration) -> Vec<PeerRef> {
        Vec::new()
    }
    fn fetch(&self, _: &ArtifactRef, _: &[PeerRef], _: Slot, _: Duration) -> Result<PathBuf> {
        anyhow::bail!("no transport configured")
    }

    fn status(&self) -> TransportStatus {
        TransportStatus {
            name: "none".into(),
            detail: "no peer transport configured".into(),
            ..Default::default()
        }
    }
}

pub mod lan;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_null_transport_never_finds_anything() {
        // The guarantee that "P2P is an enhancement" is structural: with no
        // transport the resolver simply falls through, and nothing else in the
        // daemon has to know about it.
        let t = NullTransport;
        assert!(t.discover(&art(), Duration::from_secs(1)).is_empty());
        assert_eq!(t.narinfo("abc", Duration::from_secs(1)), None);
        assert_eq!(t.status().peers_known, 0);
    }

    fn art() -> ArtifactRef {
        ArtifactRef {
            hash_part: "lcxc2z1h2g8wq8dxfpizy1di85kyxnqx".into(),
            nar_hash: Sha256Digest([0u8; 32]),
            nar_size: 1,
        }
    }
}
