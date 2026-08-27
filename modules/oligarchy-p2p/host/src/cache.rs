//! The local artifact cache.
//!
//! One file per store path, named by its **`NarHash`** — the hash the upstream
//! signature actually covers — holding the canonical uncompressed NAR. That
//! naming is the whole point: `NarHash` is immutable for a given store path, so
//! a cache entry never goes stale and never has to be invalidated. Compare
//! stage 1, which keyed the URL on the unsigned `FileHash` and broke whenever
//! upstream re-compressed.
//!
//! Nothing is named until it has been verified. Writes land in `tmp/` and are
//! `rename`d into place only after the digest matches, so a crash, a disk-full
//! or a lying peer leaves debris in `tmp/` and never a wrong answer under a
//! right name. `rename(2)` within a filesystem is atomic, which is why both
//! directories live under the same state dir.

use crate::nixhash::Sha256Digest;
use anyhow::{bail, Context, Result};
use std::fs;
use std::path::{Path, PathBuf};

pub struct Cache {
    nar_dir: PathBuf,
    tmp_dir: PathBuf,
    narinfo_dir: PathBuf,
    max_bytes: u64,
}

/// Ceiling for the narinfo directory, independent of `max_bytes`.
///
/// A narinfo is a few hundred bytes, so this is on the order of 10^5 entries
/// and rounds to nothing beside the NARs. It is separate rather than shared
/// because the two must not compete: evicting metadata to make room for one
/// more artifact would trade a cheap thing for an expensive one, and metadata
/// is what makes the artifacts reachable at all when upstream is gone.
const NARINFO_BUDGET: u64 = 64 * 1024 * 1024;

/// A reserved temp file that becomes a cache entry only on `commit`.
pub struct Slot {
    tmp: PathBuf,
    final_path: PathBuf,
    committed: bool,
}

impl Slot {
    pub fn temp_path(&self) -> &Path {
        &self.tmp
    }

    /// Publish the entry. Only call this once the digest has been checked.
    pub fn commit(mut self) -> Result<PathBuf> {
        fs::rename(&self.tmp, &self.final_path).with_context(|| {
            format!("publishing {} -> {}", self.tmp.display(), self.final_path.display())
        })?;
        self.committed = true;
        Ok(self.final_path.clone())
    }
}

impl Drop for Slot {
    fn drop(&mut self) {
        // A slot that was never committed failed verification, or the process
        // died mid-fetch. Either way the bytes are worthless; do not leave them
        // to be swept up later and mistaken for a cache entry.
        if !self.committed {
            let _ = fs::remove_file(&self.tmp);
        }
    }
}

impl Cache {
    pub fn new(state_dir: &Path, max_bytes: u64) -> Result<Self> {
        let nar_dir = state_dir.join("nar");
        let tmp_dir = state_dir.join("tmp");
        let narinfo_dir = state_dir.join("narinfo");
        fs::create_dir_all(&nar_dir).with_context(|| format!("creating {}", nar_dir.display()))?;
        fs::create_dir_all(&tmp_dir).with_context(|| format!("creating {}", tmp_dir.display()))?;
        fs::create_dir_all(&narinfo_dir)
            .with_context(|| format!("creating {}", narinfo_dir.display()))?;
        // Anything in tmp/ is from a previous life and is by definition
        // unverified. Sweep it at startup rather than letting it accumulate.
        if let Ok(rd) = fs::read_dir(&tmp_dir) {
            for e in rd.flatten() {
                let _ = fs::remove_file(e.path());
            }
        }
        Ok(Self { nar_dir, tmp_dir, narinfo_dir, max_bytes })
    }

    // ── narinfo ────────────────────────────────────────────────────────────
    //
    // Caching the metadata is not an optimisation, it is what makes the
    // artifact cache reachable. Without it every NAR request first has to
    // resolve a narinfo, that resolution goes upstream, and a populated cache
    // is useless the moment upstream is unreachable — which is exactly the
    // situation it exists for. (Observed: a cache hit returned 404 with
    // upstream down, because the metadata lookup failed first.)
    //
    // What is stored is upstream's narinfo **verbatim**, signatures and all,
    // not our rewritten one. The rewrite is cheap and regenerating it keeps a
    // single source of truth; storing the derived form would mean a change to
    // `rewrite_transport` silently disagreeing with everything already on disk.
    //
    // Staleness is not a concern: a store path is named by a hash of its own
    // inputs, so its narinfo is immutable. The only thing that can change is
    // gaining another `Sig` line, and serving a narinfo with fewer signatures
    // can only ever cause a refusal, never a false acceptance.

