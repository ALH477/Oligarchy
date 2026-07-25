//! Per-aspect CLI allowlists.
//!
//! Every aspect crate's `Command::new(prog)` argument MUST appear in its
//! aspect's `ALLOWLIST` const. A per-crate unit test asserts this by scanning
//! the crate's source tree for `Command::new("...")` literals and rejecting
//! any not listed here. The `mcp_self_audit` tool in `crates/ports-sec` runs
//! the same scan at the project level for the build gate
//! (`nix build .#mcp-self-audit`).
//!
//! Adding a new CLI to an aspect means editing this file. That is intentional:
//! capability changes are reviewable diffs in one place.

/// CLIs the `system` aspect may invoke.
pub const SYSTEM: &[&str] = &[
    "oligarchy-ctl",
    "systemctl",
    "journalctl",
    "nixos-rebuild",
    "nix",
    "nixfmt",
    "read",
    "fd",
];

/// CLIs the `net` aspect may invoke.
pub const NET: &[&str] = &[
    "strict-egress-status",
    "strict-egress-test",
    "nft",
    "resolvectl",
    "ip",
    "demod-ip-blocker",
];

/// CLIs the `dcf` aspect may invoke.
pub const DCF: &[&str] = &[
    "hydramesh-status",
    "hydramesh-peers",
    "oligarchy-ctl",
    "systemctl",
];

/// CLIs the `dsp` aspect may invoke.
pub const DSP: &[&str] = &[
    "dsp-status",
    "pw-cli",
    "pw-top",
    "vm-manager",
    "dsp-ctl",
];

/// CLIs the `ai` aspect may invoke.
pub const AI: &[&str] = &[
    "ai-stack",
    "ollama",
    "systemctl",
];

/// CLIs the `secrets` aspect may invoke. No decrypt path is permitted.
pub const SECRETS: &[&str] = &[
    "sops-blackbox-ls",
    "age",
];

/// CLIs the `vm` aspect may invoke.
pub const VM: &[&str] = &[
    "vm-manager",
    "quickemu",
    "virsh",
    "dsp-ctl",
];

/// CLIs the `ports-sec` aspect may invoke. `nmap` is the only network-active
/// CLI; everything else is read-only (`nft list`, `ip`, `cat`).
pub const PORTS_SEC: &[&str] = &[
    "nft",
    "ip",
    "cat",
    "nmap",
];

/// Returns true if `prog` is allowed for `aspect`.
pub fn is_allowed(aspect: &str, prog: &str) -> bool {
    let list = match aspect {
        "system" => SYSTEM,
        "net" => NET,
        "dcf" => DCF,
        "dsp" => DSP,
        "ai" => AI,
        "secrets" => SECRETS,
        "vm" => VM,
        "ports-sec" => PORTS_SEC,
        _ => return false,
    };
    list.contains(&prog)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn known_aspects_have_nonempty_allowlists() {
        for aspect in [
            "system", "net", "dcf", "dsp", "ai", "secrets", "vm", "ports-sec",
        ] {
            assert!(!match aspect {
                "system" => SYSTEM,
                "net" => NET,
                "dcf" => DCF,
                "dsp" => DSP,
                "ai" => AI,
                "secrets" => SECRETS,
                "vm" => VM,
                "ports-sec" => PORTS_SEC,
                _ => &[],
            }.is_empty(), "aspect {aspect} has an empty allowlist");
        }
    }

    #[test]
    fn is_allowed_rejects_unknown_aspect() {
        assert!(!is_allowed("bogus", "ls"));
    }
}