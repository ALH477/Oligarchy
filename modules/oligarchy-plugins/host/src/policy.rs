//! Host policy: the declarative half of the system.
//!
//! Written by the NixOS module to /etc/oligarchy/plugins/policy.json, read
//! by plugind at every load. This is the seam between "what the machine
//! permits" (declarative, in the flake, reproducible, reviewed) and "what
//! the user installed" (imperative, mutable, at runtime).
//!
//! The manifest is the plugin author's *request*. This file is the machine
//! owner's *answer*. The manifest can never widen what policy allows.

use anyhow::{bail, Result};
use serde::{Deserialize, Serialize};
use std::path::Path;

use crate::manifest::{Jit, Manifest, Tier, Trust};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields, default)]
pub struct Policy {
    /// Master switch for plugin-supplied JITs. Off means no plugin on this
    /// machine gets W^X memory on the host, at any trust level. A locked-down
    /// stage rig should ship with this false.
    pub allow_self_jit: bool,
    /// Whether tier=microvm may be used at all (requires KVM + microvm.nix).
    pub allow_microvm: bool,
    /// Minimum trust level required to load anything.
    pub min_trust: Trust,
    /// Tiers permitted on this host.
    pub allowed_tiers: Vec<Tier>,
    /// Refuse to load anything not signed by one of these.
    pub require_signature: bool,
    /// The ONLY keys whose signatures make a path installable.
    ///
    /// Written by the NixOS module from `custom.plugins.trustedPublicKeys`.
    /// Deliberately not "whatever the system trusts": nix.settings legitimately
    /// carries cache.nixos.org and, on a Determinate host, nine flakehub keys —
    /// and a plugin signed by cache.nixos.org is not a plugin this host has
    /// approved. plugind pins this set on the verifying subprocess and also
    /// requires that a *present* signature name a key from it. See
    /// verify_signature().
    pub trusted_public_keys: Vec<String>,
    /// Ceiling on what a manifest may request, regardless of what it asks.
    pub max_memory: u64,
    pub max_cpu_quota: u32,
    /// Paths a plugin may never name in caps, even read-only. Manifest paths
    /// are checked against these prefixes before Landlock ever sees them.
    pub forbidden_paths: Vec<String>,
    /// If false, `network = true` in a manifest is an error rather than a
    /// request.
    pub allow_network: bool,
}

impl Default for Policy {
    fn default() -> Self {
        // Defaults are the hardened position. The module opts *out*, never in.
        Policy {
            allow_self_jit: false,
            allow_microvm: false,
            min_trust: Trust::Untrusted,
            allowed_tiers: vec![Tier::Wasm],
            require_signature: true,
            trusted_public_keys: vec![],
            max_memory: 256 << 20,
            max_cpu_quota: 100,
            forbidden_paths: vec![
                "/etc/ssh".into(),
                "/etc/shadow".into(),
                "/var/lib/sops".into(),
                "/run/secrets".into(),
                "/root".into(),
                "/home".into(),
            ],
            allow_network: false,
        }
    }
}

/// What to do about a path's signature.
#[derive(Debug, PartialEq, Eq)]
pub enum SigVerdict {
    Accept,
    /// Policy requires a signature, so nothing the caller can pass helps.
    PolicyRequiresSignature,
    /// Policy tolerates unsigned paths, but the caller has to say so.
    NeedsExplicitFlag,
}

impl Policy {
    pub fn load(path: &Path) -> Result<Self> {
        match std::fs::read_to_string(path) {
            Ok(s) => Ok(serde_json::from_str(&s)?),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                tracing::warn!(
                    path = %path.display(),
                    "no policy file; falling back to hardened defaults \
                     (wasm only, no self-JIT, signatures required)"
                );
                Ok(Policy::default())
            }
            Err(e) => Err(e.into()),
        }
    }

    /// The other half of the gate: may a path with this signature status be
    /// registered at all?
    ///
    /// Lives here rather than in the registry because it is the same kind of
    /// statement as `authorize` — the machine owner's answer, not the caller's
    /// request — and because keeping it a pure function over the Policy makes
    /// the whole truth table testable without a store, a daemon or a key.
    ///
    /// The row that matters is the middle one: policy outranks the CLI. If
    /// `--allow-unsigned` could win here, the declarative half of this design
    /// would be advisory and the flag a rebuild-free way around it.
    pub fn authorize_signature(&self, verified: bool, allow_unsigned: bool) -> SigVerdict {
        if verified {
            SigVerdict::Accept
        } else if self.require_signature {
            SigVerdict::PolicyRequiresSignature
        } else if allow_unsigned {
            SigVerdict::Accept
        } else {
            SigVerdict::NeedsExplicitFlag
        }
    }

    /// The gate. Called before any artifact is opened.
    pub fn authorize(&self, m: &Manifest) -> Result<()> {
        if !self.allowed_tiers.contains(&m.tier) {
            bail!(
                "tier {:?} is not enabled on this host (allowed: {:?}). \
                 Set custom.plugins.allowedTiers in your NixOS config.",
                m.tier,
                self.allowed_tiers
            );
        }

        if m.tier == Tier::Microvm && !self.allow_microvm {
            bail!("tier=microvm requires custom.plugins.microvm.enable = true");
        }

        if m.jit == Jit::SelfJit && !self.allow_self_jit {
            bail!(
                "plugin {} requests jit=self but custom.plugins.allowSelfJit is \
                 false. This host will not grant writable-executable memory to \
                 plugin code.",
                m.id
            );
        }

        // Trust is ordered FirstParty < Trusted < Untrusted, so a *higher*
        // discriminant is less trusted.
        if m.trust > self.min_trust {
            bail!(
                "plugin {} declares trust={:?}, host requires at least {:?}",
                m.id,
                m.trust,
                self.min_trust
            );
        }

        if m.caps.network && !self.allow_network {
            bail!(
                "plugin {} requests network access; custom.plugins.allowNetwork \
                 is false",
                m.id
            );
        }

        if let Some(req) = m.caps.memory_max {
            if req > self.max_memory {
                bail!(
                    "plugin {} requests {} bytes, host ceiling is {}",
                    m.id,
                    req,
                    self.max_memory
                );
            }
        }
        if let Some(q) = m.caps.cpu_quota {
            if q > self.max_cpu_quota {
                bail!("plugin {} requests {q}% CPU, host ceiling is {}%", m.id, self.max_cpu_quota);
            }
        }

        for path in m.caps.fs_read.iter().chain(m.caps.fs_read_write.iter()) {
            for forbidden in &self.forbidden_paths {
                if is_under(path, forbidden) {
                    bail!(
                        "plugin {} requests access to {path:?}, which is under the \
                         forbidden prefix {forbidden:?}",
                        m.id
                    );
                }
            }
        }

        Ok(())
    }
}

