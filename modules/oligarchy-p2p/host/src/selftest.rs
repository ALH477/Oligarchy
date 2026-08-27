//! `oligarchy-p2pd selftest` — assertions this daemon makes about itself.
//!
//! **Why this exists.** Every failure this subsystem has shipped had the same
//! shape: the broken state was indistinguishable from the working one. A
//! declared tier that never populated, a `provide` call that was never wired, a
//! seed run that unpublished what the previous run published, a
//! `ConditionPathExists` in the wrong systemd section — in each case the daemon
//! answered requests, the unit was active, and the journal looked ordinary. A
//! passing test could not tell the difference either, which is why three of
//! them shipped behind green gates.
//!
//! `plugind selftest` exists in the plugin runtime for exactly this reason, and
//! says so three times: *a filter that silently failed to install is invisible
//! from inside the process that installed it.* This is the same idea for the
//! substituter. It does not report configuration; `check` already does that.
//! It **exercises** things and reports what actually happened.
//!
//! Two rules, taken from `mcp_self_audit` in the MCP workspace, and they are
//! the whole point:
//!
//! 1. **A check that inspected nothing is a FAIL, not a PASS.** "Zero declared
//!    narinfos, all valid" is the exact sentence that hid a real bug.
//! 2. **A skipped check is reported, never omitted.** The report must never
//!    imply a check it did not run.

use crate::cache::Cache;
use crate::config::Config;
use crate::narinfo::NarInfo;
use crate::nixhash::Sha256Digest;
use crate::scope::PeerScope;
use crate::transport::lan::ureq_like;
use sha2::{Digest, Sha256};
use std::path::Path;
use std::time::Duration;

#[derive(Debug, PartialEq, Eq, Clone, Copy)]
pub enum Verdict {
    Pass,
    Fail,
    Warn,
    /// Not run, and the report says so. Never silent.
    Skip,
}

impl Verdict {
    fn token(self) -> &'static str {
        match self {
            Verdict::Pass => "PASS",
            Verdict::Fail => "FAIL",
            Verdict::Warn => "WARN",
            Verdict::Skip => "SKIP",
        }
    }
}

pub struct Check {
    pub name: &'static str,
    pub verdict: Verdict,
    pub detail: String,
}

impl Check {
    fn new(name: &'static str, verdict: Verdict, detail: impl Into<String>) -> Self {
        Self { name, verdict, detail: detail.into() }
    }
    fn pass(name: &'static str, d: impl Into<String>) -> Self {
        Self::new(name, Verdict::Pass, d)
    }
    fn fail(name: &'static str, d: impl Into<String>) -> Self {
        Self::new(name, Verdict::Fail, d)
    }
    fn warn(name: &'static str, d: impl Into<String>) -> Self {
        Self::new(name, Verdict::Warn, d)
    }
    fn skip(name: &'static str, d: impl Into<String>) -> Self {
        Self::new(name, Verdict::Skip, d)
    }
}

/// Render a report and decide the exit status.
pub fn render(checks: &[Check]) -> (String, bool) {
    let width = checks.iter().map(|c| c.name.len()).max().unwrap_or(0);
    let mut out = String::from("oligarchy-p2pd selftest — what this daemon can prove about itself\n\n");
    for c in checks {
        out.push_str(&format!(
            "  {}  {:<width$}  {}\n",
            c.verdict.token(),
            c.name,
            c.detail,
            width = width
        ));
    }
    let failed: Vec<&str> =
        checks.iter().filter(|c| c.verdict == Verdict::Fail).map(|c| c.name).collect();
    out.push('\n');
    if failed.is_empty() {
        // Name the SKIPs and WARNs in the summary too. A report whose last line
        // reads "none failed" while three checks quietly did not run is the
        // same failure mode this command exists to end.
        let count = |v: Verdict| checks.iter().filter(|c| c.verdict == v).count();
        let mut notes = Vec::new();
        let (skipped, warned) = (count(Verdict::Skip), count(Verdict::Warn));
        if skipped > 0 {
            notes.push(format!("{skipped} skipped"));
        }
        if warned > 0 {
            notes.push(format!("{warned} warning(s)"));
        }
        out.push_str(&format!(
            "{} checks, none failed{}\n",
            checks.len(),
            if notes.is_empty() {
                String::new()
            } else {
                format!(" — {} (see above)", notes.join(", "))
            }
        ));
    } else {
        out.push_str(&format!("FAILED: {}\n", failed.join(", ")));
    }
    (out, failed.is_empty())
}