    fn narinfo_path(&self, hash_part: &str) -> PathBuf {
        self.narinfo_dir.join(format!("{hash_part}.narinfo"))
    }

    pub fn get_narinfo(&self, hash_part: &str) -> Option<String> {
        let p = self.narinfo_path(hash_part);
        let text = fs::read_to_string(&p).ok()?;
        self.touch(&p);
        Some(text)
    }

    pub fn put_narinfo(&self, hash_part: &str, text: &str) -> Result<()> {
        let final_path = self.narinfo_path(hash_part);
        let tmp = self.tmp_dir.join(format!("{hash_part}.{}.narinfo", std::process::id()));
        fs::write(&tmp, text)?;
        fs::rename(&tmp, &final_path)?;
        Ok(())
    }

    pub fn path_for(&self, nar_hash: &Sha256Digest) -> PathBuf {
        self.nar_dir.join(format!("{}.nar", nar_hash.to_nix32()))
    }

    /// A cache entry for this NAR, if one exists and is the right length.
    ///
    /// The length check is cheap and catches a truncated leftover; it is **not**
    /// the integrity check. Callers re-hash before serving — see `resolve`.
    pub fn get(&self, nar_hash: &Sha256Digest, nar_size: u64) -> Option<PathBuf> {
        let p = self.path_for(nar_hash);
        match fs::metadata(&p) {
            Ok(m) if m.is_file() && m.len() == nar_size => {
                self.touch(&p);
                Some(p)
            }
            _ => None,
        }
    }

    /// Reserve a slot. The temp name includes the target so a stray file is
    /// traceable to the fetch that produced it.
    pub fn slot(&self, nar_hash: &Sha256Digest) -> Result<Slot> {
        let stem = nar_hash.to_nix32();
        let tmp = self.tmp_dir.join(format!("{stem}.{}.part", std::process::id()));
        let _ = fs::remove_file(&tmp);
        Ok(Slot {
            tmp,
            final_path: self.nar_dir.join(format!("{stem}.nar")),
            committed: false,
        })
    }

    /// Mark an entry as recently used, so eviction is LRU rather than FIFO.
    ///
    /// Without this the cache evicts by insertion order, which is actively
    /// wrong here: the large artifacts worth caching (a toolchain, a browser)
    /// are inserted once and reused for months, while small churny paths are
    /// inserted constantly. FIFO would evict exactly the entries that pay for
    /// themselves.
    fn touch(&self, p: &Path) {
        use std::os::unix::ffi::OsStrExt;
        let Ok(c) = std::ffi::CString::new(p.as_os_str().as_bytes()) else {
            return;
        };
        let now = [
            libc::timespec { tv_sec: 0, tv_nsec: libc::UTIME_NOW },
            libc::timespec { tv_sec: 0, tv_nsec: libc::UTIME_NOW },
        ];
        // Best effort. A cache whose mtimes stop updating degrades to FIFO,
        // which is worse but not wrong, so this must never be fatal.
        unsafe {
            libc::utimensat(libc::AT_FDCWD, c.as_ptr(), now.as_ptr(), 0);
        }
    }

    pub fn total_bytes(&self) -> Result<u64> {
        let mut total = 0u64;
        for e in fs::read_dir(&self.nar_dir)?.flatten() {
            if let Ok(m) = e.metadata() {
                total = total.saturating_add(m.len());
            }
        }
        Ok(total)
    }

    /// Evict least-recently-used entries until the cache fits.
    /// Returns `(before, after)` in bytes for the NAR directory.
    pub fn evict(&self) -> Result<(u64, u64)> {
        // Metadata is swept under its own budget so the two never compete.
        if let Err(e) = self.sweep(&self.narinfo_dir, NARINFO_BUDGET) {
            tracing::warn!(error = %e, "narinfo sweep failed");
        }
        self.sweep(&self.nar_dir, self.max_bytes)
    }

