//! Which paths a peer's key is allowed to vouch for.
//!
//! **Nix cannot scope a signing key to a set of store paths.** Adding a peer's
//! public key to `trusted-public-keys` trusts that host for *everything* this
//! machine will ever substitute — and the adapter is `Priority: 30`, ahead of
//! cache.nixos.org, so it is asked first for every path. A compromised seeder
//! could mint a narinfo for glibc, sign it, and be believed. That is remote
//! root at the next rebuild, and it is the cost stage 5 incurred.
//!
//! Nix cannot scope a key. **This adapter can**, because every narinfo a peer
//! supplies passes through it. `acceptFromPeers` names the packages a peer key
//! may speak for; anything else it signs is refused before Nix sees it.
//!
//! Applied in four places, and each closes something the others cannot:
//!
//! 1. `LanTransport::narinfo`, **inside the peer loop**. It returns the first
//!    parseable answer and stops, so refusing only in the caller would let one
//!    hostile peer answer every query out-of-scope while the honest peers
//!    below it were never asked.
//! 2. `AppState::resolve`'s peer arm, before the narinfo is persisted.
//! 3. `AppState::resolve`'s disk arm — an entry that reached `narinfo/` is
//!    durable and would otherwise be served forever, transport never consulted.
//! 4. `peer.rs`, so a host that accepted something out of scope does not relay
//!    it onward and become a second hop into hosts that refused it directly.
//!
//! `declared/` is exempt everywhere: those are narinfos this host minted for
//! its own operator's packages, and the keys here belong to other hosts.
//!
//! ## What this does not cover
//!
//! **The key stays in `trusted-public-keys` globally.** Anything bypassing the
//! adapter — a peer added directly to `substituters`, `nix copy --from`, a
//! remote builder — is unscoped. The scoping is a property of this code path,
//! not of the machine.
//!
//! **The name is supplied by the peer.** `in_scope` reads `StorePath`, and the
//! transport binds only its *hash part* to what was requested, so a peer can
//! claim any name it likes. Nix independently refuses a substitution whose name
//! does not match the one it asked for, so this is a bound on what a peer may
//! *claim*, and only Nix binds the claim to reality.
//!
//! **This check runs in a process the design calls hostile — but that matters
//! less than it first appears, and the difference is worth stating precisely.**
//!
//! Compromising `oligarchy-p2pd` does *not* on its own let an attacker forge a
//! store path. Nix verifies a signature cryptographically; it does not trust a
//! key *name*. Corrupting the base64 of a `Sig:` line while leaving
//! `cache.nixos.org-1:` in front of it yields `error: signature is not valid`,
//! reproduced on real hardware. A compromised daemon holds no trusted private
//! key, so everything it can serve is either genuinely signed — in which case
//! it is genuine — or refused by nix-daemon. What it gains is denial of service
//! and visibility into which paths this host asks for.
//!
//! So the placement of this check matters in exactly one case: an attacker who
//! holds **both** a trusted peer's private key **and** code execution in this
//! daemon. With the key alone, this check stops them; with the daemon alone,
//! Nix stops them; with both, neither does. That is two compromises, not one,
//! and it is a materially smaller claim than "a daemon RCE is remote root".
//!
//! The architecturally clean version — never put the peer key in
//! `trusted-public-keys`, and have a privileged component re-sign in-scope
//! paths with a key the consumer already trusts — would close even that. It is
//! recorded as gap 38 and deliberately not built: it requires implementing
//! Ed25519 verification and Nix's fingerprint format here, and an IPC channel
//! from a daemon whose `RestrictAddressFamilies` excludes `AF_UNIX` precisely
//! so it can never reach nix-daemon. Paying that to defend against a
//! two-compromise scenario is the wrong trade today.

use crate::narinfo::NarInfo;

/// Why a peer's narinfo was refused.
#[derive(Debug, PartialEq, Eq)]
pub enum Refusal {
    /// A peer key vouches for it, but its name is not in `acceptFromPeers`.
    OutOfScope { name: String },
}

impl std::fmt::Display for Refusal {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Refusal::OutOfScope { name } => write!(
                f,
                "{name:?} is signed by a trusted peer key but is not in \
                 acceptFromPeers; a peer key may only vouch for the packages \
                 you named"
            ),
        }
    }
}

