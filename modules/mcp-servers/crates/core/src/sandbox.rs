//! Sandboxed file reads confined to `FLAKE_DIR`.
//!
//! Ports the legacy Python `read_module` parent-check: a requested path is
//! resolved canonical-relative to `FLAKE_DIR`, and the call is refused if the
//! resolved target is not `FLAKE_DIR` itself or one of its descendants.

use std::path::{Path, PathBuf};

use crate::error::{Error, Result};

/// Returns the resolved flake directory: `OLIGARCHY_FLAKE_DIR` env if set,
/// else the current working dir if it contains `flake.nix`, else
/// `/etc/nixos`.
pub fn flake_dir() -> PathBuf {
    if let Ok(env) = std::env::var("OLIGARCHY_FLAKE_DIR") {
        return PathBuf::from(env.clone())
            .canonicalize()
            .unwrap_or_else(|_| PathBuf::from(env));
    }
    let cwd = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
    if cwd.join("flake.nix").is_file() {
        return cwd.canonicalize().unwrap_or(cwd);
    }
    PathBuf::from("/etc/nixos")
}

/// Resolves `rel` against `base` and confirms the target is `base` itself or
/// a descendant. Returns the resolved path on success.
pub fn resolve_within(base: &Path, rel: &str) -> Result<PathBuf> {
    let target = base.join(rel).canonicalize().map_err(|e| {
        Error::Io(std::io::Error::new(
            e.kind(),
            format!("resolving {}: {}", base.join(rel).display(), e),
        ))
    })?;
    if target == base {
        return Ok(target);
    }
    if !target.starts_with(base) {
        return Err(Error::PathEscape(rel.to_string()));
    }
    Ok(target)
}

/// Reads a file under `base`, refusing paths that escape. Truncates at
/// `max_bytes` and returns the contents plus a trailing marker if truncated.
pub fn read_file(base: &Path, rel: &str, max_bytes: usize) -> Result<String> {
    let target = resolve_within(base, rel)?;
    if !target.is_file() {
        return Err(Error::NotAFile(rel.to_string()));
    }
    let data = std::fs::read_to_string(&target)?;
    if data.len() > max_bytes {
        let mut s = data.into_bytes();
        s.truncate(max_bytes);
        let mut s = String::from_utf8(s).map_err(|e| Error::Io(std::io::Error::new(std::io::ErrorKind::InvalidData, e)))?;
        s.push_str("\n[... truncated ...]\n");
        Ok(s)
    } else {
        Ok(data)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn resolves_descendant() {
        let tmp = std::env::temp_dir().join("sed-test");
        let _ = fs::remove_dir_all(&tmp);
        fs::create_dir_all(tmp.join("sub")).unwrap();
        fs::write(tmp.join("sub/file.txt"), "hello").unwrap();
        let r = resolve_within(&tmp, "sub/file.txt").unwrap();
        assert!(r.ends_with("sub/file.txt"));
        let _ = fs::remove_dir_all(&tmp);
    }

    #[test]
    fn rejects_escape() {
        let tmp = std::env::temp_dir().join("sed-test-escape");
        let _ = fs::remove_dir_all(&tmp);
        fs::create_dir_all(&tmp).unwrap();
        fs::write(tmp.join("file.txt"), "ok").unwrap();
        // Symlink trick: link to a parent file, then try to read through it.
        #[cfg(unix)]
        {
            use std::os::unix::fs::symlink;
            let outside = std::env::temp_dir().join("sed-outside.marker");
            fs::write(&outside, "secret").unwrap();
            let _ = symlink(&outside, tmp.join("escape"));
            let res = resolve_within(&tmp, "escape");
            assert!(res.is_err());
        }
        let _ = fs::remove_dir_all(&tmp);
    }

    #[test]
    fn truncates_large_files() {
        let tmp = std::env::temp_dir().join("sed-trunc");
        let _ = fs::remove_dir_all(&tmp);
        fs::create_dir_all(&tmp).unwrap();
        let big = "x".repeat(1000);
        fs::write(tmp.join("big.txt"), &big).unwrap();
        let r = read_file(&tmp, "big.txt", 100).unwrap();
        assert!(r.ends_with("[... truncated ...]\n"));
        assert!(r.len() <= 200);
        let _ = fs::remove_dir_all(&tmp);
    }
}