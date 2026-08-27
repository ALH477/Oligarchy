//! Minting narinfo for paths this host **built**, so it can seed them.
//!
//! The problem this closes: the peer surface answers `GET /peer/v1/narinfo/`
//! only from what is on disk, and a receiver cannot verify a NAR without the
//! signed `NarHash` that lives in a narinfo. A path fetched from upstream has
//! one. **A locally-built path has one nowhere** — nothing ever resolved it —
//! so it could never be seeded. A machine that *substituted* a rebuild was a
//! good seeder and a machine that *compiled* it was useless, which is backwards
//! for a distro whose point is artifacts no public cache has.
//!
//! So: the operator declares packages in the flake, this host signs them, and
//! the result lands in the cache's non-evictable `declared/` tier. Every peer
//! route then works unmodified — they all gate on `Cache::get_narinfo`.
//!
//! **Nix does the crypto.** `nix store sign` produces the signature and
//! `nix path-info --sigs` reads it back, so the fingerprint format
//! (`ValidPathInfo::fingerprint`) is never reimplemented here and cannot drift
//! from what Nix will actually verify. That is why this file has no ed25519.
//!
//! **This is the one place the daemon's posture is not enough.** Minting needs
//! a signing key and the Nix database, and `oligarchy-p2pd daemon` is
//! deliberately allowed neither — its unit has no `AF_UNIX`, so it cannot even
//! open the nix-daemon socket. `seed` therefore runs from a *separate* root
//! oneshot. The network-facing process still holds no key; that split is the
//! whole mitigation, and dissolving it by moving this into the daemon would
//! hand a signing key to the process that parses hostile input.

use crate::cache::Cache;
use crate::narinfo::NarInfo;
use crate::nixhash::Sha256Digest;
use anyhow::{bail, Context, Result};
use serde::Deserialize;
use std::collections::BTreeMap;
use std::io::Write;
use std::path::Path;
use std::process::{Command, Stdio};

/// One entry of `nix path-info --json-format 1 --json --sigs`.
#[derive(Debug, Clone, Deserialize)]
pub struct PathInfo {
    #[serde(rename = "narHash")]
    pub nar_hash: String,
    #[serde(rename = "narSize")]
    pub nar_size: u64,
    #[serde(default)]
    pub references: Vec<String>,
    pub deriver: Option<String>,
    pub ca: Option<String>,
    #[serde(default)]
    pub signatures: Vec<String>,
}

/// What a seed run did, for the log line and for the tests.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Summary {
    pub published: usize,
    pub signed: usize,
    pub unpublished: usize,
    pub skipped: usize,
}

/// The key's name — the part before the colon, which is also the prefix every
/// signature it makes carries. `<name>:<base64>` is the format
/// `nix key generate-secret` writes.
pub fn key_name(secret: &str) -> Result<&str> {
    let (name, rest) = secret.trim_end().split_once(':').context(
        "malformed signing key: expected `<name>:<base64>`, as written by \
         `nix key generate-secret --key-name <name>`",
    )?;
    if name.is_empty() || rest.is_empty() {
        bail!("malformed signing key: empty name or key material");
    }
    Ok(name)
}

/// Refuse a key anyone but its owner can read.
///
/// Cheap, and it catches a real footgun: a signing key that leaked to the
/// `oligarchy-p2p` user would put it in reach of the network-facing daemon,
/// which is precisely the thing the separate-unit split exists to prevent.
pub fn check_key_mode(mode: u32, path: &Path) -> Result<()> {
    if mode & 0o077 != 0 {
        bail!(
            "signing key {} is mode {:04o}: readable beyond its owner. \
             `chmod 0400` it. A key the daemon's user can read defeats the \
             reason seeding runs in a separate unit.",
            path.display(),
            mode & 0o7777
        );
    }
    Ok(())
}

