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

/// Run the decompressed payload through `crate::arca`'s judge before tar sees
/// a byte of it. `Ok` only if every member is a regular file or directory with
/// a safe name, in GNU tar's own format.
///
/// Two passes on purpose: tar extracts as it reads, so a judge riding the same
/// stream would see a device node only after root had made it. The payload
/// sits in the root-owned store (0750) between the passes.
pub fn judge_payload(payload: &Path) -> Result<Vec<crate::arca::Member>> {
    let zstd = require_tool("zstd")?;
    let mut child = Command::new(&zstd)
        .args(["-dc", "--"])
        .arg(payload)
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()?;
    let out = child
        .stdout
        .take()
        .ok_or_else(|| Error::store("zstd produced no stdout"))?;
    let verdict = crate::arca::judge(out);
    if verdict.is_err() {
        let _ = child.kill();
    }
    let status = child.wait()?;
    let members = verdict?;
    if !status.success() {
        return Err(Error::store(format!(
            "zstd -dc failed on {} (exit {})",
            payload.display(),
            status.code().unwrap_or(-1)
        )));
    }
    Ok(members)
}

pub fn extract_payload(payload: &Path, dest_dir: &Path) -> Result<()> {
    // Judge first, before anything is created -- including dest_dir.
    judge_payload(payload)?;
    std::fs::create_dir_all(dest_dir)?;
    let tar = require_tool("tar")?;
    // The name check below predates the judge and is now redundant with it
    // (the judge refuses absolute names and '..' too). It stays as a second,
    // independent reading of the same archive: it reads tar's OWN listing,
    // so it is a check on the judge as much as on the archive.
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

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!(
            "reliquary-archive-{tag}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    /// One GNU-format header, checksummed the way GNU tar writes it.
    fn header(name: &str, typ: u8, size: u64, link: &str) -> [u8; 512] {
        let mut h = [0u8; 512];
        h[..name.len()].copy_from_slice(name.as_bytes());
        h[100..108].copy_from_slice(b"0000644\0");
        h[108..116].copy_from_slice(b"0000000\0");
        h[116..124].copy_from_slice(b"0000000\0");
        h[124..136].copy_from_slice(format!("{size:011o}\0").as_bytes());
        h[136..148].copy_from_slice(b"00000000000\0");
        h[156] = typ;
        h[157..157 + link.len()].copy_from_slice(link.as_bytes());
        h[257..265].copy_from_slice(b"ustar  \0");
        h[148..156].copy_from_slice(b"        ");
        let sum: u32 = h.iter().map(|&b| b as u32).sum();
        h[148..156].copy_from_slice(format!("{sum:06o}\0 ").as_bytes());
        h
    }

    fn zstd_to(path: &Path, tar: &[u8]) {
        use std::io::Write;
        let mut c = Command::new(require_tool("zstd").unwrap())
            .args(["-q", "-c"])
            .stdin(Stdio::piped())
            .stdout(Stdio::from(File::create(path).unwrap()))
            .spawn()
            .unwrap();
        c.stdin.take().unwrap().write_all(tar).unwrap();
        assert!(c.wait().unwrap().success());
    }

    /// reliquary's own output passes the judge, and the judge lists exactly
    /// the members tar does -- then extraction proceeds as before.
    #[test]
    fn a_packed_tree_is_admitted_and_extracts() {
        let d = scratch("good");
        let src = d.join("keep");
        std::fs::create_dir_all(src.join("sub")).unwrap();
        std::fs::write(src.join("a.txt"), b"hello").unwrap();
        std::fs::write(src.join("sub").join("n".repeat(150)), b"long name").unwrap();
        let payload = d.join("payload.tar.zst");
        pack_tree(&src, &payload, 3).unwrap();

        let members = judge_payload(&payload).unwrap();
        let listing = crate::util::run(&["tar", "-tf", &payload.to_string_lossy()], None).unwrap();
        let tar_names: Vec<&[u8]> = listing
            .stdout
            .split(|&b| b == b'\n')
            .filter(|l| !l.is_empty())
            .collect();
        let judged: Vec<&[u8]> = members.iter().map(|m| m.name.as_slice()).collect();
        assert_eq!(judged, tar_names);
        assert!(members.iter().any(|m| m.dir) && members.iter().any(|m| !m.dir));

        let out = d.join("out");
        extract_payload(&payload, &out).unwrap();
        assert_eq!(std::fs::read(out.join("keep/a.txt")).unwrap(), b"hello");
        let _ = std::fs::remove_dir_all(&d);
    }

    /// The measured attack: a payload whose members are a block device and a
    /// symlink to /etc/shadow. Refused before tar runs, so nothing is created
    /// -- not even the destination directory.
    #[test]
    fn a_device_or_symlink_payload_is_refused_before_anything_is_created() {
        for (what, typ, link) in [
            ("block device", b'4', ""),
            ("symlink", b'2', "/etc/shadow"),
            ("fifo", b'6', ""),
        ] {
            let d = scratch("evil");
            let mut tar = Vec::new();
            tar.extend_from_slice(&header("evil/", b'5', 0, ""));
            tar.extend_from_slice(&header("evil/x", typ, 0, link));
            tar.extend_from_slice(&[0u8; 1024]);
            let payload = d.join("payload.tar.zst");
            zstd_to(&payload, &tar);
            let out = d.join("out");
            let err = extract_payload(&payload, &out).expect_err(what).to_string();
            assert!(err.contains("arca verdict 18"), "{what}: {err}");
            assert!(
                !out.exists(),
                "{what}: destination was created before the refusal"
            );
            let _ = std::fs::remove_dir_all(&d);
        }
    }

    /// The judge's refusals the old name check also made, plus one it could
    /// not: data hidden after the end block.
    #[test]
    fn names_and_trailing_data_are_judged_too() {
        let cases: Vec<(&str, Vec<u8>, &str)> = vec![
            (
                "dot-dot",
                [header("a/../../x", b'0', 0, ""), [0u8; 512], [0u8; 512]].concat(),
                "verdict 21",
            ),
            (
                "absolute",
                [header("/etc/x", b'0', 0, ""), [0u8; 512], [0u8; 512]].concat(),
                "verdict 20",
            ),
            (
                "after end",
                [header("f", b'0', 0, ""), [0u8; 512], [0u8; 512], [7u8; 512]].concat(),
                "data after its end block",
            ),
        ];
        for (what, tar, want) in cases {
            let d = scratch("names");
            let payload = d.join("payload.tar.zst");
            zstd_to(&payload, &tar);
            let err = judge_payload(&payload).expect_err(what).to_string();
            assert!(err.contains(want), "{what}: {err}");
            let _ = std::fs::remove_dir_all(&d);
        }
    }
}
