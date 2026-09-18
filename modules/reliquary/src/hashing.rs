use std::fs::File;
use std::io::{BufRead, BufReader, Read, Write};
use std::path::Path;

use sha2::{Digest, Sha256, Sha512};

use crate::error::Result;

const CHUNK: usize = 1024 * 1024;

#[derive(Debug, Clone)]
pub struct Digests {
    pub sha256: String,
    pub sha512: String,
}

pub fn hash_file(path: &Path) -> Result<Digests> {
    let mut sha256 = Sha256::new();
    let mut sha512 = Sha512::new();
    let mut f = File::open(path)?;
    let mut buf = vec![0u8; CHUNK];
    loop {
        let n = f.read(&mut buf)?;
        if n == 0 {
            break;
        }
        sha256.update(&buf[..n]);
        sha512.update(&buf[..n]);
    }
    Ok(Digests {
        sha256: hex::encode(sha256.finalize()),
        sha512: hex::encode(sha512.finalize()),
    })
}

pub fn write_sum_files(directory: &Path, files: &[std::path::PathBuf]) -> Result<()> {
    let mut lines256 = String::new();
    let mut lines512 = String::new();
    for f in files {
        let d = hash_file(f)?;
        let name = f.file_name().unwrap().to_string_lossy();
        lines256.push_str(&format!("{}  {}\n", d.sha256, name));
        lines512.push_str(&format!("{}  {}\n", d.sha512, name));
    }
    std::fs::write(directory.join("SHA256SUMS"), lines256)?;
    std::fs::write(directory.join("SHA512SUMS"), lines512)?;
    Ok(())
}

pub fn verify_sum_file(directory: &Path, name: &str) -> Result<Vec<String>> {
    let sums = directory.join(name);
    if !sums.exists() {
        return Ok(vec![format!("missing {name}")]);
    }
    let algo256 = name.contains("256");
    let mut problems = Vec::new();
    let f = File::open(&sums)?;
    for line in BufReader::new(f).lines() {
        let line = line?;
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let (digest, filename) = if let Some((d, n)) = line.split_once("  ") {
            (d, n)
        } else if let Some((d, n)) = line.split_once(" *") {
            (d, n)
        } else {
            continue;
        };
        // The sums file may have arrived from an untrusted medium (usb::pull_block
        // copies a whole block directory in before anything is verified), so the
        // filename is attacker data. write_sum_files only ever emits bare
        // file_name()s, so refusing anything with a separator costs nothing and
        // stops `<hash>  ../../../etc/shadow` turning verify into a read/existence
        // oracle over the whole filesystem. Unix-only crate, so `/` is the only
        // separator to worry about.
        if filename.is_empty() || filename.contains('/') || filename == ".." || filename == "." {
            problems.push(format!("{filename}: invalid filename in sums file"));
            continue;
        }
        let target = directory.join(filename);
        if !target.exists() {
            problems.push(format!("{filename}: missing"));
            continue;
        }
        let got = hash_file(&target)?;
        let actual = if algo256 { &got.sha256 } else { &got.sha512 };
        if actual != digest {
            problems.push(format!(
                "{filename}: {} mismatch",
                if algo256 { "sha256" } else { "sha512" }
            ));
        }
    }
    Ok(problems)
}

#[allow(dead_code)]
pub fn write_text(path: &Path, text: &str) -> Result<()> {
    let mut f = File::create(path)?;
    f.write_all(text.as_bytes())?;
    Ok(())
}
