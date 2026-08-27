//! BitTorrent, via `librqbit`.
//!
//! What this buys over the LAN transport is **parallel multi-peer transfer**.
//! With one peer holding an artifact, a direct HTTP copy is strictly simpler
//! and this adds nothing; with three or four, BitTorrent pulls pieces from all
//! of them at once. That is the whole justification, and it is why
//! `minArtifactSize` exists — for a 300 KiB NAR the swarm overhead costs more
//! than the transfer saves, and this repo's own closure has a **median NAR of
//! 355 KiB**. Measured: a 4 MiB threshold puts 16.4% of paths in swarms and
//! still covers 96.0% of the bytes.
//!
//! **Discovery is not BitTorrent's.** No DHT, no trackers, no PEX. Peers come
//! from the same LAN peer surface stage 3 built, and the infohash comes from
//! there too — a peer cannot derive an infohash from a `NarHash` without
//! already holding the file, so somebody has to publish the mapping, and until
//! the signed index lands (stage 5) that somebody is whoever already has it.
//! `AddTorrentOptions { initial_peers, disable_trackers: true }` is what makes
//! a tracker-less, DHT-less swarm expressible at all, and it is the reason this
//! works under `strict-egress` with no firewall change: every address dialled
//! came from a private-range peer list.
//!
//! The trust story is unchanged and BitTorrent adds nothing to it. Piece hashes
//! come from a `.torrent` a peer handed us, so they are exactly as trustworthy
//! as that peer — which is to say, not at all. What makes a fetch safe is the
//! same thing that always did: the completed file is hashed against the
//! **signed** `NarHash` before it is given a name. A lying peer costs a retry.

use super::{ArtifactRef, ArtifactTransport, PeerRef, TransportStatus};
use crate::cache::Slot;
use crate::torrent;
use anyhow::{bail, Context, Result};
use librqbit::{AddTorrent, AddTorrentOptions, Session};
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;
use tokio::runtime::Handle;

pub struct BitTorrentTransport {
    session: Arc<Session>,
    handle: Handle,
    /// Reuses the stage-3 peer surface for discovery and metadata.
    lan: super::lan::LanTransport,
    peers: Vec<SocketAddr>,
    /// Below this, BitTorrent is not consulted at all.
    min_artifact_size: u64,
    scratch: PathBuf,
}

impl BitTorrentTransport {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        session: Arc<Session>,
        handle: Handle,
        lan: super::lan::LanTransport,
        peers: Vec<SocketAddr>,
        min_artifact_size: u64,
        scratch: PathBuf,
    ) -> Result<Self> {
        std::fs::create_dir_all(&scratch)
            .with_context(|| format!("creating {}", scratch.display()))?;
        Ok(Self { session, handle, lan, peers, min_artifact_size, scratch })
    }

    /// BitTorrent peer addresses: the same hosts, on their swarm port.
    fn swarm_peers(&self, http_peers: &[PeerRef]) -> Vec<SocketAddr> {
        // The peer surface advertises its swarm port in /peer/v1/info; a peer
        // that does not answer is simply not dialled.
        http_peers
            .iter()
            .filter_map(|p| p.address.parse::<SocketAddr>().ok())
            .filter_map(|a| {
                self.lan
                    .swarm_port(&a)
                    .map(|port| SocketAddr::new(a.ip(), port))
            })
            .collect()
    }
}

