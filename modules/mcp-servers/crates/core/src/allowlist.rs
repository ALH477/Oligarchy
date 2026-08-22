//! Per-aspect CLI allowlists.
//!
//! Every aspect crate reaches a CLI through `runner::run(ASPECT, prog, ..)`,
//! which refuses and audit-logs any `prog` not in that aspect's const below.
//! That check is at RUNTIME. The build-time gates
//! (`crates/core/tests/no_open_sockets.rs` and the `mcp_self_audit` tool in
//! `crates/ports-sec`, run by `nix build .#mcp-self-audit`) scan every crate's
//! source for socket and HTTP-client patterns — they do NOT currently verify
//! `Command::new` literals against these lists, so a crate that bypasses
//! `runner::run` and spawns a process directly would slip past them.
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
    // `oligarchy-blocklist status` / `test <ip>` only — both read-only. The
    // `update` and `panic` verbs mutate, so they are never passed from here.
    "oligarchy-blocklist",
];

/// CLIs the `dcf` aspect may invoke.
///
/// `hydramesh-status` / `hydramesh-peers` were removed: they never existed on
/// the host. They are docker wrappers declared only inside the ArchibaldOS
/// guest flake (`modules/ArchibaldOS/modules/hydramesh.nix`), whose input is
/// not wired into the top-level flake — and `hydramesh-peers` was never defined
/// anywhere at all. The mesh surface now lives in the `hydramesh` aspect.
pub const DCF: &[&str] = &[
    "hydramesh",
    "oligarchy-ctl",
    "systemctl",
    "docker",
];

/// CLIs the `hydramesh` aspect may invoke.
///
/// The transmit-side HydraModem tools (`frame_tx`, `tx_campaign`, `sense_node`,
/// `sstv_send`, …) are deliberately absent: they put energy on the audio/RF
/// plane and have no place behind a read-only surface. `dcf_loopback` is a
/// purely local DSP self-test and is additionally guarded by a confirmation
/// argument in the tool itself.
pub const HYDRAMESH: &[&str] = &[
    "hydramesh",
    "dcf",
    "dcf_loopback",
    "systemctl",
    "docker",
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

/// Every known aspect name. The umbrella router (`crates/umbrella`), the
/// sub-flake's `aspectNames` and `nixos-module.nix`'s `aspectNames` must agree
/// with this list.
pub const ASPECTS: &[&str] = &[
    "system",
    "net",
    "dcf",
    "dsp",
    "ai",
    "secrets",
    "vm",
    "ports-sec",
    "hydramesh",
];

/// The allowlist for `aspect`, or `None` if the aspect is unknown. Single
/// source of truth — `is_allowed` and the tests both go through this, so a new
/// aspect cannot be half-registered.
pub fn list_for(aspect: &str) -> Option<&'static [&'static str]> {
    Some(match aspect {
        "system" => SYSTEM,
        "net" => NET,
        "dcf" => DCF,
        "dsp" => DSP,
        "ai" => AI,
        "secrets" => SECRETS,
        "vm" => VM,
        "ports-sec" => PORTS_SEC,
        "hydramesh" => HYDRAMESH,
        _ => return None,
    })
}

/// Returns true if `prog` is allowed for `aspect`.
pub fn is_allowed(aspect: &str, prog: &str) -> bool {
    list_for(aspect).is_some_and(|list| list.contains(&prog))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn known_aspects_have_nonempty_allowlists() {
        for aspect in ASPECTS {
            let list = list_for(aspect)
                .unwrap_or_else(|| panic!("aspect {aspect} is in ASPECTS but has no allowlist"));
            assert!(!list.is_empty(), "aspect {aspect} has an empty allowlist");
        }
    }

    #[test]
    fn is_allowed_rejects_unknown_aspect() {
        assert!(!is_allowed("bogus", "ls"));
        assert!(list_for("bogus").is_none());
    }

    #[test]
    fn dcf_does_not_reference_phantom_binaries() {
        // These were never installed on the host — they are docker wrappers
        // from the ArchibaldOS guest flake, and `hydramesh-peers` never
        // existed at all. Guard against them creeping back in.
        for phantom in ["hydramesh-status", "hydramesh-peers"] {
            assert!(!DCF.contains(&phantom), "{phantom} does not exist on PATH");
            assert!(!HYDRAMESH.contains(&phantom), "{phantom} does not exist on PATH");
        }
    }
}