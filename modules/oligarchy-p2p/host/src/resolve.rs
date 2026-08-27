//! Where a NAR comes from, in order, and how it gets verified on the way.
//!
//! ```text
//!   1. local cache     verified in full, then served   ← no bytes before proof
//!   2. local Nix store  verified in full, then served  ← no bytes before proof
//!   3. upstream HTTP    streamed with one-chunk lookahead, teed into the cache
//! ```
//!
//! **Sources 1 and 2 are read twice on purpose.** Hashing the whole thing
//! before opening the response means a corrupt or tampered artifact produces a
//! 404 and Nix never receives a single byte of it. Both sources are local disk,
//! where the second read is page-cache-warm and SHA-256 runs at gigabytes per
//! second, so the guarantee is close to free. This is what closes the gap
//! stage 1 left open.
//!
//! **Source 3 cannot have that guarantee, and pretending otherwise would be
//! worse than not having it.** Buffering a multi-gigabyte download before
//! emitting anything starves Nix of bytes, and Nix aborts a transfer that
//! delivers nothing for `stalled-download-timeout` (300s by default) — so
//! "verify everything first" would turn large paths from slow into impossible.
//! The first fetch therefore streams with the one-chunk lookahead from
//! `verify::Lookahead`, which still guarantees the body cannot *complete*
//! unless the digest matched, and tees a copy into the cache. Every subsequent
//! serve of that path comes from source 1 and does get the full guarantee.

use crate::cache::{Cache, Slot};
use crate::transport::ArtifactRef;
use crate::decompress::Codec;
use crate::narinfo::NarInfo;
use crate::nixhash::Sha256Digest;
use crate::verify::{Lookahead, Verifier};
use anyhow::{Context, Result};
use bytes::Bytes;
use futures_util::Stream;
use sha2::{Digest, Sha256};
use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::Arc;

/// Which source answered. Reported in the log and by `status`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Source {
    Cache,
    NixStore,
    Upstream,
}

impl Source {
    pub fn as_str(self) -> &'static str {
        match self {
            Source::Cache => "cache",
            Source::NixStore => "nix-store",
            Source::Upstream => "upstream",
        }
    }
}

