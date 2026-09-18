use std::fs::File;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use walkdir::WalkDir;

use crate::error::{Error, Result};
use crate::util::require_tool;

#[derive(Debug, Clone, serde::Serialize)]
pub struct Packed {
    pub file: String,
    pub bytes: u64,
    pub tar_entries: usize,
    pub uncompressed_bytes: u64,
    pub source_name: String,
    pub sha256: String,
    pub sha512: String,
}

pub fn pack_tree(source: &Path, dest_tar_zst: &Path, zstd_level: u8) -> Result<Packed> {
    let source = source.canonicalize()?;
    let tar = require_tool("tar")?;
    let zstd = require_tool("zstd")?;
    let parent = source.parent().unwrap_or_else(|| Path::new("."));
    let name = source
        .file_name()
        .ok_or_else(|| Error::store("source has no file name"))?
        .to_string_lossy()
        .into_owned();

    if let Some(p) = dest_tar_zst.parent() {
        std::fs::create_dir_all(p)?;
    }
    let tmp = dest_tar_zst.with_extension("zst.partial");
    let dest_file = File::create(&tmp)?;

    let mut tar_child = Command::new(&tar)
        .args([
            "--sort=name",
            "--mtime=UTC 1970-01-01",
            "--owner=0",
            "--group=0",
            "--numeric-owner",
            "-C",
        ])
        .arg(parent)
        .args(["-cf", "-", "--", &name])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?;

    let tar_stdout = tar_child
        .stdout
        .take()
        .ok_or_else(|| Error::store("tar produced no stdout"))?;

    let level = format!("-{zstd_level}");
    let mut zstd_child = Command::new(&zstd)
        .args([&level, "-T0"])
        .stdin(Stdio::from(tar_stdout))
        .stdout(Stdio::from(dest_file))
        .stderr(Stdio::piped())
        .spawn()?;

    let zstd_status = zstd_child.wait()?;
    let tar_status = tar_child.wait()?;
    if !tar_status.success() || !zstd_status.success() {
        let _ = std::fs::remove_file(&tmp);
        return Err(Error::store(format!(
            "tar|zstd failed (tar={} zstd={})",
            tar_status.code().unwrap_or(-1),
            zstd_status.code().unwrap_or(-1)
        )));
    }
    std::fs::rename(&tmp, dest_tar_zst)?;

    let listing = crate::util::run(&[&tar, "-tf", &dest_tar_zst.to_string_lossy()], None)?;
    let entries = String::from_utf8_lossy(&listing.stdout)
        .lines()
        .filter(|l| !l.is_empty())
        .count();
    let uncompressed = estimate_uncompressed(dest_tar_zst);
    let digests = crate::hashing::hash_file(dest_tar_zst)?;
    Ok(Packed {
        file: dest_tar_zst
            .file_name()
            .unwrap()
            .to_string_lossy()
            .into_owned(),
        bytes: dest_tar_zst.metadata()?.len(),
        tar_entries: entries,
        uncompressed_bytes: uncompressed,
        source_name: name,
        sha256: digests.sha256,
        sha512: digests.sha512,
    })
}

pub fn extract_payload(payload: &Path, dest_dir: &Path) -> Result<()> {
    std::fs::create_dir_all(dest_dir)?;
    let tar = require_tool("tar")?;
    let listing = crate::util::run(&[&tar, "-tf", &payload.to_string_lossy()], None)?;
    for line in String::from_utf8_lossy(&listing.stdout).lines() {
        if line.is_empty() {
            continue;
        }
        if line.starts_with('/') || line.starts_with('\\') {
            return Err(Error::store(format!(
                "refusing to extract archive with absolute path {line:?}"
            )));
        }
        for part in line.split(['/', '\\']) {
            if part == ".." {
                return Err(Error::store(format!(
                    "refusing to extract archive with parent path {line:?}"
                )));
            }
        }
    }
    crate::util::run(
        &[
            &tar,
            "--no-same-owner",
            "--no-same-permissions",
            "-C",
            &dest_dir.to_string_lossy(),
            "-xf",
            &payload.to_string_lossy(),
        ],
        None,
    )?;
    Ok(())
}

fn estimate_uncompressed(payload: &Path) -> u64 {
    let zstd = match require_tool("zstd") {
        Ok(p) => p,
        Err(_) => return 0,
    };
    let out = match crate::util::run_unchecked(&[&zstd, "-l", &payload.to_string_lossy()], None) {
        Ok(o) => o,
        Err(_) => return 0,
    };
    if !out.status.success() {
        return 0;
    }
    for line in String::from_utf8_lossy(&out.stdout).lines().skip(1) {
        let parts: Vec<&str> = line.split_whitespace().collect();
        if parts.len() >= 5 {
            if let Ok(n) = parts[4].replace(',', "").parse() {
                return n;
            }
        }
    }
    0
}

pub fn tree_bytes(path: &Path) -> u64 {
    if path.is_file() {
        return path.metadata().map(|m| m.len()).unwrap_or(0);
    }
    let mut total = 0u64;
    for entry in WalkDir::new(path).into_iter().flatten() {
        if entry.file_type().is_file() {
            if let Ok(m) = entry.metadata() {
                total += m.len();
            }
        }
    }
    total
}

#[allow(dead_code)]
pub fn dummy_path() -> PathBuf {
    PathBuf::from(".")
}