fn base_url(cfg: &Config) -> String {
    format!("http://{}:{}", cfg.bind_address, cfg.port)
}

/// Run every check.
///
/// Returns checks rather than a `Result`, deliberately: a failed check is
/// **data**, not an error. The report is the product, and one broken guarantee
/// must not hide the seven other verdicts an operator needs to see.
pub fn run(cfg: &Config) -> Vec<Check> {
    let mut v = Vec::new();
    v.push(bind_is_loopback(cfg));
    v.push(no_trusted_in_nix_conf());
    let client = ureq_like::Client::new(Duration::from_secs(5));
    v.push(daemon_answers(cfg, &client));
    v.push(declared_refuses_a_write(cfg));
    let (coherent, sample) = declared_narinfos_are_coherent(cfg);
    v.push(coherent);
    v.push(round_trip(cfg, &client, sample));
    v.push(peer_scope_is_bounded(cfg));
    v.push(peers_reachable(cfg, &client));
    v
}

fn bind_is_loopback(cfg: &Config) -> Check {
    const N: &str = "bind_is_loopback";
    match cfg.bind_address.parse::<std::net::IpAddr>() {
        Ok(ip) if ip.is_loopback() => Check::pass(N, format!("{ip}")),
        Ok(ip) => Check::fail(N, format!("{ip} is routable; this surface proxies upstream")),
        Err(e) => Check::fail(N, format!("unparseable bind address: {e}")),
    }
}

/// `?trusted=1` makes Nix accept unsigned paths, silently, with exit 0 — the
/// single change that would undo the whole design. Both files are checked
/// because Determinate ships `nix.conf` *and* `nix.custom.conf` and either can
/// carry substituters.
fn no_trusted_in_nix_conf() -> Check {
    no_trusted_in("/etc/nix/nix.conf", "/etc/nix/nix.custom.conf")
}

fn no_trusted_in(a: &str, b: &str) -> Check {
    const N: &str = "no_trusted_in_nix_conf";
    let files = [a, b];
    let mut read = 0;
    let mut offenders = Vec::new();
    for f in files {
        if let Ok(text) = std::fs::read_to_string(f) {
            read += 1;
            for line in text.lines() {
                let l = line.trim();
                if l.starts_with('#') {
                    continue;
                }
                if (l.starts_with("substituters") || l.starts_with("trusted-substituters"))
                    && l.contains("trusted=")
                {
                    offenders.push(format!("{f}: {l}"));
                }
            }
        }
    }
    if read == 0 {
        // Rule 1: inspecting nothing is not a pass.
        return Check::fail(N, "neither nix.conf nor nix.custom.conf could be read");
    }
    if offenders.is_empty() {
        Check::pass(N, format!("{read} file(s) clean"))
    } else {
        Check::fail(N, offenders.join("; "))
    }
}

/// The check `status` has never done: is anything actually listening, and is it
/// us? A dead daemon is the case an operator runs this for.
fn daemon_answers(cfg: &Config, client: &ureq_like::Client) -> Check {
    const N: &str = "daemon_answers";
    let url = format!("{}/nix-cache-info", base_url(cfg));
    match client.get_text(&url, Duration::from_secs(5), 64 * 1024) {
        Ok(Some(body)) => {
            let want = format!("StoreDir: {}", cfg.store_dir);
            if body.contains(&want) {
                Check::pass(N, format!("{} serving {}", base_url(cfg), cfg.store_dir))
            } else {
                Check::fail(N, format!("answered, but not with {want:?}: {body:?}"))
            }
        }
        Ok(None) => Check::fail(N, "404 on /nix-cache-info"),
        Err(e) => Check::fail(N, format!("no answer on {}: {e}", base_url(cfg))),
    }
}

