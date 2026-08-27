//! Serving a NAR we already have, straight out of the local Nix store.
//!
//! `nix-store --dump` rather than `nix store dump-path` on purpose: the old CLI
//! serialises a directory and consults nothing else, so this needs no access to
//! the Nix database and no connection to `nix-daemon`. That in turn is why the
//! unit's `RestrictAddressFamilies` can stay `AF_INET AF_INET6` with no
//! `AF_UNIX` — an unprivileged daemon that never talks to the daemon socket
//! cannot be tricked into asking it for anything.
//!
//! We also never ask whether the path is *valid*. We do not have to: the output
//! is hashed against the signed `NarHash` like every other source. A path that
//! is present-but-invalid — the debris a failed substitution leaves behind,
//! which Stage 0 spike 6 confirmed really does get left on disk — simply fails
//! the digest and falls through. Verifying is cheaper than asking, and it
//! answers the question that actually matters.

use anyhow::{bail, Context, Result};
use std::path::Path;
use std::process::{Child, ChildStdout, Command, Stdio};

pub struct Dump {
    child: Child,
}

impl Dump {
    pub fn stdout(&mut self) -> Option<ChildStdout> {
        self.child.stdout.take()
    }

    /// Reap the child and report whether it succeeded. A non-zero exit means
    /// the bytes are incomplete even if they happened to hash correctly, which
    /// cannot happen, but saying so costs nothing.
    pub fn finish(mut self) -> Result<()> {
        let status = self.child.wait().context("waiting for nix-store --dump")?;
        if !status.success() {
            bail!("nix-store --dump exited with {status}");
        }
        Ok(())
    }
}

impl Drop for Dump {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// Does this look like a path in our store that we could dump?
///
/// The store path comes from a narinfo, which came from an upstream cache, so
/// it is attacker-influenced in exactly the same way everything else is. It is
/// about to become an argument to a subprocess, so it gets checked rather than
/// trusted: it must sit directly under the configured store directory, and it
/// must not try to climb out of it.
pub fn is_dumpable(store_dir: &str, store_path: &str) -> bool {
    let Some(rest) = store_path.strip_prefix(store_dir) else {
        return false;
    };
    let Some(name) = rest.strip_prefix('/') else {
        return false;
    };
    !name.is_empty()
        && !name.contains('/')
        && name != "."
        && name != ".."
        && !name.contains('\0')
}

/// Start dumping a store path. The caller streams and verifies stdout.
pub fn dump(store_dir: &str, store_path: &str) -> Result<Option<Dump>> {
    if !is_dumpable(store_dir, store_path) {
        bail!("refusing to dump {store_path:?}: not a direct child of {store_dir:?}");
    }
    if !Path::new(store_path).exists() {
        return Ok(None);
    }
    let child = Command::new("nix-store")
        .arg("--dump")
        .arg(store_path)
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .stdin(Stdio::null())
        .spawn()
        .context("spawning nix-store --dump (is nix on the unit's PATH?)")?;
    Ok(Some(Dump { child }))
}

#[cfg(test)]
mod tests {
    use super::*;

    const SD: &str = "/nix/store";

    #[test]
    fn accepts_a_normal_store_path() {
        assert!(is_dumpable(SD, "/nix/store/lcxc2z1h2g8wq8dxfpizy1di85kyxnqx-hello-2.12.3"));
    }

    #[test]
    fn refuses_anything_that_is_not_a_direct_child_of_the_store() {
        // This string reaches a subprocess argument, so it is checked rather
        // than trusted — it arrived in a narinfo from an upstream cache.
        for bad in [
            "/etc/passwd",
            "/nix/store",
            "/nix/store/",
            "/nix/store/..",
            "/nix/store/../etc",
            "/nix/store/foo/bar",
            "/nix/storeee/foo",
            "relative-path",
            "",
        ] {
            assert!(!is_dumpable(SD, bad), "accepted {bad:?}");
        }
    }

    #[test]
    fn refuses_an_embedded_nul() {
        assert!(!is_dumpable(SD, "/nix/store/foo\0bar"));
    }

    #[test]
    fn a_missing_path_is_a_miss_not_an_error() {
        // Falling through to the next source is the correct response; an error
        // here would turn "we do not have it" into a 404 storm.
        let r = dump(SD, "/nix/store/00000000000000000000000000000000-nope").unwrap();
        assert!(r.is_none());
    }

    #[test]
    fn a_path_outside_the_store_is_an_error_not_a_miss() {
        // The distinction matters: a miss is normal, an attempt to escape the
        // store is a thing to log loudly.
        assert!(dump(SD, "/etc/passwd").is_err());
    }
}