/// The 32-character hash part of a store path.
fn hash_part(store_path: &str) -> Result<&str> {
    let base = store_path.rsplit('/').next().unwrap_or(store_path);
    let hp = base.split_once('-').map(|(h, _)| h).unwrap_or(base);
    if hp.len() != 32 {
        bail!("{store_path} does not look like a store path");
    }
    Ok(hp)
}

/// `References:` and `Deriver:` are **basenames** in a narinfo, not paths.
/// cache.nixos.org emits them that way and Nix parses them that way; writing
/// full paths produces a narinfo that parses and then fails verification with
/// a fingerprint mismatch, which surfaces far from here.
fn basename(p: &str) -> &str {
    p.rsplit('/').next().unwrap_or(p)
}

/// Convert Nix's SRI `sha256-<base64>` to a narinfo's `sha256:<nix32>`.
fn to_narinfo_hash(sri: &str) -> Result<Sha256Digest> {
    let d = sri.strip_prefix("sha256-").unwrap_or(sri);
    Sha256Digest::parse_digest(d).with_context(|| format!("parsing narHash {sri:?}"))
}

/// Build the canonical narinfo text for a path we hold.
///
/// The transport fields are the adapter's canonical form and nothing else:
/// `Compression: none`, `FileHash = NarHash`, `FileSize = NarSize` and a URL
/// that is a pure function of signed data. There is no upstream here to
/// re-compress underneath us, but emitting the same shape the substituter
/// surface would rewrite to keeps one description of an artifact in the system
/// rather than two.
pub fn narinfo_text(store_path: &str, info: &PathInfo, key_name: &str) -> Result<String> {
    let hp = hash_part(store_path)?;
    let nar_hash = to_narinfo_hash(&info.nar_hash)?;
    if info.nar_size == 0 {
        bail!("{store_path} has NarSize 0");
    }

    // A path with no signature is one Nix will refuse, so publishing metadata
    // for it advertises something no peer can use. The exception is real:
    // a content-addressed path needs no signature at all —
    // `ValidPathInfo::checkSignatures` returns `maxSigs` immediately for one,
    // because its trust anchor is the store path name, which Nix recomputes.
    if info.signatures.is_empty() && info.ca.is_none() {
        bail!("{store_path} carries no signature and is not content-addressed");
    }

    let mut s = String::new();
    s.push_str(&format!("StorePath: {store_path}\n"));
    s.push_str(&format!("URL: nar/{hp}/{}.nar\n", nar_hash.to_nix32()));
    s.push_str("Compression: none\n");
    s.push_str(&format!("FileHash: {}\n", nar_hash.to_prefixed()));
    s.push_str(&format!("FileSize: {}\n", info.nar_size));
    s.push_str(&format!("NarHash: {}\n", nar_hash.to_prefixed()));
    s.push_str(&format!("NarSize: {}\n", info.nar_size));
    let refs: Vec<&str> = info.references.iter().map(|r| basename(r)).collect();
    s.push_str(&format!("References: {}\n", refs.join(" ")));
    if let Some(d) = &info.deriver {
        s.push_str(&format!("Deriver: {}\n", basename(d)));
    }
    if let Some(ca) = &info.ca {
        s.push_str(&format!("CA: {ca}\n"));
    }
    for sig in &info.signatures {
        s.push_str(&format!("Sig: {sig}\n"));
    }

    // Self-checks. `NarInfo::parse` is necessary and nowhere near sufficient:
    // it validates StorePath, NarHash, a non-empty URL and a non-zero NarSize,
    // and nothing about whether this file is coherent with its own name or
    // usable by anyone. Each check below is a silent, permanent failure if it
    // is wrong, so each is checked here where the mistake is.
    let ni = NarInfo::parse(&s).with_context(|| format!("minted narinfo for {store_path}"))?;

    // (1) The filename is the lookup key; `route::nar_url` derives the hash
    //     part from StorePath instead. If they disagree, `http::nar`'s
    //     anti-open-proxy check rejects our own artifact forever.
    if ni.hash_part() != hp {
        bail!("minted narinfo for {store_path} has hash part {} but is filed under {hp}", ni.hash_part());
    }
    // (2) The URL we wrote must be the URL the daemon will re-derive.
    let derived = crate::route::nar_url(&ni);
    if ni.url() != derived {
        bail!("minted URL {:?} does not match the derived {derived:?}", ni.url());
    }
    // (3) A signature by somebody else does not make this path servable by us.
    //     A CA path is the documented exception — its anchor is the store path
    //     name, which Nix recomputes.
    if info.ca.is_none() && !ni.get_all("Sig").iter().any(|g| g.starts_with(&format!("{key_name}:"))) {
        bail!("minted narinfo for {store_path} carries no signature by {key_name:?}");
    }
    Ok(s)
}