/// The key name of each configured public key — the part before the first
/// colon, which is exactly what a `Sig:` line carries.
pub fn key_names(keys: &[String]) -> Vec<String> {
    keys.iter()
        .filter_map(|k| k.split_once(':').map(|(n, _)| n.trim().to_string()))
        .filter(|n| !n.is_empty())
        .collect()
}

/// Does any signature on this narinfo name a key we trust *because it belongs
/// to a peer*?
///
/// **The inverse formulation is wrong, and wrong in the failing-open
/// direction.** The tempting rule is "scope it only when NO signature names a
/// key outside the peer set" — i.e. treat a `cache.nixos.org-1` signature as
/// proof that upstream vouched for the path. But signatures are attacker-
/// controlled data: a narinfo can carry a forged
/// `Sig: cache.nixos.org-1:<garbage>` alongside a real peer signature. That
/// names a key outside the peer set, so the inverse rule waves it through — and
/// Nix then accepts the path anyway, because `checkSignatures` needs only *one*
/// signature to verify and the peer's does. Distinguishing a forged signature
/// from a real one means doing Ed25519, which this crate deliberately does not
/// do (see the module header of `declared.rs`: Nix does the crypto).
///
/// Asking "is a peer key involved at all" needs no verification and cannot be
/// gamed by *adding* signatures, only by removing them — and removing the peer
/// signature is what makes Nix refuse the path outright.
pub fn mentions_peer_key(ni: &NarInfo, peer_key_names: &[String]) -> bool {
    ni.get_all("Sig").iter().any(|sig| match sig.split_once(':') {
        Some((name, _)) => peer_key_names.iter().any(|k| k == name),
        None => false,
    })
}

/// The package name a store path carries: the basename with the 32-character
/// hash and its separating `-` removed.
fn path_name(store_path: &str) -> &str {
    let base = store_path.rsplit('/').next().unwrap_or(store_path);
    match base.split_once('-') {
        Some((hash, name)) if hash.len() == 32 => name,
        _ => base,
    }
}

/// Is this store path within the scope an operator granted to peer keys?
///
/// Three entry forms, in order of precedence:
///
/// * `"*"` — everything. An explicit, warned-about opt-out of scoping.
/// * a full `/nix/store/...` path — matched exactly. For a pinned flake, where
///   the paths do not move, this is the tightest possible grant.
/// * a bare name — matched against the path's name, exactly or with a version
///   suffix.
///
/// **"Followed by a `-`" is not a sufficient version test, and getting this
/// wrong grants far more than intended.** `glibc-locales-2.40` and
/// `linux-firmware-2024` both begin `glibc-` / `linux-`, so a bare `-` check
/// lets an entry for `glibc` speak for `glibc-locales` — a different package.
/// Nix splits a name into pname and version at the first `-` followed by a
/// non-letter, so this requires the character after the `-` to be a **digit**.
///
/// `my-thing` accepts `my-thing`, `my-thing-1.2.3` and `my-thing-1.2.3-dev`;
/// it does not accept `my-thingamajig`, `glibc-locales-2.40` or
/// `linux-firmware-2024`. The deliberate false negative is an *unversioned*
/// package's extra outputs — `my-thing-dev` with no version does not match
/// `my-thing` — which errs closed and is fixable by naming it exactly.
///
/// A `.drv` is swept in with its output (`hello-2.12.3.drv` matches `hello`),
/// which is what you want when a peer serves both, and is harmless either way:
/// derivations are text-content-addressed, so Nix re-derives their path.
pub fn in_scope(store_path: &str, allow: &[String]) -> bool {
    let name = path_name(store_path);
    allow.iter().any(|entry| {
        let e = entry.trim();
        if e == "*" {
            return true;
        }
        if e.starts_with("/nix/store/") {
            return e == store_path;
        }
        if name == e {
            return true;
        }
        match name.strip_prefix(e).and_then(|r| r.strip_prefix('-')) {
            Some(rest) => rest.starts_with(|c: char| c.is_ascii_digit()),
            None => false,
        }
    })
}