/// `ReadOnlyPaths` is only ever proven by trying it.
///
/// A configured-but-ineffective mount is invisible from inside this process,
/// which is the entire lesson of the bugs that motivated this command. Running
/// as root would write successfully and report a false PASS, so that case is a
/// loud SKIP rather than a quiet one.
fn declared_refuses_a_write(cfg: &Config) -> Check {
    const N: &str = "declared_refuses_a_write";
    if !cfg.serve_declared {
        return Check::skip(N, "servePackages is empty; there is no declared tier");
    }
    // Via `Cache` rather than re-deriving the path, so the probe cannot end up
    // testing a directory the daemon does not use.
    let cache = match Cache::open(Path::new(&cfg.state_dir), 0) {
        Ok(c) => c,
        Err(e) => return Check::fail(N, format!("cannot open the state dir: {e}")),
    };
    let dir = cache.declared_dir().to_path_buf();
    if !dir.is_dir() {
        return Check::fail(N, format!("{} does not exist", dir.display()));
    }
    // SAFETY: euid only.
    let euid = unsafe { libc::geteuid() };
    if euid == 0 {
        return Check::skip(
            N,
            "running as root, which can write regardless — run the \
             oligarchy-p2p-selftest unit, which runs as the daemon user \
             inside the daemon's sandbox",
        );
    }
    let probe = dir.join(format!(".selftest-{}", std::process::id()));
    match std::fs::write(&probe, b"x") {
        Ok(()) => {
            let _ = std::fs::remove_file(&probe);
            Check::fail(
                N,
                format!(
                    "wrote {} as uid {euid} — neither ReadOnlyPaths nor the \
                     directory mode refuses this daemon, so it can rewrite \
                     what it publishes",
                    probe.display()
                ),
            )
        }
        Err(e) => Check::pass(N, format!("refused as uid {euid} ({})", e.kind())),
    }
}

/// Every published narinfo is one a peer will act on. Returns a sample path for
/// the round-trip check so the two do not disagree about what to test.
fn declared_narinfos_are_coherent(cfg: &Config) -> (Check, Option<(String, NarInfo)>) {
    const N: &str = "declared_narinfos_are_coherent";
    if !cfg.serve_declared {
        return (Check::skip(N, "servePackages is empty"), None);
    }
    let cache = match Cache::open(Path::new(&cfg.state_dir), 0) {
        Ok(c) => c,
        Err(e) => return (Check::fail(N, format!("cannot open the state dir: {e}")), None),
    };
    let listed = match cache.list_declared() {
        Ok(l) => l,
        Err(e) => return (Check::fail(N, format!("cannot list declared/: {e}")), None),
    };
    if listed.is_empty() {
        // Rule 1 again, and this is the sentence that hid a real bug: a host
        // told to publish that publishes nothing looks healthy from every
        // other angle.
        return (
            Check::fail(N, "servePackages is set but declared/ is EMPTY — check oligarchy-p2p-seed.service"),
            None,
        );
    }
    let mut sample = None;
    let mut bad = Vec::new();
    for hp in &listed {
        let Some(text) = cache.get_narinfo(hp) else {
            bad.push(format!("{hp}: listed but unreadable"));
            continue;
        };
        match NarInfo::parse(&text) {
            Err(e) => bad.push(format!("{hp}: {e}")),
            Ok(ni) => {
                if ni.hash_part() != hp {
                    bad.push(format!("{hp}: names {} instead", ni.hash_part()));
                } else if ni.url() != crate::route::nar_url(&ni) {
                    bad.push(format!("{hp}: URL {:?} is not the derived one", ni.url()));
                } else if ni.get_all("Sig").is_empty() && ni.get("CA").is_none() {
                    bad.push(format!("{hp}: no signature and not content-addressed"));
                } else if sample.is_none() {
                    sample = Some((hp.clone(), ni));
                }
            }
        }
    }
    if bad.is_empty() {
        (Check::pass(N, format!("{} published, all coherent", listed.len())), sample)
    } else {
        (Check::fail(N, bad.join("; ")), sample)
    }
}

