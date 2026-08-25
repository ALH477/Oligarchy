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
                if path.starts_with(forbidden.as_str()) {
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
    fn forbidden_paths_are_prefixes() {
        let p = Policy::default();
        let mut m = manifest(Tier::Wasm, Jit::None, Trust::Untrusted);
        m.caps.fs_read.push("/run/secrets/guitar-key".into());
        assert!(p.authorize(&m).is_err());
    }

    #[test]
    fn min_trust_ordering() {
        let mut p = Policy::default();
        p.min_trust = Trust::Trusted;
        assert!(p.authorize(&manifest(Tier::Wasm, Jit::None, Trust::Untrusted)).is_err());
        assert!(p.authorize(&manifest(Tier::Wasm, Jit::None, Trust::FirstParty)).is_ok());
    }
}