/// Hash a file in full and compare against the signed digest and length.
///
/// Returns `Ok(())` only if the file on disk *is* the NAR the narinfo
/// describes. Any other outcome is a miss, not an error the caller should
/// propagate to Nix as a 500 — a bad cache entry is our problem to fall through
/// from, not Nix's problem to see.
pub fn verify_file(path: &Path, digest: &Sha256Digest, len: u64) -> Result<()> {
    let mut f = std::fs::File::open(path).with_context(|| format!("opening {}", path.display()))?;
    let meta = f.metadata()?;
    anyhow::ensure!(
        meta.len() == len,
        "{}: length {} != declared {len}",
        path.display(),
        meta.len()
    );
    let mut hasher = Sha256::new();
    let mut buf = vec![0u8; 256 * 1024];
    loop {
        let n = f.read(&mut buf)?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    let mut got = [0u8; 32];
    got.copy_from_slice(&hasher.finalize());
    let got = Sha256Digest(got);
    anyhow::ensure!(
        got == *digest,
        "{}: hash mismatch\n  expected: {}\n  got:      {}",
        path.display(),
        digest.to_prefixed(),
        got.to_prefixed()
    );
    Ok(())
}

/// Try the two local sources. Returns a path to a **fully verified** file.
///
/// `store_dir`/`serve_from_store` gate source 2; a `None` return means neither
/// local source could answer and the caller should go upstream.
pub fn local(
    cache: &Cache,
    ni: &NarInfo,
    store_dir: &str,
    serve_from_store: bool,
) -> Option<(Source, PathBuf)> {
    let digest = ni.nar_hash();
    let len = ni.nar_size().ok()?;

    if let Some(p) = cache.get(&digest, len) {
        match verify_file(&p, &digest, len) {
            Ok(()) => return Some((Source::Cache, p)),
            Err(e) => {
                // A cache entry that does not match its own name is corruption
                // or tampering. Drop it and carry on; the next source will
                // repopulate it.
                tracing::error!(error = %e, "REFUSED a cache entry; removing it");
                let _ = std::fs::remove_file(&p);
            }
        }
    }

    if serve_from_store {
        match dump_into_cache(cache, ni, store_dir) {
            // NOTE: nothing is announced here. `provide` is blocking by the
            // trait's contract and this function is called from an async
            // handler, so calling it here panics with "Cannot start a runtime
            // from within a runtime". The caller owns the blocking context and
            // announces there — see the `Source::NixStore` arm in http.rs.
            Ok(Some(p)) => return Some((Source::NixStore, p)),
            Ok(None) => {}
            Err(e) => tracing::warn!(error = %e, "nix-store dump failed; falling through"),
        }
    }
    None
}

/// Serialise a store path we already hold, verify it, and publish it as a cache
/// entry. Returns the cache path, or `None` if we do not have the path.
fn dump_into_cache(cache: &Cache, ni: &NarInfo, store_dir: &str) -> Result<Option<PathBuf>> {
    let digest = ni.nar_hash();
    let len = ni.nar_size()?;
    let store_path = ni.store_path();

    let Some(mut dump) = crate::nixstore::dump(store_dir, store_path)? else {
        return Ok(None);
    };
    let mut out = dump.stdout().context("nix-store --dump produced no stdout")?;

    let slot = cache.slot(&digest)?;
    let mut verifier = Verifier::new(digest, len, format!("nix-store:{store_path}"));
    {
        let mut f = std::fs::File::create(slot.temp_path())?;
        let mut buf = vec![0u8; 256 * 1024];
        loop {
            let n = out.read(&mut buf)?;
            if n == 0 {
                break;
            }
            verifier.update(&buf[..n])?;
            std::io::Write::write_all(&mut f, &buf[..n])?;
        }
        std::io::Write::flush(&mut f)?;
    }
    drop(out);
    dump.finish()?;
    // Publishing is conditional on the digest. A store path that is present but
    // invalid — the debris a failed substitution leaves behind — fails here and
    // the slot's Drop removes the temp file.
    verifier.finish()?;
    let p = slot.commit()?;
    if let Ok((b, a)) = cache.evict() {
        if b != a {
            tracing::info!(before = b, after = a, "evicted");
        }
    }
    Ok(Some(p))
}

/// The upstream path: decompress, verify, tee into the cache, and stream out.
///
/// The decoders are blocking `Read`s and the body is an async stream, so the
/// whole pipeline runs on a blocking task and hands finished chunks back over a
/// channel. The lookahead lives on the blocking side because that is where the
/// digest is known.
#[allow(clippy::too_many_arguments)]
pub fn upstream_stream<S>(
    body: S,
    codec: Codec,
    mut verifier: Verifier,
    slot: Option<Slot>,
    cache: Option<Arc<Cache>>,
    transport: Option<Arc<dyn crate::transport::ArtifactTransport>>,
) -> impl Stream<Item = std::io::Result<Bytes>> + Send
where
    S: Stream<Item = std::io::Result<Bytes>> + Send + Unpin + 'static,
{
    let (tx, mut rx) = tokio::sync::mpsc::channel::<std::io::Result<Bytes>>(4);

    tokio::task::spawn_blocking(move || {
        let bridge = tokio_util::io::SyncIoBridge::new(tokio_util::io::StreamReader::new(body));
        let mut dec = codec.reader(bridge);
        let mut la = Lookahead::default();
        let mut file = match slot.as_ref().map(|s| std::fs::File::create(s.temp_path())) {
            None => None,
            Some(Ok(f)) => Some(f),
            Some(Err(e)) => {
                // Not fatal: serving Nix matters more than populating a cache.
                tracing::warn!(error = %e, "cannot open cache slot; serving without caching");
                None
            }
        };
        let mut buf = vec![0u8; 256 * 1024];
        let fail = |tx: &tokio::sync::mpsc::Sender<_>, e: String| {
            let _ = tx.blocking_send(Err(std::io::Error::other(e)));
        };

        loop {
            let n = match dec.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => n,
                Err(e) => {
                    tracing::warn!(error = %e, "upstream read/decompress failed");
                    fail(&tx, e.to_string());
                    return;
                }
            };
            if let Err(e) = verifier.update(&buf[..n]) {
                tracing::error!(after = verifier.seen(), error = %e, "REFUSED mid-stream");
                fail(&tx, e.to_string());
                return;
            }
            if let Some(f) = file.as_mut() {
                if let Err(e) = std::io::Write::write_all(f, &buf[..n]) {
                    tracing::warn!(error = %e, "cache write failed; continuing without caching");
                    file = None;
                }
            }
            if let Some(prev) = la.push(Bytes::copy_from_slice(&buf[..n])) {
                if tx.blocking_send(Ok(prev)).is_err() {
                    // Nix hung up. Nothing to serve, and a partial file must
                    // not be published; dropping `slot` removes it.
                    return;
                }
            }
        }

        match verifier.finish() {
            Err(e) => {
                tracing::error!(error = %e, "REFUSED at end of stream");
                fail(&tx, e.to_string());
            }
            Ok(v) => {
                let cached = file
                    .as_mut()
                    .map(|f| std::io::Write::flush(f))
                    .transpose()
                    .is_ok();
                drop(file);
                if cached {
                    if let Some(s) = slot {
                        match s.commit() {
                            Ok(p) => {
                                tracing::debug!(path = %p.display(), "cached");
                                // Seed what we just fetched. This is the COMMON
                                // case — a host pulls a rebuild from upstream
                                // and its neighbours then pull it from the
                                // host — and wiring `provide` only into the
                                // peer-fetch path missed it entirely, so
                                // nothing ever seeded anything it had not
                                // itself received from another peer.
                                if let Some(t) = transport.as_ref() {
                                    let a = ArtifactRef {
                                        hash_part: String::new(),
                                        nar_hash: v.digest,
                                        nar_size: v.bytes,
                                    };
                                    if let Err(e) = t.provide(&a, &p) {
                                        tracing::warn!(error = %e, "could not announce");
                                    }
                                }
                                // Sweep here, not only at startup. A daemon that
                                // runs for weeks would otherwise grow without
                                // bound between restarts, and `maxCacheSize`
                                // would describe a boot-time snapshot rather
                                // than a budget.
                                if let Some(c) = cache.as_ref() {
                                    match c.evict_with(&|d| {
                                        if let Some(t) = transport.as_ref() {
                                            let a = ArtifactRef {
                                                hash_part: String::new(),
                                                nar_hash: *d,
                                                nar_size: 0,
                                            };
                                            let _ = t.remove(&a);
                                        }
                                    }) {
                                        Ok((b, a)) if b != a => {
                                            tracing::info!(before = b, after = a, "evicted")
                                        }
                                        Ok(_) => {}
                                        Err(e) => tracing::warn!(error = %e, "eviction failed"),
                                    }
                                }
                            }
                            Err(e) => tracing::warn!(error = %e, "cache publish failed"),
                        }
                    }
                }
                tracing::debug!(bytes = v.bytes, digest = %v.digest.to_nix32(), "verified");
                if let Some(last) = la.take() {
                    let _ = tx.blocking_send(Ok(last));
                }
            }
        }
    });

    async_stream::stream! {
        while let Some(item) = rx.recv().await {
            yield item;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn digest_of(data: &[u8]) -> Sha256Digest {
        let mut h = Sha256::new();
        h.update(data);
        let mut o = [0u8; 32];
        o.copy_from_slice(&h.finalize());
        Sha256Digest(o)
    }

    #[test]
    fn verify_file_accepts_the_real_thing() {
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("a.nar");
        std::fs::write(&p, b"hello nar").unwrap();
        assert!(verify_file(&p, &digest_of(b"hello nar"), 9).is_ok());
    }

    #[test]
    fn verify_file_catches_a_length_preserving_corruption() {
        // The case a length check alone cannot see, and the reason source 1
        // re-hashes instead of trusting the filename.
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("a.nar");
        std::fs::write(&p, b"hello nnr").unwrap();
        let e = verify_file(&p, &digest_of(b"hello nar"), 9).unwrap_err();
        assert!(e.to_string().contains("hash mismatch"), "{e}");
    }

    #[test]
    fn verify_file_catches_truncation_before_hashing() {
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("a.nar");
        std::fs::write(&p, b"hello").unwrap();
        assert!(verify_file(&p, &digest_of(b"hello nar"), 9).is_err());
    }

    // ── upstream_stream: the path bytes from the network actually take ─────
    // These assert the guarantee end-to-end against the code that runs, rather
    // than against `Verifier` in isolation. Testing only the latter is exactly
    // what let the stage-1 bug through.

    async fn drive(
        chunks: Vec<&'static [u8]>,
        expect: &[u8],
        slot: Option<Slot>,
    ) -> (Vec<u8>, Option<String>) {
        use futures_util::StreamExt;
        let total: usize = chunks.iter().map(|c| c.len()).sum();
        let v = Verifier::new(digest_of(expect), total as u64, "fake-upstream");
        let src = futures_util::stream::iter(
            chunks.into_iter().map(|c| Ok(Bytes::from_static(c))),
        );
        let st = upstream_stream(Box::pin(src), Codec::None, v, slot, None, None);
        futures_util::pin_mut!(st);
        let (mut out, mut err) = (Vec::new(), None);
        while let Some(item) = st.next().await {
            match item {
                Ok(b) => out.extend_from_slice(&b),
                Err(e) => {
                    err = Some(e.to_string());
                    break;
                }
            }
        }
        (out, err)
    }

    #[tokio::test]
    async fn a_good_stream_passes_every_byte_through_in_order() {
        let (out, err) = drive(vec![b"abc", b"def", b"ghi"], b"abcdefghi", None).await;
        assert_eq!(err, None);
        assert_eq!(out, b"abcdefghi");
    }

    #[tokio::test]
    async fn a_corrupt_body_never_completes() {
        // THE regression test. Before the lookahead existed, the digest check
        // lived after the read loop and a Content-Length-sized consumer dropped
        // the generator before reaching it — so a length-preserving corruption
        // was served with HTTP 200 and nothing in the log. Reproduced against a
        // real upstream at the time.
        let (out, err) = drive(vec![b"abc", b"deX", b"ghi"], b"abcdefghi", None).await;
        assert!(err.is_some(), "corrupt body completed cleanly");
        assert!(err.unwrap().contains("hash mismatch"));
        assert!(out.len() < 9, "emitted {} of 9 bytes", out.len());
    }

    #[tokio::test]
    async fn a_corrupt_body_is_never_published_to_the_cache() {
        // Stage 2's addition: a failed fetch must not leave a named cache
        // entry, or every later request would serve the bad bytes from disk
        // without ever contacting upstream again.
        let d = tempfile::tempdir().unwrap();
        let c = Cache::new(d.path(), 1 << 30).unwrap();
        let dg = digest_of(b"abcdefghi");
        let slot = c.slot(&dg).unwrap();
        let tmp = slot.temp_path().to_path_buf();

        let (_, err) = drive(vec![b"abc", b"deX", b"ghi"], b"abcdefghi", Some(slot)).await;
        assert!(err.is_some());

        // The load-bearing half, and it is synchronous: publishing is a
        // `rename` that never happened, so the name cannot exist.
        assert!(c.get(&dg, 9).is_none(), "a corrupt body was published");

        // Removing the temp is best-effort and happens when the blocking task
        // drops its slot, which is not ordered against the consumer seeing the
        // error. Poll rather than assume — an earlier version of this test
        // asserted immediately, passed on this machine and failed in the build
        // sandbox. `Cache::new` sweeps `tmp/` at startup for the same reason:
        // the cleanup is eventual, so something has to be the backstop.
        for _ in 0..100 {
            if !tmp.exists() {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }
        assert!(!tmp.exists(), "temp file left behind");
    }

    #[tokio::test]
    async fn a_good_body_is_published_and_then_served_locally() {
        // The other half: a verified fetch becomes a cache entry, and that
        // entry then satisfies `local()` in full — which is what upgrades every
        // subsequent serve to "verified before a byte goes out".
        let d = tempfile::tempdir().unwrap();
        let c = Cache::new(d.path(), 1 << 30).unwrap();
        let dg = digest_of(b"abcdefghi");
        let slot = c.slot(&dg).unwrap();

        let (out, err) = drive(vec![b"abc", b"def", b"ghi"], b"abcdefghi", Some(slot)).await;
        assert_eq!(err, None);
        assert_eq!(out, b"abcdefghi");

        let ni = NarInfo::parse(&format!(
            "StorePath: /nix/store/00000000000000000000000000000000-x\n\
             URL: nar/x.nar\nNarHash: {}\nNarSize: 9\n",
            dg.to_prefixed()
        ))
        .unwrap();
        let (src, path) = local(&c, &ni, "/nix/store", false).expect("cache miss after a good fetch");
        assert_eq!(src, Source::Cache);
        assert_eq!(std::fs::read(path).unwrap(), b"abcdefghi");
    }

    #[test]
    fn a_corrupt_cache_entry_is_removed_rather_than_served() {
        // Falling through is not enough: leaving the bad entry means every
        // future request pays the hash and fails again.
        let d = tempfile::tempdir().unwrap();
        let c = Cache::new(d.path(), 1 << 30).unwrap();
        let good = b"the real nar";
        let dg = digest_of(good);
        let slot = c.slot(&dg).unwrap();
        let mut f = std::fs::File::create(slot.temp_path()).unwrap();
        f.write_all(b"the fake nar").unwrap(); // same length, wrong bytes
        drop(f);
        let p = slot.commit().unwrap();
        assert!(p.exists());

        let ni = NarInfo::parse(&format!(
            "StorePath: /nix/store/00000000000000000000000000000000-x\n\
             URL: nar/x.nar\nNarHash: {}\nNarSize: {}\n",
            dg.to_prefixed(),
            good.len()
        ))
        .unwrap();

        assert!(local(&c, &ni, "/nix/store", false).is_none());
        assert!(!p.exists(), "corrupt entry left in place");
    }
}