/// Is `path` at or under `prefix`, comparing path components?
///
/// A raw `str::starts_with` gets this wrong in both directions, and both
/// mistakes matter. `"//home/asher/.ssh"` and `"/./home/asher/.ssh"` are the
/// same path to the kernel but do not start with `"/home"`, so a plugin could
/// name a forbidden directory and be waved through to Landlock. Meanwhile
/// `"/homework"` *does* start with `"/home"` and would be refused for no
/// reason.
///
/// `Path::components` normalises away empty and `.` components for us. `..` is
/// deliberately NOT resolved — that needs the filesystem, and a capability
/// containing `..` is a manifest bug worth refusing outright rather than
/// silently interpreting.
fn is_under(path: &str, prefix: &str) -> bool {
    use std::path::{Component, Path};
    if path.split('/').any(|c| c == "..") {
        // Cannot be reasoned about without touching the filesystem. Treat as
        // matching every prefix so it is always refused.
        return true;
    }
    let mut p = Path::new(path).components();
    for want in Path::new(prefix).components() {
        match (p.next(), want) {
            (Some(Component::Normal(a)), Component::Normal(b)) if a == b => {}
            (Some(Component::RootDir), Component::RootDir) => {}
            _ => return false,
        }
    }
    true
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::manifest::Caps;

    fn manifest(tier: Tier, jit: Jit, trust: Trust) -> Manifest {
        Manifest {
            id: "t".into(),
            version: "1".into(),
            tier,
            jit,
            trust,
            entry: "x".into(),
            abi: crate::manifest::SUPPORTED_ABI.into(),
            caps: Caps::default(),
            meta: Default::default(),
        }
    }

    #[test]
    fn default_policy_refuses_self_jit() {
        let p = Policy::default();
        let m = manifest(Tier::Native, Jit::SelfJit, Trust::FirstParty);
        assert!(p.authorize(&m).is_err());
    }

    #[test]
    fn default_policy_allows_plain_wasm() {
        let p = Policy::default();
        let m = manifest(Tier::Wasm, Jit::Host, Trust::Untrusted);
        assert!(p.authorize(&m).is_ok());
    }

    #[test]
    fn is_under_compares_components_not_bytes() {
        // The two directions a byte-prefix test gets wrong.
        assert!(is_under("/home/asher/.ssh", "/home"));
        assert!(is_under("//home/asher/.ssh", "/home"));
        assert!(is_under("/./home/asher/.ssh", "/home"));
        assert!(!is_under("/homework/notes", "/home"));
        assert!(is_under("/home", "/home"));
        // `..` is refused rather than resolved.
        assert!(is_under("/tmp/../home", "/anything"));
    }

    #[test]
    fn forbidden_paths_are_prefixes() {
        let p = Policy::default();
        let mut m = manifest(Tier::Wasm, Jit::None, Trust::Untrusted);
        m.caps.fs_read.push("/run/secrets/guitar-key".into());
        assert!(p.authorize(&m).is_err());
    }

    #[test]
    fn a_signed_path_is_accepted_regardless_of_flags() {
        for require in [true, false] {
            for flag in [true, false] {
                let mut p = Policy::default();
                p.require_signature = require;
                assert_eq!(
                    p.authorize_signature(true, flag),
                    SigVerdict::Accept,
                    "verified path refused with require={require} flag={flag}"
                );
            }
        }
    }

    #[test]
    fn allow_unsigned_cannot_override_policy() {
        // The rule stage 2 exists to make true. An unprivileged caller cannot
        // even encode the flag (see control.rs), but root can — and on a
        // requireSignature host it must still lose.
        let p = Policy::default(); // require_signature = true
        assert!(p.require_signature);
        assert_eq!(
            p.authorize_signature(false, true),
            SigVerdict::PolicyRequiresSignature
        );
        assert_eq!(
            p.authorize_signature(false, false),
            SigVerdict::PolicyRequiresSignature
        );
    }

    #[test]
    fn unsigned_needs_saying_so_even_where_permitted() {
        let mut p = Policy::default();
        p.require_signature = false;
        assert_eq!(
            p.authorize_signature(false, false),
            SigVerdict::NeedsExplicitFlag
        );
        assert_eq!(p.authorize_signature(false, true), SigVerdict::Accept);
    }

    #[test]
    fn min_trust_ordering() {
        let mut p = Policy::default();
        p.min_trust = Trust::Trusted;
        assert!(p.authorize(&manifest(Tier::Wasm, Jit::None, Trust::Untrusted)).is_err());
        assert!(p.authorize(&manifest(Tier::Wasm, Jit::None, Trust::FirstParty)).is_ok());
    }
}