/// Run `nix` with a newline-separated path list on stdin, returning the exit
/// status alongside stdout so a caller can distinguish "this Nix does not know
/// that flag" from "that path is bad".
fn nix_try(nix: &str, args: &[&str], paths: &[String]) -> Result<(bool, Vec<u8>)> {
    let mut child = Command::new(nix)
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .with_context(|| format!("spawning {nix} {}", args.join(" ")))?;
    {
        let mut si = child.stdin.take().context("no stdin")?;
        for p in paths {
            si.write_all(p.as_bytes())?;
            si.write_all(b"\n")?;
        }
    }
    let out = child.wait_with_output()?;
    if !out.status.success() {
        let err = String::from_utf8_lossy(&out.stderr);
        if !err.trim().is_empty() {
            tracing::debug!(args = args.join(" "), "nix: {}", err.trim());
        }
    }
    Ok((out.status.success(), out.stdout))
}

/// Run `nix` and insist it worked.
fn nix_stdin(nix: &str, args: &[&str], paths: &[String]) -> Result<Vec<u8>> {
    let (ok, out) = nix_try(nix, args, paths)?;
    if !ok {
        bail!("{nix} {} failed", args.join(" "));
    }
    Ok(out)
}

/// Which declared paths this host must sign.
///
/// Only the ones with **no signature at all**, which are precisely the paths
/// gap 21 is about: this host built them, nothing else has heard of them, and
/// without a signature from us no peer can use them.
///
/// Everything else already carries a signature — normally cache.nixos.org's —
/// and resolves through the ordinary chain. Signing those too would be wrong
/// twice over. It is permanent (`nix store sign` writes `/nix/var/nix/db`, and
/// the extra signature then travels through `nix copy`, `nix path-info --sigs`
/// and ssh-ng, not merely through this adapter), and it is the maximum possible
/// blast radius for the key: a consumer that trusts it does so for EVERY store
/// path it will ever substitute, because Nix cannot scope a key to a path set.
/// `servePackages = [ pkgs.foo ]` must not put this host's name on glibc.
///
/// A content-addressed path is excluded: its anchor is the store path name,
/// which Nix recomputes, so a signature would add nothing.
pub fn plan_signing(
    paths: &[String],
    info: &BTreeMap<String, PathInfo>,
    key_name: &str,
) -> Vec<String> {
    let ours = format!("{key_name}:");
    paths
        .iter()
        .filter(|p| {
            info.get(*p)
                .map(|i| {
                    i.ca.is_none()
                        && !i.signatures.iter().any(|s| s.starts_with(&ours))
                        && !i.signatures.iter().any(|s| !s.starts_with(&ours))
                })
                .unwrap_or(false)
        })
        .cloned()
        .collect()
}

