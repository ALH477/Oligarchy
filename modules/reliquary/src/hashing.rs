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
    let mut parsed_any = false;
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
        parsed_any = true;
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
    // A sums file that yielded no entry at all is itself the failure. Empty,
    // all-comments, truncated to zero by a failed USB write, or separated by
    // something other than the two spellings above — every one of those used to
    // return no problems, and `store::verify` reports a block as verified when
    // `problems.is_empty() && par.ok`. That silently demoted the independent
    // checksum leg to "par2 said yes", which is exactly the single point of
    // failure carrying two hash files is meant to avoid.
    if !parsed_any {
        problems.push(format!("{name}: no parseable entries"));
    }
    Ok(problems)
}

#[allow(dead_code)]
pub fn write_text(path: &Path, text: &str) -> Result<()> {
    let mut f = File::create(path)?;
    f.write_all(text.as_bytes())?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn tmpdir(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!(
            "reliquary-hashing-{tag}-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    /// The regression: a sums file that parsed to zero entries returned zero
    /// problems, and `store::verify` reports a block verified when
    /// `problems.is_empty() && par.ok`. That quietly reduced two independent
    /// integrity legs to one.
    #[test]
    fn a_sums_file_with_no_parseable_entries_is_itself_a_problem() {
        let d = tmpdir("empty");
        for (name, body) in [
            ("SHA256SUMS", ""),
            ("SHA512SUMS", "# only a comment\n\n"),
            // Single-space and tab separators are neither of the two accepted
            // spellings, so every line falls through the parser.
            ("SHA256SUMS.alt", "abc payload.tar.zst\n"),
        ] {
            std::fs::write(d.join(name), body).unwrap();
            let problems = verify_sum_file(&d, name).unwrap();
            assert!(
                problems.iter().any(|p| p.contains("no parseable entries")),
                "{name} with body {body:?} should be refused, got {problems:?}"
            );
        }
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn a_missing_sums_file_is_still_reported_as_missing() {
        let d = tmpdir("missing");
        let problems = verify_sum_file(&d, "SHA256SUMS").unwrap();
        assert_eq!(problems, vec!["missing SHA256SUMS".to_string()]);
        let _ = std::fs::remove_dir_all(&d);
    }

    /// A well-formed file that verifies must still report nothing — the new
    /// check must not turn every success into a problem.
    #[test]
    fn a_good_sums_file_reports_no_problems() {
        let d = tmpdir("good");
        std::fs::write(d.join("payload.bin"), b"hello reliquary").unwrap();
        let got = hash_file(&d.join("payload.bin")).unwrap();
        std::fs::write(
            d.join("SHA256SUMS"),
            format!("{}  payload.bin\n", got.sha256),
        )
        .unwrap();
        assert!(verify_sum_file(&d, "SHA256SUMS").unwrap().is_empty());
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn a_traversing_filename_is_refused_and_still_counts_as_parsed() {
        let d = tmpdir("traversal");
        std::fs::write(d.join("SHA256SUMS"), "deadbeef  ../../etc/shadow\n").unwrap();
        let problems = verify_sum_file(&d, "SHA256SUMS").unwrap();
        assert!(problems.iter().any(|p| p.contains("invalid filename")));
        assert!(
            !problems.iter().any(|p| p.contains("no parseable entries")),
            "a refused filename is a parsed line, not an unparseable one: {problems:?}"
        );
        let _ = std::fs::remove_dir_all(&d);
    }
}
