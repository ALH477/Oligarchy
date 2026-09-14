//! `egress_coverage` — compares the well-known endpoints table against the
//! live strict-egress ruleset. Reports **gaps** (an API that listens but
//! whose remote endpoints aren't on the allowlist) and **proposes** exact
//! `nft add element …` lines as text — never applies them.

use crate::known_endpoints::{KNOWN, summary};
use oligarchy_mcp_core::runner::{self, QUICK_TIMEOUT};
use std::collections::HashSet;

pub fn report() -> String {
    // Pull the live ruleset so we can diff our expected remotes against it.
    let live = runner::run(
        "ports-sec",
        "nft",
        &["-j", "list", "table", "inet", "strict-egress"],
        QUICK_TIMEOUT,
    )
    .unwrap_or_else(|e| format!("[no strict-egress table: {e}]"));

    // Extract quoted hostname tokens from the resolver log too.
    let resolved = runner::run(
        "ports-sec",
        "cat",
        &["/run/strict-egress/resolved.txt"],
        QUICK_TIMEOUT,
    )
    .unwrap_or_default();

    let live_tokens = allowed_tokens(&live, &resolved);
    let mut out = String::from("── egress coverage vs known endpoints ──────────────\n");
    let mut gaps = Vec::new();
    let mut proposals = String::new();
    for ep in KNOWN {
        out.push_str(&summary(ep));
        out.push('\n');
        for remote in ep.remote_endpoints {
            if !live_tokens.contains(*remote) {
                gaps.push((ep.name, remote));
                proposals.push_str(&format!(
                    "# gap: {} expects {} — propose:\n",
                    ep.name, remote
                ));
                proposals.push_str(&format!(
                    "  sudo nft add element inet strict-egress egress_dyn4 \"{{ <{remote}-IP> timeout 26h }}\"\n"
                ));
                proposals.push_str(&format!(
                    "  (and add \"{remote}\" to networking.firewall.strictEgress.allow.domains so it stays re-resolved)\n"
                ));
            }
        }
    }

    if gaps.is_empty() {
        out.push_str("\n[gaps] none — every known remote endpoint is covered by the ruleset.\n");
    } else {
        out.push_str(&format!("\n[gaps] {} remote-host entr{} missing from the live ruleset:\n",
            gaps.len(), if gaps.len() == 1 { "y is" } else { "ies are" }));
        for (name, remote) in &gaps {
            out.push_str(&format!("  - {name} -> {remote}\n"));
        }
        out.push_str("\n── proposed nft add element lines (NOT applied) ────────\n");
        out.push_str(&proposals);
    }
    out
}

/// Reduce the live ruleset JSON + resolver log into the set of hostnames
/// already covered. A hostname counts only when it appears in the resolver
/// log AND at least one of its resolved IPs is currently a set element in
/// the table — earlier this checked the log alone, so a domain whose nft
/// set was emptied (table recreated, another module fighting nftables)
/// still reported "covered by the ruleset" while the ruleset held nothing.
fn allowed_tokens<'a>(live: &str, resolved: &'a str) -> HashSet<&'a str> {
    let mut allowed: HashSet<&'a str> = HashSet::new();
    let table_present = !live.starts_with("[no strict-egress table");
    for line in resolved.lines() {
        // Line shape from strict-egress-resolve is exactly "<hostname> <ip>",
        // one line per answer (`echo "$domain $ip" >> resolved.txt.new`).
        let mut it = line.split_whitespace();
        let (Some(host), Some(ip)) = (it.next(), it.next()) else { continue };
        // Without a live table nothing is covered, no matter what the log
        // says about what was resolved a moment ago.
        if !table_present {
            break;
        }
        if live.contains(ip) {
            allowed.insert(host);
        }
    }
    allowed
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reports_some_text() {
        // Just smoke: with no real ruleset the function still returns text.
        let r = report();
        assert!(r.contains("egress coverage"));
    }
}