    fn sweep(&self, dir: &Path, budget: u64) -> Result<(u64, u64)> {
        let mut entries: Vec<(std::time::SystemTime, u64, PathBuf)> = Vec::new();
        let mut total = 0u64;
        for e in fs::read_dir(dir)?.flatten() {
            let Ok(m) = e.metadata() else { continue };
            if !m.is_file() {
                continue;
            }
            total = total.saturating_add(m.len());
            entries.push((m.modified().unwrap_or(std::time::UNIX_EPOCH), m.len(), e.path()));
        }
        let before = total;
        if total <= budget {
            return Ok((before, total));
        }
        entries.sort_by_key(|(t, _, _)| *t);
        for (_, len, path) in entries {
            if total <= budget {
                break;
            }
            match fs::remove_file(&path) {
                Ok(()) => {
                    tracing::debug!(path = %path.display(), len, "evicted");
                    total = total.saturating_sub(len);
                }
                Err(e) => tracing::warn!(path = %path.display(), error = %e, "eviction failed"),
            }
        }
        Ok((before, total))
    }
}

/// Parse a human size: bare bytes, or a `K`/`M`/`G`/`T` suffix (binary units,
/// matching how everything else in this repo and in systemd spells sizes).
pub fn parse_size(s: &str) -> Result<u64> {
    let t = s.trim();
    if t.is_empty() {
        bail!("empty size");
    }
    let (num, mult) = match t.chars().last().unwrap().to_ascii_uppercase() {
        'K' => (&t[..t.len() - 1], 1024u64),
        'M' => (&t[..t.len() - 1], 1024 * 1024),
        'G' => (&t[..t.len() - 1], 1024 * 1024 * 1024),
        'T' => (&t[..t.len() - 1], 1024u64 * 1024 * 1024 * 1024),
        _ => (t, 1),
    };
    let n: u64 = num
        .trim()
        .parse()
        .with_context(|| format!("{s:?} is not a size like \"20G\" or \"1048576\""))?;
    n.checked_mul(mult)
        .with_context(|| format!("{s:?} overflows a u64"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn digest(n: u8) -> Sha256Digest {
        Sha256Digest([n; 32])
    }

    #[test]
    fn sizes_parse_in_binary_units() {
        assert_eq!(parse_size("1024").unwrap(), 1024);
        assert_eq!(parse_size("1K").unwrap(), 1024);
        assert_eq!(parse_size("20G").unwrap(), 20 * 1024 * 1024 * 1024);
        assert_eq!(parse_size(" 512M ").unwrap(), 512 * 1024 * 1024);
        assert_eq!(parse_size("2g").unwrap(), 2 * 1024 * 1024 * 1024);
    }

    #[test]
    fn refuses_a_size_it_cannot_parse() {
        for bad in ["", "G", "twenty", "1.5G", "-1", "99999999999999999999T"] {
            assert!(parse_size(bad).is_err(), "accepted {bad:?}");
        }
    }

    #[test]
    fn an_uncommitted_slot_leaves_nothing_behind() {
        // The guarantee that makes a crash safe: a name only ever appears in
        // nar/ after the digest matched.
        let d = tempfile::tempdir().unwrap();
        let c = Cache::new(d.path(), 1 << 30).unwrap();
        let tmp_path;
        {
            let slot = c.slot(&digest(1)).unwrap();
            tmp_path = slot.temp_path().to_path_buf();
            fs::write(&tmp_path, b"half a nar").unwrap();
            assert!(tmp_path.exists());
            // dropped without commit
        }
        assert!(!tmp_path.exists(), "temp survived an uncommitted slot");
        assert!(c.get(&digest(1), 10).is_none(), "an unverified entry became visible");
    }

    #[test]
    fn a_committed_slot_becomes_a_cache_hit() {
        let d = tempfile::tempdir().unwrap();
        let c = Cache::new(d.path(), 1 << 30).unwrap();
        let slot = c.slot(&digest(2)).unwrap();
        fs::write(slot.temp_path(), b"0123456789").unwrap();
        let p = slot.commit().unwrap();
        assert!(p.exists());
        assert_eq!(c.get(&digest(2), 10), Some(p));
    }

    #[test]
    fn a_wrong_length_entry_is_not_a_hit() {
        let d = tempfile::tempdir().unwrap();
        let c = Cache::new(d.path(), 1 << 30).unwrap();
        let slot = c.slot(&digest(3)).unwrap();
        fs::write(slot.temp_path(), b"short").unwrap();
        slot.commit().unwrap();
        assert!(c.get(&digest(3), 999).is_none());
    }

    #[test]
    fn startup_sweeps_unverified_leftovers() {
        // A previous process died mid-fetch. Those bytes never passed a digest
        // check and must not be mistaken for anything.
        let d = tempfile::tempdir().unwrap();
        fs::create_dir_all(d.path().join("tmp")).unwrap();
        let junk = d.path().join("tmp/leftover.part");
        fs::write(&junk, b"garbage").unwrap();
        let _c = Cache::new(d.path(), 1 << 30).unwrap();
        assert!(!junk.exists(), "leftover temp survived startup");
    }

    #[test]
    fn narinfo_round_trips_and_survives_a_restart() {
        // The guarantee that makes the artifact cache usable offline.
        let d = tempfile::tempdir().unwrap();
        {
            let c = Cache::new(d.path(), 1 << 30).unwrap();
            assert!(c.get_narinfo("abc").is_none());
            c.put_narinfo("abc", "StorePath: /nix/store/x\nSig: k:v\n").unwrap();
            assert!(c.get_narinfo("abc").unwrap().contains("Sig: k:v"));
        }
        // A fresh Cache sweeps tmp/ but must not touch narinfo/.
        let c2 = Cache::new(d.path(), 1 << 30).unwrap();
        assert!(c2.get_narinfo("abc").unwrap().contains("Sig: k:v"));
    }

    #[test]
    fn evicting_nars_does_not_evict_metadata() {
        // If a NAR eviction took the narinfo with it, the next request could
        // not even find out what to fetch — the cache would forget how to
        // refill itself. The two budgets are separate for this reason.
        let d = tempfile::tempdir().unwrap();
        let c = Cache::new(d.path(), 1).unwrap(); // NAR budget: one byte
        c.put_narinfo("keepme", "StorePath: /nix/store/x\nNarHash: sha256:z\n").unwrap();
        let slot = c.slot(&digest(9)).unwrap();
        fs::write(slot.temp_path(), vec![0u8; 4096]).unwrap();
        slot.commit().unwrap();

        let (before, after) = c.evict().unwrap();
        assert_eq!(before, 4096);
        assert!(after <= 1, "NAR budget not enforced: {after}");
        assert!(c.get_narinfo("keepme").is_some(), "metadata evicted with the NARs");
    }

    #[test]
    fn eviction_drops_the_least_recently_used_first() {
        let d = tempfile::tempdir().unwrap();
        // Room for two 100-byte entries, not three.
        let c = Cache::new(d.path(), 250).unwrap();
        for i in 1..=3u8 {
            let slot = c.slot(&digest(i)).unwrap();
            let mut f = fs::File::create(slot.temp_path()).unwrap();
            f.write_all(&vec![0u8; 100]).unwrap();
            drop(f);
            slot.commit().unwrap();
            // mtime has 1s granularity on some filesystems; make the order
            // unambiguous rather than racing it.
            std::thread::sleep(std::time::Duration::from_millis(1100));
        }
        // Touch the oldest so it is no longer the LRU victim.
        assert!(c.get(&digest(1), 100).is_some());
        std::thread::sleep(std::time::Duration::from_millis(1100));

        let (before, after) = c.evict().unwrap();
        assert_eq!(before, 300);
        assert!(after <= 250, "still over budget: {after}");
        assert!(c.get(&digest(1), 100).is_some(), "evicted the entry we just used");
        assert!(c.get(&digest(2), 100).is_none(), "LRU victim survived");
    }
}