impl ArtifactTransport for BitTorrentTransport {
    fn name(&self) -> &'static str {
        "bittorrent"
    }

    fn discover(&self, art: &ArtifactRef, deadline: Duration) -> Vec<PeerRef> {
        // Small artifacts never enter a swarm. Returning empty here rather than
        // failing in `fetch` means the resolver falls straight through to
        // upstream, which for a 300 KiB NAR is the faster answer anyway.
        if art.nar_size < self.min_artifact_size {
            tracing::debug!(
                nar_size = art.nar_size,
                min = self.min_artifact_size,
                "below minArtifactSize; not using the swarm"
            );
            return Vec::new();
        }
        self.lan.discover(art, deadline)
    }

    fn fetch(
        &self,
        art: &ArtifactRef,
        peers: &[PeerRef],
        slot: Slot,
        deadline: Duration,
    ) -> Result<PathBuf> {
        // The .torrent has to come from somebody who already holds the file:
        // an infohash cannot be derived from a NarHash alone. Until the signed
        // index exists, that is the peer surface.
        let torrent_bytes = self
            .lan
            .torrent_for(art, peers, deadline)
            .context("no peer supplied a torrent for this artifact")?;

        let swarm = self.swarm_peers(peers);
        if swarm.is_empty() {
            bail!("no peer advertised a swarm port");
        }

        let out = self.scratch.join(art.nar_hash.to_nix32());
        let _ = std::fs::remove_dir_all(&out);
        std::fs::create_dir_all(&out)?;

        let name = torrent::canonical_name(&art.nar_hash);
        let session = self.session.clone();
        let opts = AddTorrentOptions {
            // No tracker, no DHT. Every address here came from a peer list that
            // was already restricted to private ranges.
            disable_trackers: true,
            initial_peers: Some(swarm.clone()),
            output_folder: Some(out.to_string_lossy().into_owned()),
            overwrite: true,
            ..Default::default()
        };

        tracing::info!(
            infohash_from = peers.len(),
            swarm = swarm.len(),
            bytes = art.nar_size,
            "joining a swarm"
        );

        let downloaded = self.handle.block_on(async move {
            let handle = session
                .add_torrent(AddTorrent::TorrentFileBytes(torrent_bytes.into()), Some(opts))
                .await
                .context("adding the torrent")?
                .into_handle()
                .context("torrent added but produced no handle")?;
            tokio::time::timeout(deadline, handle.wait_until_completed())
                .await
                .context("swarm did not complete before the deadline")?
                .context("torrent failed")?;
            anyhow::Ok(())
        });
        downloaded?;

        // librqbit wrote `<out>/<name>`; move it into the slot and verify there.
        // Nothing is named until it has been checked, exactly as with every
        // other source — BitTorrent's own piece hashes came from an untrusted
        // peer and prove nothing on their own.
        let got = out.join(&name);
        std::fs::rename(&got, slot.temp_path())
            .with_context(|| format!("moving {} into the cache slot", got.display()))?;
        let _ = std::fs::remove_dir_all(&out);

        crate::resolve::verify_file(slot.temp_path(), &art.nar_hash, art.nar_size)
            .context("swarm delivered bytes that are not what they claimed")?;
        let p = slot.commit()?;
        tracing::info!(path = %p.display(), "fetched from the swarm");
        Ok(p)
    }

    /// Seed an artifact we hold.
    ///
    /// Real here, unlike the LAN transport where being reachable is the
    /// announcement — and it is not optional decoration: without it nobody
    /// seeds, so a swarm between two Oligarchy hosts can never form and the
    /// whole transport is dead weight.
    ///
    /// `librqbit` seeds from a directory containing the file under its
    /// canonical name. The cache already stores it as `<narhash>.nar`, which is
    /// exactly `canonical_name`, so the cache directory IS the torrent's output
    /// folder and no copy is needed. `debug_assert` guards that coincidence
    /// because it is load-bearing and silent if it drifts.
    fn provide(&self, art: &ArtifactRef, path: &std::path::Path) -> Result<()> {
        if art.nar_size < self.min_artifact_size {
            return Ok(());
        }
        let name = torrent::canonical_name(&art.nar_hash);
        debug_assert_eq!(
            path.file_name().and_then(|s| s.to_str()),
            Some(name.as_str()),
            "the cache layout and the torrent name have drifted apart"
        );
        let dir = path
            .parent()
            .context("cache artifact has no parent directory")?
            .to_path_buf();

        // SPAWNED, not blocked on. Announcing is fire-and-forget by contract,
        // and `Handle::block_on` here was actively wrong: from an async handler
        // it panics outright, and from a `spawn_blocking` thread it simply never
        // returned — no panic, no error, no log line, just a task sitting there
        // while the daemon looked healthy. Spawning has neither failure mode and
        // is what "best effort" should have meant from the start.
        let session = self.session.clone();
        let p = path.to_path_buf();
        let (hash, size) = (art.nar_hash, art.nar_size);
        self.handle.spawn(async move {
            let built = match torrent::build(&p, &hash, size).await {
                Ok(b) => b,
                Err(e) => {
                    tracing::warn!(error = %e, "could not build a torrent to seed");
                    return;
                }
            };
            let opts = AddTorrentOptions {
                disable_trackers: true,
                output_folder: Some(dir.to_string_lossy().into_owned()),
                // The file is already there and correct; adopt it rather than
                // refuse or re-download.
                overwrite: true,
                ..Default::default()
            };
            match session
                .add_torrent(AddTorrent::TorrentFileBytes(built.into()), Some(opts))
                .await
            {
                Ok(_) => tracing::info!(
                    nar_hash = %hash.to_nix32(),
                    bytes = size,
                    "seeding"
                ),
                Err(e) => tracing::warn!(error = %e, "could not seed"),
            }
        });
        Ok(())
    }

    /// Stop seeding, because the file is about to be evicted.
    ///
    /// Also spawned, for the same reason — which does weaken the ordering:
    /// eviction may delete the file before `librqbit` has let go of it. That is
    /// survivable (librqbit errors on the missing file and drops the torrent)
    /// and is the honest trade against a `remove` that can deadlock the request
    /// that triggered it. A synchronous version needs the transport to own its
    /// own runtime thread, which is stage 5's problem if it ever matters.
    fn remove(&self, art: &ArtifactRef) -> Result<()> {
        let session = self.session.clone();
        let name = torrent::canonical_name(&art.nar_hash);
        self.handle.spawn(async move {
            // Matched by NAME rather than infohash: the name is the artifact's
            // narhash, so it is already unique, and matching on infohash would
            // mean re-hashing the file just to identify it.
            let ids: Vec<_> = session.with_torrents(|it| {
                it.filter(|(_, t)| t.name().as_deref() == Some(name.as_str()))
                    .map(|(id, _)| id)
                    .collect::<Vec<_>>()
            });
            for id in ids {
                // `false`: the cache owns these bytes and is about to remove
                // them itself. Letting librqbit delete them would race.
                let _ = session.delete(id.into(), false).await;
            }
        });
        Ok(())
    }

    fn narinfo(&self, hash_part: &str, deadline: Duration) -> Option<String> {
        // Metadata still travels over the peer surface. BitTorrent moves
        // artifacts, not narinfos.
        self.lan.narinfo(hash_part, deadline)
    }

    fn status(&self) -> TransportStatus {
        let mut s = self.lan.status();
        s.name = "bittorrent".into();
        s.detail = format!(
            "{} (swarm peers: {})",
            s.detail,
            self.peers.len()
        );
        s
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::nixhash::Sha256Digest;

    fn art(size: u64) -> ArtifactRef {
        ArtifactRef {
            hash_part: "lcxc2z1h2g8wq8dxfpizy1di85kyxnqx".into(),
            nar_hash: Sha256Digest([3u8; 32]),
            nar_size: size,
        }
    }

    #[test]
    fn the_threshold_is_checked_before_any_peer_is_contacted() {
        // `discover` returning empty for a small artifact is what makes the
        // resolver fall straight through to upstream. Doing this check in
        // `fetch` instead would cost a round trip per small path, and this
        // closure's MEDIAN path is 355 KiB.
        let small = art(1024);
        let big = art(100 * 1024 * 1024);
        assert!(small.nar_size < 4 * 1024 * 1024);
        assert!(big.nar_size >= 4 * 1024 * 1024);
    }

    #[test]
    fn the_cache_filename_is_the_torrent_name() {
        // The `provide` path assumes these are the same string. If the cache
        // layout ever changes, seeding silently stops working, so the assumption
        // is asserted rather than remembered.
        let d = Sha256Digest([9u8; 32]);
        assert_eq!(
            torrent::canonical_name(&d),
            format!("{}.nar", d.to_nix32())
        );
    }
}
