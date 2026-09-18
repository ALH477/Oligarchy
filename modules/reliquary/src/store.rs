use std::path::{Path, PathBuf};

use serde_json::Value;

use crate::archive;
use crate::config::Config;
use crate::error::{Error, Result};
use crate::hashing;
use crate::manifest;
use crate::parity;

pub struct Store {
    pub cfg: Config,
}

impl Store {
    pub fn new(cfg: Config) -> Result<Self> {
        cfg.ensure_dirs();
        if !cfg.catalog_path().exists() {
            manifest::write_json(&cfg.catalog_path(), &manifest::empty_catalog())?;
        }
        Ok(Self { cfg })
    }

    pub fn catalog(&self) -> Result<Value> {
        manifest::read_json(&self.cfg.catalog_path())
    }

    fn save_catalog(&self, mut cat: Value) -> Result<()> {
        cat["updated"] = Value::String(manifest::utcnow());
        manifest::write_json(&self.cfg.catalog_path(), &cat)
    }

    pub fn block_dir(&self, block_id: &str) -> PathBuf {
        self.cfg.blocks().join(block_id)
    }

    pub fn load_manifest(&self, block_id: &str) -> Result<Value> {
        validate_block_id(block_id)?;
        let path = self.block_dir(block_id).join("manifest.json");
        if !path.exists() {
            return Err(Error::UnknownBlock(block_id.into()));
        }
        manifest::read_json(&path)
    }

    pub fn list_blocks(&self) -> Result<Vec<Value>> {
        let mut rows = Vec::new();
        let blocks = self.cfg.blocks();
        if !blocks.exists() {
            return Ok(rows);
        }
        let mut names: Vec<_> = std::fs::read_dir(&blocks)?
            .flatten()
            .map(|e| e.path())
            .collect();
        names.sort();
        for child in names {
            let man = child.join("manifest.json");
            if man.exists() {
                rows.push(manifest::read_json(&man)?);
            }
        }
        Ok(rows)
    }

    pub fn ingest(&self, source: &Path, profile: &str, notes: &str, force: bool) -> Result<Value> {
        let source = if source.exists() {
            source.canonicalize()?
        } else {
            return Err(Error::MissingSource(source.to_path_buf()));
        };

        let work = self.cfg.work_root.join("ingest");
        crate::util::remove_dir_if_exists(&work)?;
        std::fs::create_dir_all(&work)?;

        let payload_tmp = work.join("payload.tar.zst");
        let packed = archive::pack_tree(&source, &payload_tmp, self.cfg.zstd_level)?;

        if profile == "cd" {
            let budget = (self.cfg.cd_capacity_bytes as f64 * 0.92) as u64;
            let expected = packed.bytes
                + packed.bytes * u64::from(self.cfg.par2_redundancy) / 100
                + 2 * 1024 * 1024;
            if expected > budget && !force {
                let _ = std::fs::remove_dir_all(&work);
                return Err(Error::store(format!(
                    "packed payload {} B plus {}% PAR2 will not fit an 80-minute CD-R (~{} B usable). Split the source, use --profile usb, or pass --force.",
                    packed.bytes, self.cfg.par2_redundancy, budget
                )));
            }
        }

        let block_id = format!(
            "{}-{}",
            chrono::Utc::now().format("%Y%m%d"),
            &packed.sha256[..16]
        );
        let dest = self.block_dir(&block_id);
        if dest.exists() {
            let _ = std::fs::remove_dir_all(&work);
            return self.load_manifest(&block_id);
        }
        std::fs::create_dir_all(&dest)?;
        let payload = dest.join("payload.tar.zst");
        std::fs::rename(&payload_tmp, &payload)?;

        let par = parity::create_par2(&payload, self.cfg.par2_redundancy, self.cfg.par2_volumes)?;

        // Hash only immutable payload + PAR2. Manifest and copies.json are
        // allowed to gain provenance later; including them in SHA256SUMS made
        // every USB push fail verification.
        write_payload_sums(&dest, &payload)?;

        let payload_json = serde_json::to_value(&packed)?;
        let par_json = serde_json::to_value(&par)?;
        let man = manifest::new_block_manifest(
            &block_id,
            &source.to_string_lossy(),
            payload_json,
            par_json,
            profile,
            notes,
        );
        manifest::write_json(&dest.join("manifest.json"), &man)?;
        manifest::write_json(&dest.join("copies.json"), &serde_json::json!([]))?;

        let mut cat = self.catalog()?;
        let blocks = cat
            .get_mut("blocks")
            .and_then(|v| v.as_array_mut())
            .cloned()
            .unwrap_or_default();
        let blocks: Vec<Value> = blocks
            .into_iter()
            .filter(|b| b.get("id").and_then(|v| v.as_str()) != Some(&block_id))
            .collect();
        cat["blocks"] = Value::Array(blocks);
        if let Some(arr) = cat.get_mut("blocks").and_then(|v| v.as_array_mut()) {
            arr.push(serde_json::json!({
                "id": block_id,
                "created": man.get("created"),
                "origin": man.get("origin"),
                "profile": profile,
                "payload_bytes": packed.bytes,
                "sha256": packed.sha256,
            }));
        }
        self.save_catalog(cat)?;
        let _ = std::fs::remove_dir_all(&work);
        Ok(man)
    }

