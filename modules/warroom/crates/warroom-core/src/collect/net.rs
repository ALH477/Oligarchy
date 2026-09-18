//! NET collector — `nmcli` + strict-egress summary
//!
//! OWNER: work stream S1.
//!
//! Two `nmcli -t` calls. Terse mode is used rather than the default table
//! because the default is localised and column-aligned; terse is a stable,
//! colon-separated machine format. It escapes a literal colon inside a field as
//! `\:` and a literal backslash as `\\`, so the splitter here is escape-aware —
//! a naive `split(':')` shreds any connection whose name contains a colon,
//! which is legal and common for VPN profiles.
//!
//! The egress mode is read from the security status cache rather than by
//! shelling out: `nft list chain` needs root and `strict-egress-status` is
//! another fork. It is already computed for us every 5 minutes.

use crate::model::{Availability, Health, Panel};
use serde_json::Value;
use std::time::Duration;

const TIMEOUT: Duration = Duration::from_secs(3);

pub struct NetCollector {
    _priv: (),
}

impl NetCollector {
    pub fn new() -> Self {
        NetCollector { _priv: () }
    }
}

impl Default for NetCollector {
    fn default() -> Self {
        Self::new()
    }
}

/// Split one `nmcli -t` record into fields, honouring `\:` and `\\`.
fn split_terse(line: &str) -> Vec<String> {
    let mut fields = Vec::new();
    let mut cur = String::new();
    let mut chars = line.chars();
    while let Some(c) = chars.next() {
        match c {
            '\\' => match chars.next() {
                // A trailing lone backslash is kept literally rather than
                // swallowing the end of the record.
                None => cur.push('\\'),
                Some(next) => cur.push(next),
            },
            ':' => fields.push(std::mem::take(&mut cur)),
            other => cur.push(other),
        }
    }
    fields.push(cur);
    fields
}

/// `nmcli -t -f STATE,CONNECTIVITY general` -> `("connected", "full")`.
fn parse_general(out: &str) -> Option<(String, String)> {
    let line = out.lines().map(str::trim).find(|l| !l.is_empty())?;
    let f = split_terse(line);
    if f.len() < 2 {
        return None;
    }
    Some((f[0].clone(), f[1].clone()))
}

/// `nmcli -t -f NAME,TYPE,DEVICE connection show --active`.
fn parse_connections(out: &str) -> Vec<Vec<String>> {
    out.lines()
        .map(str::trim)
        .filter(|l| !l.is_empty())
        .filter_map(|l| {
            let f = split_terse(l);
            (f.len() >= 3).then(|| vec![f[0].clone(), f[1].clone(), f[2].clone()])
        })
        .collect()
}

/// NetworkManager's connectivity vocabulary. `unknown` is what NM reports when
/// its connectivity check is disabled — common, and genuinely "we do not know",
/// so it must not be Good.
fn connectivity_health(v: &str) -> Health {
    match v {
        "full" => Health::Good,
        "limited" | "portal" => Health::Warn,
        "none" => Health::Bad,
        _ => Health::Unknown,
    }
}

fn state_health(v: &str) -> Health {
    match v {
        "connected" => Health::Good,
        "connected (site only)" | "connected (local only)" | "connecting" => Health::Warn,
        "disconnected" | "asleep" => Health::Bad,
        _ => Health::Unknown,
    }
}