/// Which declared paths this host may publish a narinfo for.
///
/// Those that carry **no signature by anybody else** — so either only ours, or
/// none at all with a `CA:` to stand in for one. A path cache.nixos.org signed
/// is never published here: a declared narinfo outranks the fetched tier and is
/// never evicted, so minting one for a path upstream also has would freeze that
/// path's signature set forever, and a path that later gained a second `Sig`
/// upstream would start being refused by peers trusting only the other key.
///
/// **This is deliberately not the complement of `plan_signing`.** After the
/// first run a locally-built path carries our signature, so it no longer needs
/// signing — but it must still be published, or the prune below would
/// unpublish on the second `nixos-rebuild` everything the first one published.
pub fn plan_publishing(
    paths: &[String],
    info: &BTreeMap<String, PathInfo>,
    key_name: &str,
) -> Vec<String> {
    let ours = format!("{key_name}:");
    paths
        .iter()
        .filter(|p| {
            info.get(*p)
                .map(|i| {
                    !i.signatures.iter().any(|s| !s.starts_with(&ours))
                        && (i.ca.is_some() || !i.signatures.is_empty())
                })
                .unwrap_or(false)
        })
        .cloned()
        .collect()
}

/// Sign, query and publish. Returns what changed.
pub fn seed(
    cache: &Cache,
    nix: &str,
    key_file: &Path,
    key_secret: &str,
    paths: &[String],
) -> Result<Summary> {
    let mut sum = Summary::default();
    let name = key_name(key_secret)?;

    // What we already hold, so a path dropped from `servePackages` actually
    // stops being served instead of the declared set only ever growing.
    let previous: Vec<String> = cache.list_declared()?;

    if paths.is_empty() {
        for hp in &previous {
            cache.remove_declared(hp)?;
            sum.unpublished += 1;
        }
        return Ok(sum);
    }

    let before = path_info(nix, paths)?;

    let to_sign = plan_signing(paths, &before, name);
    let info = if to_sign.is_empty() {
        before
    } else {
        tracing::info!(count = to_sign.len(), key = name, "signing locally-built paths");
        nix_stdin(
            nix,
            &["store", "sign", "--key-file", &key_file.to_string_lossy(), "--stdin"],
            &to_sign,
        )?;
        sum.signed = to_sign.len();
        // Re-query the WHOLE set, not just what was signed: the publish plan
        // below has to see every path, including the ones already carrying our
        // signature from an earlier run.
        path_info(nix, paths)?
    };

    let mineable = plan_publishing(paths, &info, name);
    let upstream_owned = paths.len() - mineable.len();

    // Most of a declared closure is not ours to publish, and that is the
    // normal, healthy shape — `servePackages = [ pkgs.foo ]` pulls in hundreds
    // of cache.nixos.org paths that resolve perfectly well without us. Log both
    // numbers so "we published 1 of 312" reads as correct rather than broken.
    tracing::info!(
        declared = paths.len(),
        ours = mineable.len(),
        upstream_owned,
        "declared closure"
    );

    let mut published: Vec<String> = Vec::new();
    for p in &mineable {
        let Some(i) = info.get(p) else {
            tracing::warn!(path = %p, "declared path is not valid in the store; skipping");
            sum.skipped += 1;
            continue;
        };
        let hp = match hash_part(p) {
            Ok(hp) => hp,
            Err(e) => {
                tracing::warn!(path = %p, error = %e, "skipping");
                sum.skipped += 1;
                continue;
            }
        };
        match narinfo_text(p, i, name) {
            Ok(text) => {
                cache.put_declared(hp, &text)?;
                published.push(hp.to_string());
                sum.published += 1;
            }
            Err(e) => {
                tracing::warn!(path = %p, error = %e, "not publishable; skipping");
                sum.skipped += 1;
            }
        }
    }

    for hp in previous {
        if !published.contains(&hp) {
            cache.remove_declared(&hp)?;
            sum.unpublished += 1;
        }
    }
    Ok(sum)
}