/// End to end, through the real surface: ask ourselves for a narinfo, ask for
/// the NAR it names, and hash it. Everything else in this report checks a part;
/// this checks that the parts are connected.
fn round_trip(
    cfg: &Config,
    client: &ureq_like::Client,
    sample: Option<(String, NarInfo)>,
) -> Check {
    const N: &str = "round_trip";
    let Some((hp, _)) = sample else {
        return Check::skip(N, "no declared narinfo to test with");
    };
    let base = base_url(cfg);
    let text = match client.get_text(&format!("{base}/{hp}.narinfo"), Duration::from_secs(30), 1 << 20) {
        Ok(Some(t)) => t,
        Ok(None) => return Check::fail(N, format!("{hp}.narinfo: 404 from our own surface")),
        Err(e) => return Check::fail(N, format!("{hp}.narinfo: {e}")),
    };
    let ni = match NarInfo::parse(&text) {
        Ok(n) => n,
        Err(e) => return Check::fail(N, format!("we served an unparseable narinfo: {e}")),
    };
    let want = ni.nar_hash();
    let size = match ni.nar_size() {
        Ok(s) => s,
        Err(e) => return Check::fail(N, format!("{e}")),
    };
    let url = format!("{base}/{}", crate::route::nar_url(&ni));
    let body = match client.get_bytes(&url, Duration::from_secs(120), size + 1) {
        Ok(Some(b)) => b,
        Ok(None) => return Check::fail(N, format!("{url}: 404 — the narinfo names a NAR we do not serve")),
        Err(e) => return Check::fail(N, format!("{url}: {e}")),
    };
    if body.len() as u64 != size {
        return Check::fail(N, format!("{} bytes served against NarSize {size}", body.len()));
    }
    let got = Sha256Digest(Sha256::digest(&body).into());
    if got != want {
        return Check::fail(N, format!("hash mismatch: {} != {}", got.to_nix32(), want.to_nix32()));
    }
    Check::pass(N, format!("{hp}: {size} bytes, {}", want.to_prefixed()))
}

fn peer_scope_is_bounded(cfg: &Config) -> Check {
    const N: &str = "peer_scope_is_bounded";
    let sc = PeerScope::new(&cfg.peer_public_keys, &cfg.accept_from_peers);
    if !sc.is_active() {
        return Check::pass(N, "no peer keys trusted; nothing to bound");
    }
    if cfg.accept_from_peers.iter().any(|e| e.trim() == "*") {
        return Check::warn(
            N,
            "acceptFromPeers is \"*\" — a trusted peer key vouches for EVERY \
             store path this host substitutes",
        );
    }
    Check::pass(N, sc.describe())
}

