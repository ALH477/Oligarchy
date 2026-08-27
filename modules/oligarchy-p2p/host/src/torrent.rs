//! Canonical torrent construction.
//!
//! **Everything in this module is wire contract.** Two hosts that independently
//! build a torrent for the same NAR must arrive at the same infohash, or they
//! join different swarms and the transport silently degrades to a swarm of one
//! per peer — with no error anywhere.
//!
//! Stage 0 established, by reading `librqbit`'s `create_torrent_file.rs` and
//! then demonstrating it, that the infohash is deterministic: `compute_info_hash`
//! bencodes only the `info` dict, and `create_torrent` hardcodes
//! `created_by: None` / `creation_date: None`, so no timestamp or host identity
//! reaches it. Three inputs remain, and all three are pinned here:
//!
//! * **`name`** — `<narhash-nix32>.nar`. Passed explicitly. Left to default it
//!   would be the on-disk `basename`, and a peer that stored the artifact under
//!   a different filename would compute a different infohash. Demonstrated:
//!   with the name pinned, a copy at an unrelated path produced the identical
//!   infohash.
//! * **`piece_length`** — from the table below. `librqbit`'s default is a flat
//!   2 MiB carrying `// TODO: make this smarter or smth`; relying on it would
//!   couple every Oligarchy infohash to an upstream TODO that can change in any
//!   release.
//! * **single-file mode** — the NAR is one file, so `length: Some(n)`,
//!   `files: None`.
//!
//! Changing any of them forks the swarm from every host still running the old
//! rule. That is not a thing to do casually, and never without a version bump
//! on the peer protocol.

use crate::nixhash::Sha256Digest;
use anyhow::{Context, Result};
use std::path::Path;

/// Piece length for a NAR of this size. A pure function of signed data.
///
/// The shape is conventional (larger pieces for larger payloads, to keep the
/// piece-hash list from dominating the metadata) and the exact thresholds
/// matter far less than that they never change. Sizes are powers of two
/// because BitTorrent requires it.
pub fn piece_length(nar_size: u64) -> u32 {
    const KIB: u64 = 1024;
    const MIB: u64 = 1024 * KIB;
    match nar_size {
        0..=67_108_863 => (256 * KIB) as u32,           // < 64 MiB
        67_108_864..=1_073_741_823 => (1 * MIB) as u32, // < 1 GiB
        _ => (4 * MIB) as u32,
    }
}

/// The name every host must give this artifact inside the info dict.
pub fn canonical_name(nar_hash: &Sha256Digest) -> String {
    format!("{}.nar", nar_hash.to_nix32())
}

/// Build the canonical `.torrent` for a NAR we hold.
///
/// Built on demand rather than stored: it is a pure function of the file plus
/// the two pinned parameters, so persisting it would only create a second thing
/// that can go stale relative to the first.
pub async fn build(nar_path: &Path, nar_hash: &Sha256Digest, nar_size: u64) -> Result<Vec<u8>> {
    let res = librqbit::create_torrent(
        nar_path,
        librqbit::CreateTorrentOptions {
            name: Some(&canonical_name(nar_hash)),
            piece_length: Some(piece_length(nar_size)),
        },
    )
    .await
    .with_context(|| format!("building a torrent for {}", nar_path.display()))?;
    Ok(res.as_bytes().context("serialising the torrent")?.to_vec())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn piece_length_is_a_pure_function_of_size() {
        // Same size in, same answer out, always — this is the property that
        // makes two independently-built torrents agree.
        for n in [0u64, 1, 1 << 20, 1 << 26, 1 << 30, 1 << 40] {
            assert_eq!(piece_length(n), piece_length(n));
        }
    }

    #[test]
    fn piece_length_steps_where_documented() {
        assert_eq!(piece_length(0), 256 * 1024);
        assert_eq!(piece_length(64 * 1024 * 1024 - 1), 256 * 1024);
        assert_eq!(piece_length(64 * 1024 * 1024), 1024 * 1024);
        assert_eq!(piece_length(1024 * 1024 * 1024 - 1), 1024 * 1024);
        assert_eq!(piece_length(1024 * 1024 * 1024), 4 * 1024 * 1024);
        // The largest NAR measured in this repo's own closure was 3.2 GiB
        // (android-studio); make sure that lands somewhere sane.
        assert_eq!(piece_length(3_400_000_000), 4 * 1024 * 1024);
    }

    #[test]
    fn piece_lengths_are_powers_of_two() {
        // BitTorrent requires it, and a non-power-of-two would be accepted by
        // our own code and rejected by other clients.
        for n in [0u64, 1 << 26, 1 << 30, 1 << 40] {
            let p = piece_length(n);
            assert!(p.is_power_of_two(), "{p} is not a power of two");
        }
    }

    #[test]
    fn the_name_is_derived_from_signed_data_only() {
        // NOT the on-disk filename. If this ever becomes basename-derived, two
        // peers holding the same NAR at different paths compute different
        // infohashes and each ends up alone in its own swarm — silently.
        let d = Sha256Digest([7u8; 32]);
        assert_eq!(canonical_name(&d), format!("{}.nar", d.to_nix32()));
        assert!(canonical_name(&d).ends_with(".nar"));
        assert_eq!(canonical_name(&d).len(), 52 + 4);
    }
}