fn path_info(nix: &str, paths: &[String]) -> Result<BTreeMap<String, PathInfo>> {
    // Two spellings, and BOTH are needed. Determinate Nix 3.x deprecates the
    // bare `--json` and warns that it will become an error, so pin the format
    // where we can. But `--json-format` does not exist at all on the Nix in
    // nixpkgs — it is `unrecognised flag` there, which is a hard failure — so
    // pinning unconditionally makes this unusable on a stock NixOS host. This
    // was found by the VM gate, whose Nix is the stable one.
    //
    // The shapes agree: stable's `--json` *is* format 1. Only `--json-format 2`
    // differs (bare-basename references, a structured `ca` object), and we
    // never ask for it.
    let pinned = ["path-info", "--json-format", "1", "--json", "--sigs", "--stdin"];
    let (ok, out) = nix_try(nix, &pinned, paths)?;
    let out = if ok {
        out
    } else {
        tracing::debug!("`--json-format` not supported; this Nix predates it");
        nix_stdin(nix, &["path-info", "--json", "--sigs", "--stdin"], paths)?
    };
    serde_json::from_slice(&out).context("parsing `nix path-info --json` output")
}

/// Read the declared path list produced by `pkgs.closureInfo`.
pub fn read_path_list(p: &Path) -> Result<Vec<String>> {
    let text = std::fs::read_to_string(p)
        .with_context(|| format!("reading declared path list {}", p.display()))?;
    let mut v: Vec<String> = text
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty())
        .map(str::to_string)
        .collect();
    v.sort();
    v.dedup();
    Ok(v)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn info() -> PathInfo {
        PathInfo {
            nar_hash: "sha256-u59acWqXzrxd4DeumpDsJjTLP0roxjLiN7cKENPiDE0=".into(),
            nar_size: 274568,
            references: vec![
                "/nix/store/18bbdvag5v2f3d4y37pdbkzvh7s71cw4-hello-2.12.2".into(),
                "/nix/store/7nbi22pcc92y2fqbkyp7h3srvvklmckb-glibc-2.40-224".into(),
            ],
            deriver: Some("/nix/store/8550ijfw8imvqnky30gwdvwlidq3g42b-hello-2.12.2.drv".into()),
            ca: None,
            signatures: vec!["nixos-p2p-1:AAAABBBB==".into()],
        }
    }

    const P: &str = "/nix/store/18bbdvag5v2f3d4y37pdbkzvh7s71cw4-hello-2.12.2";

    #[test]
    fn a_minted_narinfo_round_trips() {
        let text = narinfo_text(P, &info(), "nixos-p2p-1").unwrap();
        let ni = NarInfo::parse(&text).unwrap();
        assert_eq!(ni.store_path(), P);
        assert_eq!(ni.nar_size().unwrap(), 274568);
        assert_eq!(ni.compression(), "none");
        assert_eq!(ni.get_all("Sig"), vec!["nixos-p2p-1:AAAABBBB=="]);
    }

    #[test]
    fn the_emitted_url_equals_route_nar_url() {
        // If these ever disagree the anti-open-proxy check in `http::nar`
        // rejects our own artifact and the path 404s on the host that owns it.
        let text = narinfo_text(P, &info(), "nixos-p2p-1").unwrap();
        let ni = NarInfo::parse(&text).unwrap();
        assert_eq!(ni.url(), crate::route::nar_url(&ni));
    }

    #[test]
    fn references_are_basenames_not_paths() {
        // Full paths here parse fine and then fail signature verification with
        // a fingerprint mismatch, three machines away from the mistake.
        let text = narinfo_text(P, &info(), "nixos-p2p-1").unwrap();
        let ni = NarInfo::parse(&text).unwrap();
        let refs = ni.get("References").unwrap();
        assert!(!refs.contains('/'), "references carry a path: {refs}");
        assert_eq!(
            refs,
            "18bbdvag5v2f3d4y37pdbkzvh7s71cw4-hello-2.12.2 \
             7nbi22pcc92y2fqbkyp7h3srvvklmckb-glibc-2.40-224"
        );
        assert_eq!(ni.get("Deriver").unwrap(), "8550ijfw8imvqnky30gwdvwlidq3g42b-hello-2.12.2.drv");
    }

    #[test]
    fn the_nar_hash_is_converted_from_sri_not_copied() {
        // `nix path-info` speaks SRI base64; a narinfo speaks `sha256:<nix32>`.
        // Copying the SRI form straight through yields a narinfo Nix rejects.
        let text = narinfo_text(P, &info(), "nixos-p2p-1").unwrap();
        assert!(text.contains("NarHash: sha256:"), "{text}");
        assert!(!text.contains("sha256-"), "SRI form leaked into the narinfo:\n{text}");
    }

    #[test]
    fn an_unsigned_path_is_never_published() {
        let mut i = info();
        i.signatures.clear();
        assert!(narinfo_text(P, &i, "nixos-p2p-1").is_err(), "published metadata Nix will refuse");
    }

    #[test]
    fn a_content_addressed_path_needs_no_signature() {
        // Not an oversight in the check above. `checkSignatures` returns
        // `maxSigs` for a CA path without examining a signature at all — the
        // anchor is the store path name, which Nix recomputes from `CA:`.
        let mut i = info();
        i.signatures.clear();
        i.ca = Some("fixed:r:sha256:1abc".into());
        let text = narinfo_text(P, &i, "nixos-p2p-1").unwrap();
        assert!(text.contains("CA: fixed:r:sha256:1abc"), "{text}");
    }

    #[test]
    fn a_signature_by_somebody_else_is_not_ours() {
        // A path signed only by cache.nixos.org is not one this host can
        // vouch for, and minting metadata that claims otherwise publishes an
        // artifact no peer trusting *our* key can use.
        let mut i = info();
        i.signatures = vec!["cache.nixos.org-1:AAAA==".into()];
        assert!(narinfo_text(P, &i, "nixos-p2p-1").is_err());
    }

    #[test]
    fn a_narinfo_filed_under_the_wrong_name_is_refused() {
        // The filename is the lookup key but `route::nar_url` derives the hash
        // part from StorePath. Disagreement is a silent, permanent 404 on the
        // host that owns the artifact.
        let text = narinfo_text(P, &info(), "nixos-p2p-1").unwrap();
        let ni = NarInfo::parse(&text).unwrap();
        assert_eq!(ni.hash_part(), "18bbdvag5v2f3d4y37pdbkzvh7s71cw4");
        assert_eq!(crate::route::nar_url(&ni), ni.url());
    }

    #[test]
    fn a_path_with_no_references_still_parses() {
        // `References: ` with a trailing space and an empty value. Emitting
        // `References:` with no space makes `NarInfo::parse` fail on the
        // `": "` separator, which would drop every leaf path in a closure.
        let mut i = info();
        i.references.clear();
        let text = narinfo_text(P, &i, "nixos-p2p-1").unwrap();
        assert!(text.contains("References: \n"), "{text:?}");
        assert_eq!(NarInfo::parse(&text).unwrap().get("References"), Some(""));
    }

    #[test]
    fn a_null_deriver_emits_no_line() {
        let mut i = info();
        i.deriver = None;
        let text = narinfo_text(P, &i, "nixos-p2p-1").unwrap();
        assert!(!text.contains("Deriver"), "{text}");
        NarInfo::parse(&text).unwrap();
    }

    fn plan_map(entries: Vec<(&str, PathInfo)>) -> (Vec<String>, BTreeMap<String, PathInfo>) {
        let paths: Vec<String> = entries.iter().map(|(p, _)| p.to_string()).collect();
        let m = entries.into_iter().map(|(p, i)| (p.to_string(), i)).collect();
        (paths, m)
    }

    #[test]
    fn a_second_run_republishes_rather_than_unpublishing() {
        // THE re-run bug. After the first seed the path carries our signature,
        // so it no longer needs signing — but it must still be published, or
        // the prune step unpublishes on the second `nixos-rebuild` everything
        // the first one published, silently, on a host that still looks fine.
        let mut signed = info();
        signed.signatures = vec!["nixos-p2p-1:AAAA==".into()];
        let (paths, m) = plan_map(vec![(P, signed)]);

        assert!(plan_signing(&paths, &m, "nixos-p2p-1").is_empty(), "re-signed an already-signed path");
        assert_eq!(
            plan_publishing(&paths, &m, "nixos-p2p-1"),
            vec![P.to_string()],
            "a path we already signed stopped being published"
        );
    }

    #[test]
    fn an_unsigned_path_is_signed_then_published() {
        let mut fresh = info();
        fresh.signatures.clear();
        let (paths, m) = plan_map(vec![(P, fresh)]);
        assert_eq!(plan_signing(&paths, &m, "nixos-p2p-1"), vec![P.to_string()]);
        // Not publishable YET — it has no signature until `nix store sign`
        // runs and the info is re-queried.
        assert!(plan_publishing(&paths, &m, "nixos-p2p-1").is_empty());
    }

    #[test]
    fn an_upstream_signed_path_is_neither_signed_nor_published() {
        // The blast-radius rule: `servePackages = [ pkgs.foo ]` must not put
        // this host's name on glibc, and must not shadow glibc's narinfo with
        // a frozen copy of its signature set either.
        let mut up = info();
        up.signatures = vec!["cache.nixos.org-1:BBBB==".into()];
        let (paths, m) = plan_map(vec![(P, up)]);
        assert!(plan_signing(&paths, &m, "nixos-p2p-1").is_empty());
        assert!(plan_publishing(&paths, &m, "nixos-p2p-1").is_empty());
    }

    #[test]
    fn a_content_addressed_path_is_published_without_being_signed() {
        let mut ca = info();
        ca.signatures.clear();
        ca.ca = Some("fixed:r:sha256:1abc".into());
        let (paths, m) = plan_map(vec![(P, ca)]);
        assert!(plan_signing(&paths, &m, "nixos-p2p-1").is_empty(), "signed a CA path for nothing");
        assert_eq!(plan_publishing(&paths, &m, "nixos-p2p-1"), vec![P.to_string()]);
    }

    #[test]
    fn a_path_missing_from_the_store_is_skipped_by_both_plans() {
        let (paths, m) = (vec![P.to_string()], BTreeMap::new());
        assert!(plan_signing(&paths, &m, "nixos-p2p-1").is_empty());
        assert!(plan_publishing(&paths, &m, "nixos-p2p-1").is_empty());
    }

    #[test]
    fn a_world_readable_key_is_refused() {
        let p = Path::new("/tmp/k");
        assert!(check_key_mode(0o400, p).is_ok());
        assert!(check_key_mode(0o600, p).is_ok());
        for bad in [0o440, 0o444, 0o604, 0o666, 0o777] {
            assert!(check_key_mode(bad, p).is_err(), "accepted mode {bad:04o}");
        }
    }

    #[test]
    fn the_key_name_is_the_signature_prefix() {
        assert_eq!(key_name("nixos-p2p-1:c2VjcmV0\n").unwrap(), "nixos-p2p-1");
        assert!(key_name("no-colon").is_err());
        assert!(key_name(":empty").is_err());
        assert!(key_name("empty:").is_err());
    }

    #[test]
    fn a_path_that_is_not_a_store_path_is_refused() {
        assert!(hash_part("/etc/passwd").is_err());
        assert!(hash_part("/nix/store/short-name").is_err());
        assert_eq!(hash_part(P).unwrap(), "18bbdvag5v2f3d4y37pdbkzvh7s71cw4");
    }

    #[test]
    fn the_path_list_is_sorted_and_deduplicated() {
        let d = tempfile::tempdir().unwrap();
        let f = d.path().join("store-paths");
        std::fs::write(&f, "/nix/store/b\n/nix/store/a\n\n/nix/store/b\n").unwrap();
        assert_eq!(read_path_list(&f).unwrap(), vec!["/nix/store/a", "/nix/store/b"]);
    }
}