fn peers_reachable(cfg: &Config, client: &ureq_like::Client) -> Check {
    const N: &str = "peers_reachable";
    if cfg.peers.is_empty() {
        return Check::skip(N, "no peers configured");
    }
    let mut up = 0;
    let mut down = Vec::new();
    for p in &cfg.peers {
        let url = format!("http://{p}/peer/v1/info");
        match client.head_ok(&url, Duration::from_secs(3)) {
            Ok(true) => up += 1,
            _ => down.push(p.clone()),
        }
    }
    if down.is_empty() {
        Check::pass(N, format!("{up}/{} reachable", cfg.peers.len()))
    } else {
        // A peer being down is not a fault in this host, so it must not fail
        // the run — otherwise the command becomes one nobody trusts.
        Check::warn(N, format!("{up}/{} reachable; down: {}", cfg.peers.len(), down.join(" ")))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_failed_check_decides_the_exit_status() {
        let (out, ok) = render(&[Check::pass("a", "fine"), Check::fail("b", "broken")]);
        assert!(!ok);
        assert!(out.contains("FAILED: b"), "{out}");
    }

    #[test]
    fn a_skipped_check_is_reported_never_omitted() {
        // The report must never imply a check it did not run.
        let (out, ok) = render(&[Check::pass("a", "fine"), Check::skip("b", "not applicable")]);
        assert!(ok);
        assert!(out.contains("SKIP"), "{out}");
        assert!(out.contains("b"), "{out}");
        assert!(out.contains("1 skipped"), "{out}");
    }

    #[test]
    fn a_warning_does_not_fail_the_run_but_is_summarised() {
        let (out, ok) = render(&[Check::pass("a", "fine"), Check::warn("b", "a peer is down")]);
        assert!(ok);
        // "none failed" on its own would bury it.
        assert!(out.contains("1 warning(s)"), "{out}");
    }

    #[test]
    fn an_unreadable_nix_conf_is_a_failure_not_a_pass() {
        // Rule 1: a check that inspected nothing has proven nothing. This is
        // the shape that let "zero declared narinfos, all valid" pass.
        let c = no_trusted_in("/nonexistent/a.conf", "/nonexistent/b.conf");
        assert_eq!(c.verdict, Verdict::Fail, "{}", c.detail);
    }

    #[test]
    fn a_trusted_substituter_is_caught_in_either_file() {
        let d = tempfile::tempdir().unwrap();
        let a = d.path().join("nix.conf");
        let b = d.path().join("nix.custom.conf");
        std::fs::write(&a, "substituters = https://cache.nixos.org\n").unwrap();
        std::fs::write(&b, "experimental-features = nix-command\n").unwrap();
        let (as_, bs) = (a.to_str().unwrap(), b.to_str().unwrap());
        assert_eq!(no_trusted_in(as_, bs).verdict, Verdict::Pass);

        // Determinate ships BOTH files and either can carry substituters, so a
        // check that read only the first would miss this entirely.
        std::fs::write(&b, "substituters = http://127.0.0.1:5111?trusted=1\n").unwrap();
        let c = no_trusted_in(as_, bs);
        assert_eq!(c.verdict, Verdict::Fail, "{}", c.detail);
        assert!(c.detail.contains("trusted="), "{}", c.detail);
    }

    #[test]
    fn a_commented_out_trusted_line_is_not_a_finding() {
        let d = tempfile::tempdir().unwrap();
        let a = d.path().join("nix.conf");
        let b = d.path().join("other.conf");
        std::fs::write(&a, "# substituters = http://x?trusted=1\nsubstituters = https://ok\n").unwrap();
        std::fs::write(&b, "").unwrap();
        assert_eq!(
            no_trusted_in(a.to_str().unwrap(), b.to_str().unwrap()).verdict,
            Verdict::Pass
        );
    }

    #[test]
    fn a_routable_bind_fails() {
        let mut cfg = crate::config::Config::sample();
        cfg.bind_address = "0.0.0.0".into();
        assert_eq!(bind_is_loopback(&cfg).verdict, Verdict::Fail);
        cfg.bind_address = "127.0.0.1".into();
        assert_eq!(bind_is_loopback(&cfg).verdict, Verdict::Pass);
    }

    #[test]
    fn a_wildcard_scope_warns() {
        let mut cfg = crate::config::Config::sample();
        cfg.peer_public_keys = vec!["k-1:AAAA==".into()];
        cfg.accept_from_peers = vec!["*".into()];
        assert_eq!(peer_scope_is_bounded(&cfg).verdict, Verdict::Warn);
        cfg.accept_from_peers = vec!["my-thing".into()];
        assert_eq!(peer_scope_is_bounded(&cfg).verdict, Verdict::Pass);
    }

    #[test]
    fn an_empty_declared_tier_fails_when_packages_were_declared() {
        // "servePackages is set but nothing is published" is exactly the
        // failure that looks identical to working from every other angle.
        let d = tempfile::tempdir().unwrap();
        let mut cfg = crate::config::Config::sample();
        cfg.state_dir = d.path().to_string_lossy().into_owned();
        cfg.serve_declared = true;
        Cache::open(d.path(), 0).unwrap();
        let (c, sample) = declared_narinfos_are_coherent(&cfg);
        assert_eq!(c.verdict, Verdict::Fail, "{}", c.detail);
        assert!(sample.is_none());
    }
}
