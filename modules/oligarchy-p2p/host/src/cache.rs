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
    declared_dir: PathBuf,
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
    /// Open the cache directories, creating them if needed. No sweep.
    pub fn open(state_dir: &Path, max_bytes: u64) -> Result<Self> {
        let nar_dir = state_dir.join("nar");
        let tmp_dir = state_dir.join("tmp");
        let narinfo_dir = state_dir.join("narinfo");
        let declared_dir = state_dir.join("declared");
        fs::create_dir_all(&nar_dir).with_context(|| format!("creating {}", nar_dir.display()))?;
        fs::create_dir_all(&tmp_dir).with_context(|| format!("creating {}", tmp_dir.display()))?;
        fs::create_dir_all(&narinfo_dir)
            .with_context(|| format!("creating {}", narinfo_dir.display()))?;
        // Best effort, unlike the other three. This directory is created by
        // tmpfiles as root and the daemon is given it read-only, so a failure
        // here is normal and must not stop the daemon; a missing declared tier
        // simply reads as empty.
        let _ = fs::create_dir_all(&declared_dir);
        Ok(Self { nar_dir, tmp_dir, narinfo_dir, declared_dir, max_bytes })
    }

    /// As `open`, plus the startup sweep. **Daemon only.**
    ///
    /// Anything in `tmp/` is from a previous life and is by definition
    /// unverified, so the daemon clears it on the way up. The `seed`
    /// subcommand must NOT do this: it is a different process that can run
    /// while the daemon is mid-fetch, and sweeping `tmp/` under it would
    /// delete a slot that is being written and turn a good fetch into a
    /// rename of a file that is no longer there.
    pub fn new(state_dir: &Path, max_bytes: u64) -> Result<Self> {
        let c = Self::open(state_dir, max_bytes)?;
        if let Ok(rd) = fs::read_dir(&c.tmp_dir) {
            for e in rd.flatten() {
                let _ = fs::remove_file(e.path());
            }
        }
        Ok(c)
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
        // Declared first, and never touched. A declared narinfo is not a cache
        // entry that happens to be here — it is state this host published on
        // purpose, and it outranks anything a fetch may have left behind.
        if let Ok(text) = fs::read_to_string(self.declared_path(hash_part)) {
            return Some(text);
        }
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

    // ── declared ───────────────────────────────────────────────────────────
    //
    // Metadata this host MINTED and SIGNED for paths its operator declared in
    // `servePackages`, rather than metadata it fetched from somebody else.
    //
    // It lives in its own directory for one reason: **it must never be
    // evicted.** A fetched narinfo that gets swept can be fetched again; a
    // declared one cannot, because nothing upstream has ever heard of the path.
    // Evicting it would silently unpublish a package while the daemon carried
    // on looking healthy. `evict_with` sweeps `narinfo/` and `nar/` and is not
    // told this directory exists.
    //
    // The writer is a separate root oneshot (`oligarchy-p2pd seed`), not the
    // daemon: minting requires a signing key and the Nix database, and the
    // daemon is deliberately allowed neither.

    pub fn declared_dir(&self) -> &Path {
        &self.declared_dir
    }

    /// Whether this hash part is one we published rather than one we fetched.
    ///
    /// The NAR path uses this to skip the upstream arm: a locally-built path
    /// is by definition not on cache.nixos.org, so asking for it is a
    /// guaranteed miss that leaks the hash part of a path built inside this
    /// LAN to a public cache, once per request.
    pub fn is_declared(&self, hash_part: &str) -> bool {
        self.declared_path(hash_part).exists()
    }

    fn declared_path(&self, hash_part: &str) -> PathBuf {
        self.declared_dir.join(format!("{hash_part}.narinfo"))
    }

    /// Publish a minted narinfo. Mode `0644`: the daemon runs `PrivateUsers`
    /// and would not be able to read a root-owned `0600` file here, and a
    /// narinfo is public data — it is handed to every peer that asks.
    pub fn put_declared(&self, hash_part: &str, text: &str) -> Result<()> {
        use std::os::unix::fs::PermissionsExt;
        let final_path = self.declared_path(hash_part);
        // Deliberately NOT tmp/: that directory is swept wholesale at daemon
        // startup, and the emitter is a different process that may run while
        // the daemon is mid-fetch. Same filesystem either way, so the rename
        // is still atomic.
        let tmp = self.declared_dir.join(format!(".{hash_part}.{}.part", std::process::id()));
        fs::write(&tmp, text).with_context(|| format!("writing {}", tmp.display()))?;
        fs::set_permissions(&tmp, fs::Permissions::from_mode(0o644))?;
        fs::rename(&tmp, &final_path).with_context(|| {
            format!("publishing {} -> {}", tmp.display(), final_path.display())
        })?;
        Ok(())
    }

    /// The hash parts currently published.
    pub fn list_declared(&self) -> Result<Vec<String>> {
        let mut out = Vec::new();
        for e in fs::read_dir(&self.declared_dir)?.flatten() {
            let name = e.file_name();
            let Some(name) = name.to_str() else { continue };
            if name.starts_with('.') {
                continue;
            }
            if let Some(hp) = name.strip_suffix(".narinfo") {
                out.push(hp.to_string());
            }
        }
        out.sort();
        Ok(out)
    }

    /// Unpublish. Dropping a package from `servePackages` must actually stop
    /// this host serving it, or the declared set would only ever grow.
    pub fn remove_declared(&self, hash_part: &str) -> Result<()> {
        match fs::remove_file(self.declared_path(hash_part)) {
            Ok(()) => Ok(()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(e) => Err(e).with_context(|| format!("unpublishing {hash_part}")),
        }
    }

    /// Drop a fetched narinfo. Used when one is found to be unservable after
    /// the fact — a scope refusal on the read path — because leaving it there
    /// means answering with it again on the next request.
    pub fn remove_narinfo(&self, hash_part: &str) -> Result<()> {
        match fs::remove_file(self.narinfo_path(hash_part)) {
            Ok(()) => Ok(()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(e) => Err(e).with_context(|| format!("dropping narinfo {hash_part}")),
        }
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
        self.evict_with(&|_| {})
    }

    /// As `evict`, but tell `on_evict` about each artifact **before** its file
    /// is removed.
    ///
    /// The ordering is the point. A seeding transport has the file open and is
    /// advertising it to a swarm; deleting it first leaves peers talking to a
    /// host that claims to have an artifact and cannot produce it, which is
    /// worse than one that never claimed it.
    pub fn evict_with(&self, on_evict: &dyn Fn(&Sha256Digest)) -> Result<(u64, u64)> {
        // Metadata is swept under its own budget so the two never compete.
        // Nothing announces a narinfo, so no callback here.
        if let Err(e) = self.sweep(&self.narinfo_dir, NARINFO_BUDGET, &|_| {}) {
            tracing::warn!(error = %e, "narinfo sweep failed");
        }
        self.sweep(&self.nar_dir, self.max_bytes, on_evict)
    }

    /// The digest an artifact filename encodes, if it is one of ours.
    fn digest_of(path: &Path) -> Option<Sha256Digest> {
        let stem = path.file_name()?.to_str()?.strip_suffix(".nar")?;
        Sha256Digest::from_nix32(stem).ok()
    }

    fn sweep(&self, dir: &Path, budget: u64, on_evict: &dyn Fn(&Sha256Digest)) -> Result<(u64, u64)> {
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
            if let Some(d) = Self::digest_of(&path) {
                on_evict(&d);
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
    fn a_declared_narinfo_is_never_evicted() {
        // The guarantee: a fetched narinfo that gets swept can be fetched
        // again; a declared one cannot, because nothing upstream has ever
        // heard of the path. Evicting it would silently unpublish a package.
        let d = tempfile::tempdir().unwrap();
        let c = Cache::new(d.path(), 1 << 30).unwrap();

        // Fill narinfo/ far past its own budget with fetched entries...
        let filler = "x".repeat(64 * 1024);
        for i in 0..(NARINFO_BUDGET / filler.len() as u64 + 8) {
            c.put_narinfo(&format!("fetched{i:028}"), &filler).unwrap();
        }
        // ...and publish one declared entry.
        c.put_declared("dddddddddddddddddddddddddddddddd", "StorePath: /nix/store/x\n").unwrap();

        c.evict().unwrap();

        assert_eq!(
            c.get_narinfo("dddddddddddddddddddddddddddddddd").as_deref(),
            Some("StorePath: /nix/store/x\n"),
            "eviction reached the declared tier"
        );
    }

    #[test]
    fn a_declared_narinfo_outranks_a_fetched_one() {
        // Same hash part in both tiers. Declared wins: it is what this host
        // deliberately published, and a stale fetched copy must not shadow it.
        let d = tempfile::tempdir().unwrap();
        let c = Cache::new(d.path(), 1 << 30).unwrap();
        let hp = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        c.put_narinfo(hp, "fetched").unwrap();
        c.put_declared(hp, "declared").unwrap();
        assert_eq!(c.get_narinfo(hp).as_deref(), Some("declared"));
    }

    #[test]
    fn a_dropped_package_is_unpublished() {
        let d = tempfile::tempdir().unwrap();
        let c = Cache::new(d.path(), 1 << 30).unwrap();
        let hp = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
        c.put_declared(hp, "declared").unwrap();
        assert_eq!(c.list_declared().unwrap(), vec![hp.to_string()]);
        c.remove_declared(hp).unwrap();
        assert!(c.list_declared().unwrap().is_empty());
        assert!(c.get_narinfo(hp).is_none(), "an unpublished path is still served");
        // Idempotent: re-running the emitter must not fail on an absent entry.
        c.remove_declared(hp).unwrap();
    }

    #[test]
    fn a_declared_narinfo_is_readable_by_the_daemon() {
        // The daemon runs PrivateUsers and cannot read a root-owned 0600 file
        // the emitter left here. A narinfo is public data anyway — it is handed
        // to every peer that asks.
        use std::os::unix::fs::PermissionsExt;
        let d = tempfile::tempdir().unwrap();
        let c = Cache::new(d.path(), 1 << 30).unwrap();
        let hp = "cccccccccccccccccccccccccccccccc";
        c.put_declared(hp, "declared").unwrap();
        let mode = fs::metadata(c.declared_dir().join(format!("{hp}.narinfo")))
            .unwrap()
            .permissions()
            .mode();
        assert_eq!(mode & 0o777, 0o644, "declared narinfo is not world-readable");
    }

    #[test]
    fn seeding_does_not_sweep_an_in_flight_fetch() {
        // `Cache::open` is what the emitter uses. If it swept tmp/ like
        // `Cache::new` does, running the seed oneshot while the daemon was
        // mid-fetch would delete the slot under it and turn a good fetch into
        // a rename of a file that is no longer there.
        let d = tempfile::tempdir().unwrap();
        let daemon = Cache::new(d.path(), 1 << 30).unwrap();
        let slot = daemon.slot(&digest(9)).unwrap();
        fs::write(slot.temp_path(), b"in flight").unwrap();

        let emitter = Cache::open(d.path(), 1 << 30).unwrap();
        emitter.put_declared("eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee", "declared").unwrap();

        assert!(slot.temp_path().exists(), "the emitter swept an in-flight slot");
        slot.commit().unwrap();
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
    fn eviction_announces_before_it_deletes() {
        // The ordering a seeding transport depends on: it must be told to stop
        // serving a file while that file still exists.
        use std::sync::Mutex;
        let d = tempfile::tempdir().unwrap();
        let c = Cache::new(d.path(), 10).unwrap();
        let slot = c.slot(&digest(4)).unwrap();
        fs::write(slot.temp_path(), vec![0u8; 4096]).unwrap();
        let path = slot.commit().unwrap();

        let seen: Mutex<Vec<(String, bool)>> = Mutex::new(Vec::new());
        c.evict_with(&|dg| {
            seen.lock().unwrap().push((dg.to_nix32(), path.exists()));
        })
        .unwrap();

        let seen = seen.into_inner().unwrap();
        assert_eq!(seen.len(), 1, "callback not invoked");
        assert_eq!(seen[0].0, digest(4).to_nix32(), "wrong artifact announced");
        assert!(seen[0].1, "the file was already gone when the callback ran");
        assert!(!path.exists(), "eviction did not actually delete");
    }

    #[test]
    fn digest_of_ignores_files_that_are_not_ours() {
        assert!(Cache::digest_of(Path::new("/x/README")).is_none());
        assert!(Cache::digest_of(Path::new("/x/short.nar")).is_none());
        assert_eq!(
            Cache::digest_of(Path::new(&format!("/x/{}.nar", digest(5).to_nix32()))),
            Some(digest(5))
        );
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