/// Read the strict-egress mode out of the security cache. Free — the file is
/// already on tmpfs and refreshed by a timer. `None` when the cache is absent,
/// which is not an error here: strict-egress is optional.
fn egress_mode() -> Option<String> {
    let raw = std::fs::read_to_string(super::security::SECURITY_CACHE).ok()?;
    let v: Value = serde_json::from_str(&raw).ok()?;
    v.get("egress")
        .and_then(Value::as_str)
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

/// Loopback is not connectivity. A host whose only "active connection" is `lo`
/// is offline, and counting it would report 1 connection on an unplugged
/// laptop.
fn is_real_link(conn_type: &str, device: &str) -> bool {
    conn_type != "loopback" && device != "lo"
}

impl super::Collector for NetCollector {
    fn id(&self) -> &'static str {
        "net"
    }

    fn title(&self) -> &'static str {
        "NET"
    }

    fn interval(&self) -> Duration {
        Duration::from_secs(10)
    }

    fn probe(&self) -> Availability {
        match crate::exec::which("nmcli") {
            Some(_) => Availability::Present,
            None => Availability::Missing("nmcli not installed"),
        }
    }

    fn collect(&mut self) -> anyhow::Result<Panel> {
        let general = crate::exec::run(
            "nmcli",
            &["-t", "-f", "STATE,CONNECTIVITY", "general"],
            TIMEOUT,
        )?;

        // nmcli exits 0 with empty stdout when NetworkManager is not running
        // on the bus. Empty is not "no networks" — it is no answer.
        let (state, connectivity) = parse_general(&general)
            .ok_or_else(|| anyhow::anyhow!("nmcli general returned no usable record"))?;

        let sh = state_health(&state);
        let ch = connectivity_health(&connectivity);

        let mut panel = Panel::new(Health::Unknown, String::new())
            .row("state", state.clone(), sh)
            .row("connectivity", connectivity.clone(), ch);

        // A failing connection list must not take down a pane that already
        // knows whether the host is online.
        let conns = crate::exec::run(
            "nmcli",
            &["-t", "-f", "NAME,TYPE,DEVICE", "connection", "show", "--active"],
            TIMEOUT,
        )
        .ok()
        .map(|o| parse_connections(&o));

        let primary = conns.as_ref().and_then(|c| {
            c.iter()
                .find(|row| is_real_link(&row[1], &row[2]))
                .map(|row| format!("{} ({})", row[0], row[2]))
        });

        match (&conns, &primary) {
            (Some(list), Some(p)) => {
                panel = panel.row("primary", p.clone(), Health::Good);
                let real = list.iter().filter(|r| is_real_link(&r[1], &r[2])).count();
                panel = panel.plain("active links", format!("{real}"));
                panel = panel.table(
                    vec!["connection".into(), "type".into(), "device".into()],
                    list.clone(),
                );
            }
            (Some(list), None) => {
                // Connections listed, none of them a real link: loopback only.
                panel = panel.row("primary", "none (loopback only)", Health::Bad);
                panel = panel.plain("active links", "0");
                if !list.is_empty() {
                    panel = panel.table(
                        vec!["connection".into(), "type".into(), "device".into()],
                        list.clone(),
                    );
                }
            }
            (None, _) => {
                panel = panel.row("primary", "--", Health::Unknown);
            }
        }

        let egress = egress_mode();
        match &egress {
            Some(m) => {
                // Judged in the PERIMETER pane, not here — showing the same
                // finding twice would double-count it in the SITREP rollup.
                panel = panel.plain("strict egress", m.clone());
            }
            None => panel = panel.plain("strict egress", "--"),
        }

        let link_health = match (&conns, &primary) {
            (Some(_), Some(_)) => Health::Good,
            (Some(_), None) => Health::Bad,
            (None, _) => Health::Unknown,
        };
        panel.health = Health::worst([sh, ch, link_health]);
        panel.summary = format!(
            "{} · {} · {}",
            state,
            connectivity,
            primary.unwrap_or_else(|| "no link".into())
        );

        Ok(panel)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn general_terse_record() {
        assert_eq!(
            parse_general("connected:full\n"),
            Some(("connected".into(), "full".into()))
        );
        // Empty output is no answer, not a healthy default.
        assert_eq!(parse_general(""), None);
        assert_eq!(parse_general("\n  \n"), None);
        // A single field is a shape we do not understand.
        assert_eq!(parse_general("connected\n"), None);
    }

    #[test]
    fn connections_from_a_real_host() {
        let out = "Matrix-5G:802-11-wireless:wlp5s0\ntailscale0:tun:tailscale0\nlo:loopback:lo\n";
        let rows = parse_connections(out);
        assert_eq!(rows.len(), 3);
        assert_eq!(rows[0], vec!["Matrix-5G", "802-11-wireless", "wlp5s0"]);
        assert_eq!(rows[2], vec!["lo", "loopback", "lo"]);
    }

    #[test]
    fn an_escaped_colon_in_a_connection_name_survives() {
        // nmcli emits `\:` for a literal colon; a naive split makes four
        // fields out of three and drops the device column.
        let rows = parse_connections("Work\\: VPN:vpn:tun0\n");
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0], vec!["Work: VPN", "vpn", "tun0"]);
    }

    #[test]
    fn an_escaped_backslash_is_not_an_escape() {
        let f = split_terse("a\\\\b:c");
        assert_eq!(f, vec!["a\\b", "c"]);
        // A dangling backslash must not eat the record terminator.
        assert_eq!(split_terse("a\\"), vec!["a\\"]);
    }

    #[test]
    fn loopback_is_not_a_link() {
        assert!(!is_real_link("loopback", "lo"));
        assert!(!is_real_link("ethernet", "lo"));
        assert!(is_real_link("802-11-wireless", "wlp5s0"));
        assert!(is_real_link("tun", "tailscale0"));
    }

    #[test]
    fn connectivity_unknown_is_not_good() {
        assert_eq!(connectivity_health("full"), Health::Good);
        assert_eq!(connectivity_health("limited"), Health::Warn);
        assert_eq!(connectivity_health("portal"), Health::Warn);
        assert_eq!(connectivity_health("none"), Health::Bad);
        assert_eq!(connectivity_health("unknown"), Health::Unknown);
        assert_eq!(connectivity_health(""), Health::Unknown);
    }

    #[test]
    fn state_vocabulary() {
        assert_eq!(state_health("connected"), Health::Good);
        assert_eq!(state_health("connected (site only)"), Health::Warn);
        assert_eq!(state_health("disconnected"), Health::Bad);
        assert_eq!(state_health("asleep"), Health::Bad);
        assert_eq!(state_health("whatever"), Health::Unknown);
    }
}