/// How many refusals get a `warn` before the rest drop to `debug`.
///
/// A refusal is remotely triggerable: a hostile peer can answer every request
/// in a closure with an out-of-scope narinfo, and Nix mass-queries closures of
/// thousands of paths. One `warn` per path is journal amplification an attacker
/// controls. The first few are what an operator needs to diagnose the problem;
/// the rest are noise, so they still exist at `debug` but stop filling the log.
const LOUD_REFUSALS: usize = 16;

static REFUSALS: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);

/// Report a refusal, loudly at first and quietly thereafter.
pub fn warn_refusal(peer: &str, hash_part: &str, store_path: &str) {
    let n = REFUSALS.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    if n < LOUD_REFUSALS {
        tracing::warn!(
            peer,
            hash_part,
            store_path,
            "REFUSED a peer narinfo: signed by a trusted peer key but outside \
             acceptFromPeers"
        );
        if n + 1 == LOUD_REFUSALS {
            tracing::warn!(
                "further scope refusals will be logged at debug; a peer is \
                 offering many out-of-scope paths"
            );
        }
    } else {
        tracing::debug!(peer, hash_part, store_path, "refused: out of scope");
    }
}

/// What a peer key is allowed to say, resolved once at startup.
///
/// One value rather than two loose `Vec<String>` arguments, because they are
/// meaningless apart: key names without a scope is the dangerous configuration
/// this module exists to prevent, and a scope without key names never fires.
#[derive(Debug, Clone, Default)]
pub struct PeerScope {
    key_names: Vec<String>,
    allow: Vec<String>,
}

impl PeerScope {
    pub fn new(peer_public_keys: &[String], accept_from_peers: &[String]) -> Self {
        Self {
            key_names: key_names(peer_public_keys),
            allow: accept_from_peers.to_vec(),
        }
    }

    /// Whether any peer key is trusted at all. With none — stages 1 through 4,
    /// and every host that has not opted in — nothing is ever scoped and this
    /// whole module is inert.
    pub fn is_active(&self) -> bool {
        !self.key_names.is_empty()
    }

    /// A one-line description for `status` and `selftest`.
    pub fn describe(&self) -> String {
        if !self.is_active() {
            return "no peer keys trusted".to_string();
        }
        if self.allow.iter().any(|e| e.trim() == "*") {
            return format!("{} peer key(s), UNSCOPED (*)", self.key_names.len());
        }
        format!("{} peer key(s), scoped to: {}", self.key_names.len(), self.allow.join(" "))
    }

    pub fn check(&self, ni: &NarInfo) -> Result<(), Refusal> {
        accept_peer_narinfo(ni, &self.key_names, &self.allow)
    }
}

/// The single decision: may we accept this narinfo from a peer?
///
/// Called on the way in, before the narinfo is persisted or memoised — and
/// again when one is read back off disk, because a poisoned cache entry is
/// durable and tier 2 would otherwise serve it forever without ever consulting
/// the transport again.
pub fn accept_peer_narinfo(
    ni: &NarInfo,
    peer_key_names: &[String],
    allow: &[String],
) -> Result<(), Refusal> {
    if !mentions_peer_key(ni, peer_key_names) {
        // Either upstream vouched for it, or nobody Nix trusts did — in which
        // case Nix refuses it downstream and we need no opinion. This is the
        // ordinary stage 3/4 relay case and must stay unrestricted, or a peer
        // could no longer hand us a cached copy of an upstream path offline.
        return Ok(());
    }
    if in_scope(ni.store_path(), allow) {
        return Ok(());
    }
    Err(Refusal::OutOfScope { name: path_name(ni.store_path()).to_string() })
}