    pub fn verify(&self, block_id: &str, repair: bool) -> Result<Value> {
        validate_block_id(block_id)?;
        let dest = self.block_dir(block_id);
        if !dest.exists() {
            return Err(Error::UnknownBlock(block_id.into()));
        }
        let mut problems = hashing::verify_sum_file(&dest, "SHA256SUMS")?;
        problems.extend(hashing::verify_sum_file(&dest, "SHA512SUMS")?);
        let index = dest.join("payload.tar.zst.par2");
        let mut par = serde_json::json!({"ok": false, "output": "missing PAR2 index"});
        if index.exists() {
            let mut result = parity::verify_par2(&index)?;
            if !result.ok && repair {
                result = parity::repair_par2(&index)?;
                if result.ok {
                    result = parity::verify_par2(&index)?;
                }
            }
            par = serde_json::to_value(result)?;
        }
        let ok = problems.is_empty() && par.get("ok").and_then(|v| v.as_bool()).unwrap_or(false);
        Ok(serde_json::json!({
            "id": block_id,
            "ok": ok,
            "checksum_problems": problems,
            "par2": par,
        }))
    }

    pub fn extract(&self, block_id: &str, dest: &Path, verify_first: bool) -> Result<PathBuf> {
        validate_block_id(block_id)?;
        if verify_first {
            let result = self.verify(block_id, false)?;
            if result.get("ok") != Some(&Value::Bool(true)) {
                return Err(Error::store(format!(
                    "block {block_id} failed verification: {result}"
                )));
            }
        }
        // Refuse a destination that already holds anything. extract_payload's
        // tar-slip check only sees one archive at a time: a first extract can
        // leave a symlink member behind (its own path has no `..`, so it
        // passes), and a second extract into the same dest writes THROUGH that
        // symlink to somewhere outside dest, because tar follows a symlink
        // already sitting at the target. A fresh directory per extract is the
        // only way to close that across two archives.
        if dest.exists() && std::fs::read_dir(dest)?.next().is_some() {
            return Err(Error::store(format!(
                "destination {} is not empty; extract into a fresh, empty directory \
                 (a second extract into a populated directory can be made to follow \
                 a symlink planted by the first)",
                dest.display()
            )));
        }
        std::fs::create_dir_all(dest)?;
        archive::extract_payload(&self.block_dir(block_id).join("payload.tar.zst"), dest)?;
        Ok(dest.to_path_buf())
    }

    pub fn copy_block(&self, block_id: &str, dest_dir: &Path, medium: &str) -> Result<PathBuf> {
        validate_block_id(block_id)?;
        let src = self.block_dir(block_id);
        if !src.exists() {
            return Err(Error::UnknownBlock(block_id.into()));
        }
        std::fs::create_dir_all(dest_dir)?;
        let target = dest_dir.join(block_id);
        crate::util::remove_dir_if_exists(&target)?;
        crate::util::copy_dir_all(&src, &target)?;
        append_copy(&src.join("copies.json"), medium, &target)?;
        append_copy(&target.join("copies.json"), medium, &target)?;
        Ok(target)
    }
}

pub fn validate_block_id(block_id: &str) -> Result<()> {
    let mut parts = block_id.split('-');
    let date = parts.next().unwrap_or("");
    let hex = parts.next().unwrap_or("");
    let ok = parts.next().is_none()
        && date.len() == 8
        && date.bytes().all(|b| b.is_ascii_digit())
        && hex.len() == 16
        && hex.bytes().all(|b| b.is_ascii_hexdigit());
    if ok {
        Ok(())
    } else {
        Err(Error::store(format!(
            "invalid block id {block_id:?}: expected YYYYMMDD- plus 16 hex chars"
        )))
    }
}

fn write_payload_sums(dest: &Path, payload: &Path) -> Result<()> {
    let mut files = vec![payload.to_path_buf()];
    if let Ok(rd) = std::fs::read_dir(dest) {
        for e in rd.flatten() {
            let p = e.path();
            if p.extension().and_then(|s| s.to_str()) == Some("par2") {
                files.push(p);
            }
        }
    }
    files.sort();
    files.dedup();
    hashing::write_sum_files(dest, &files)
}

fn append_copy(path: &Path, medium: &str, location: &Path) -> Result<()> {
    let mut copies = if path.exists() {
        manifest::read_json(path)?
    } else {
        serde_json::json!([])
    };
    if !copies.is_array() {
        copies = serde_json::json!([]);
    }
    if let Some(arr) = copies.as_array_mut() {
        arr.push(serde_json::json!({
            "medium": medium,
            "location": location.display().to_string(),
            "at": manifest::utcnow(),
        }));
    }
    manifest::write_json(path, &copies)
}