#[cfg(test)]
mod tests_support {
    use super::*;
    pub const HP: &str = "18bbdvag5v2f3d4y37pdbkzvh7s71cw4";
    pub fn ni(store_name: &str, sigs: &[&str]) -> NarInfo {
        let mut s = format!(
            "StorePath: /nix/store/{HP}-{store_name}\n\
             URL: nar/{HP}/0k8cwb9i02mp6zi35ip898zwnd16xj89mbipw1fvrklpd9qmm7xv.nar\n\
             Compression: none\n\
             NarHash: sha256:0k8cwb9i02mp6zi35ip898zwnd16xj89mbipw1fvrklpd9qmm7xv\n\
             NarSize: 274568\n\
             References: \n"
        );
        for g in sigs { s.push_str(&format!("Sig: {g}\n")); }
        NarInfo::parse(&s).unwrap()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use super::tests_support::*;

    fn peers() -> Vec<String> {
        key_names(&["nixos-p2p-1:AAAA==".to_string()])
    }

    #[test]
    fn an_inactive_scope_is_inert() {
        let sc = PeerScope::new(&[], &[]);
        assert!(!sc.is_active());
        assert_eq!(sc.check(&ni("glibc-2.40-224", &["anyone-1:AAAA=="])), Ok(()));
        assert_eq!(sc.describe(), "no peer keys trusted");
    }

    #[test]
    fn describe_names_the_wildcard_for_what_it_is() {
        let sc = PeerScope::new(&["k-1:AAAA==".into()], &["*".into()]);
        assert!(sc.describe().contains("UNSCOPED"));
    }

    #[test]
    fn a_key_name_is_the_part_before_the_colon() {
        assert_eq!(key_names(&["a-1:XYZ==".into(), "b-2:Q==".into()]), vec!["a-1", "b-2"]);
        // Garbage entries are dropped rather than becoming an empty name that
        // would match a malformed `Sig:` line.
        assert!(key_names(&["no-colon".into(), ":empty".into()]).is_empty());
    }

    #[test]
    fn an_upstream_relayed_narinfo_is_never_scoped() {
        // Stage 3/4 behaviour: a peer handing us its cached copy of an
        // upstream path. Restricting this would break offline substitution,
        // which is the entire reason the peer narinfo leg exists.
        let n = ni("hello-2.12.2", &["cache.nixos.org-1:BBBB=="]);
        assert!(!mentions_peer_key(&n, &peers()));
        assert_eq!(accept_peer_narinfo(&n, &peers(), &[]), Ok(()));
    }

    #[test]
    fn a_peer_minted_narinfo_must_be_in_scope() {
        let n = ni("my-thing-1.2.3", &["nixos-p2p-1:AAAA=="]);
        assert_eq!(
            accept_peer_narinfo(&n, &peers(), &["other".into()]),
            Err(Refusal::OutOfScope { name: "my-thing-1.2.3".into() })
        );
        assert_eq!(accept_peer_narinfo(&n, &peers(), &["my-thing".into()]), Ok(()));
    }

    #[test]
    fn a_forged_upstream_signature_does_not_lift_the_scope() {
        // THE hole in the obvious formulation. An attacker appends a garbage
        // `cache.nixos.org-1` line, so "is there a signature by a non-peer
        // key?" says yes and waves it through — while Nix accepts the path on
        // the strength of the peer signature, which is real. We cannot tell the
        // forged one from the real one without doing Ed25519, so the rule must
        // not depend on being able to.
        let n = ni("glibc-2.40-224", &["cache.nixos.org-1:FORGED==", "nixos-p2p-1:AAAA=="]);
        assert!(mentions_peer_key(&n, &peers()));
        assert!(accept_peer_narinfo(&n, &peers(), &["my-thing".into()]).is_err());
    }

    #[test]
    fn the_attack_this_exists_to_stop() {
        // A compromised seeder mints glibc. Priority 30 means the adapter is
        // asked before cache.nixos.org, so without this check the consumer
        // installs it.
        let n = ni("glibc-2.40-224", &["nixos-p2p-1:AAAA=="]);
        assert!(accept_peer_narinfo(&n, &peers(), &["my-thing".into()]).is_err());
    }

    #[test]
    fn a_version_suffix_matches_but_a_longer_name_does_not() {
        assert!(in_scope(&format!("/nix/store/{HP}-my-thing"), &["my-thing".into()]));
        assert!(in_scope(&format!("/nix/store/{HP}-my-thing-1.2.3"), &["my-thing".into()]));
        assert!(in_scope(&format!("/nix/store/{HP}-my-thing-1.2.3-dev"), &["my-thing".into()]));
        // A `-` alone is NOT enough, and these are real nixpkgs names: both
        // begin with the entry followed by `-`, and both are different
        // packages. Requiring a digit after the `-` is what separates a
        // version suffix from a longer package name.
        assert!(!in_scope(&format!("/nix/store/{HP}-my-thingamajig"), &["my-thing".into()]));
        assert!(!in_scope(&format!("/nix/store/{HP}-glibc-locales-2.40"), &["glibc".into()]));
        assert!(!in_scope(&format!("/nix/store/{HP}-linux-firmware-2024"), &["linux".into()]));
    }

    #[test]
    fn an_unversioned_package_needs_its_exact_name() {
        // Recorded rather than accidental. Without a version there is no digit
        // to anchor on, so `my-thing` does not reach `my-thing-dev`. That errs
        // closed; name it exactly, or pin the store path.
        assert!(in_scope(&format!("/nix/store/{HP}-p2p-seed-probe"), &["p2p-seed-probe".into()]));
        assert!(!in_scope(&format!("/nix/store/{HP}-my-thing-dev"), &["my-thing".into()]));
    }

    #[test]
    fn a_full_store_path_entry_matches_exactly() {
        let p = format!("/nix/store/{HP}-my-thing-1.2.3");
        assert!(in_scope(&p, &[p.clone()]));
        // A different path with the same name is NOT granted by a pinned entry.
        let other = format!("/nix/store/{}-my-thing-1.2.3", "a".repeat(32));
        assert!(!in_scope(&other, &[p]));
    }

    #[test]
    fn the_wildcard_is_explicit_and_total() {
        assert!(in_scope(&format!("/nix/store/{HP}-anything-at-all"), &["*".into()]));
        let n = ni("glibc-2.40-224", &["nixos-p2p-1:AAAA=="]);
        assert_eq!(accept_peer_narinfo(&n, &peers(), &["*".into()]), Ok(()));
    }

    #[test]
    fn an_empty_scope_refuses_everything_a_peer_key_signed() {
        // The module asserts this configuration is unreachable, but the daemon
        // must fail closed rather than open if it is ever reached.
        let n = ni("my-thing-1.2.3", &["nixos-p2p-1:AAAA=="]);
        assert!(accept_peer_narinfo(&n, &peers(), &[]).is_err());
    }

    #[test]
    fn with_no_peer_keys_configured_nothing_is_scoped() {
        // Stages 1-4: `trustedPublicKeys` empty, so no key is trusted because
        // of a peer and there is nothing to scope. Every existing gate lands
        // here, and their behaviour must be bit-identical to before.
        let n = ni("hello-2.12.2", &["cache.nixos.org-1:BBBB=="]);
        assert_eq!(accept_peer_narinfo(&n, &[], &[]), Ok(()));
        let m = ni("my-thing-1.2.3", &["somebody-1:AAAA=="]);
        assert_eq!(accept_peer_narinfo(&m, &[], &[]), Ok(()));
    }

    #[test]
    fn a_narinfo_with_no_signature_is_not_scoped() {
        // Nix refuses an unsigned path anyway, so we need no opinion — and
        // taking one would mean scoping content-addressed paths, whose anchor
        // is the store path name that Nix recomputes.
        let n = ni("my-thing-1.2.3", &[]);
        assert!(!mentions_peer_key(&n, &peers()));
        assert_eq!(accept_peer_narinfo(&n, &peers(), &[]), Ok(()));
    }
}

#[cfg(test)]
mod adversarial {
    use super::*;
    use super::tests_support::*;

    /// The bypass an adversarial review found in the FIRST formulation of this
    /// rule. Kept as a test because the broken version is the intuitive one and
    /// somebody will propose it again.
    #[test]
    fn appending_a_junk_upstream_signature_does_not_lift_the_scope() {
        let peers = key_names(&["K-1:REAL==".to_string()]);
        // A real peer signature over a malicious glibc, plus one line of pure
        // garbage naming cache.nixos.org. Nix COUNTS good signatures rather
        // than requiring all of them to verify, so the junk line costs the
        // attacker nothing and the real one gets the path registered.
        let n = ni("glibc-2.40-224", &["K-1:REAL==", "cache.nixos.org-1:AAAAAAAA"]);
        assert!(
            accept_peer_narinfo(&n, &peers, &["my-thing".into()]).is_err(),
            "a junk signature disabled the scope check"
        );
    }
}
