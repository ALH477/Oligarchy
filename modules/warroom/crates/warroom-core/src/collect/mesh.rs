//! MESH collector — `dcf status` / `dcf list-peers` (JSON)
//!
//! OWNER: work stream S1.
//!
//! Both verbs emit JSON on stdout. `dcf` also logs to **stderr** when it cannot
//! find `dcf_config.toml` in the CWD — which is always, for a daemon-less
//! invocation from a TUI — so `exec::run` (stdout only) already gets clean
//! JSON. We still scan forward to the first `{`/`[` rather than trusting that:
//! a future log line that lands on stdout would otherwise turn this pane into a
//! permanent parse error.
//!
//! The peer object shape is not pinned by anything in this repo (`dcf` comes
//! from the HydraMesh flake input), so the table derives its columns from the
//! data instead of hardcoding them, with a preferred ordering for the fields we
//! do expect.

use crate::model::{Availability, Health, Panel};
use serde_json::Value;
use std::time::Duration;

const TIMEOUT: Duration = Duration::from_millis(2500);

/// Columns we know how to name, in the order an operator wants to read them.
/// Anything else the peer object carries is appended afterwards, so a new
/// upstream field shows up rather than being silently dropped.
const PREFERRED_COLUMNS: [&str; 11] = [
    "peer_id",
    "id",
    "node_id",
    "host",
    "address",
    "addr",
    "port",
    "role",
    "status",
    "health",
    "last_seen",
];

pub struct MeshCollector {
    _priv: (),
}

impl MeshCollector {
    pub fn new() -> Self {
        MeshCollector { _priv: () }
    }
}

impl Default for MeshCollector {
    fn default() -> Self {
        Self::new()
    }
}

/// Most log lines we could be prefixed with; a bound so a stream that is all
/// brackets and no JSON cannot turn into a quadratic scan.
const MAX_JSON_CANDIDATES: usize = 64;

/// Take the JSON document out of a stream that may be prefixed by log lines.
///
/// Seeking to the first `{` or `[` is NOT sufficient, and assuming it was is a
/// bug this module's tests caught: `dcf`'s own log format is
/// `[2026-09-18T06:25:32.571Z WARN  dcf] Config file not found: ...`, which
/// opens with a bracket. Matching "starts a line" fails on it for the same
/// reason. So every bracket is treated as a *candidate* start and the first one
/// from which the remainder parses as a complete document wins — trailing
/// garbage makes `from_str` fail, which is what makes the test decisive.
fn parse_json(out: &str) -> anyhow::Result<Value> {
    let mut tried = 0usize;
    for (i, c) in out.char_indices() {
        if c != '{' && c != '[' {
            continue;
        }
        tried += 1;
        if tried > MAX_JSON_CANDIDATES {
            break;
        }
        if let Ok(v) = serde_json::from_str::<Value>(out[i..].trim_end()) {
            return Ok(v);
        }
    }
    Err(anyhow::anyhow!("no JSON document in dcf output"))
}

/// Scalars as a human would write them; containers as compact JSON rather
/// than `[object]`, so a nested field is still legible in a table cell.
fn cell(v: &Value) -> String {
    match v {
        Value::Null => "--".to_string(),
        Value::String(s) => s.clone(),
        Value::Bool(b) => b.to_string(),
        Value::Number(n) => n.to_string(),
        other => other.to_string(),
    }
}

/// Derive `(headers, rows)` from a JSON array of peer objects.
///
/// The column set is the union of every peer's keys, so a peer carrying an
/// extra field does not shift another peer's columns.
fn peer_table(peers: &[Value]) -> (Vec<String>, Vec<Vec<String>>) {
    let mut keys: Vec<String> = Vec::new();
    for want in PREFERRED_COLUMNS {
        if peers.iter().any(|p| p.get(want).is_some()) {
            keys.push(want.to_string());
        }
    }
    for p in peers {
        if let Some(obj) = p.as_object() {
            for k in obj.keys() {
                if !keys.iter().any(|existing| existing == k) {
                    keys.push(k.clone());
                }
            }
        }
    }

    // A list of bare strings (ids with no structure) is a legitimate shape too.
    if keys.is_empty() {
        return (
            vec!["peer".to_string()],
            peers.iter().map(|p| vec![cell(p)]).collect(),
        );
    }

    let rows = peers
        .iter()
        .map(|p| {
            keys.iter()
                .map(|k| p.get(k).map(cell).unwrap_or_else(|| "--".to_string()))
                .collect()
        })
        .collect();
    (keys, rows)
}

impl super::Collector for MeshCollector {
    fn id(&self) -> &'static str {
        "mesh"
    }

    fn title(&self) -> &'static str {
        "MESH"
    }

    fn interval(&self) -> Duration {
        Duration::from_secs(5)
    }

    fn probe(&self) -> Availability {
        match crate::exec::which("dcf") {
            Some(_) => Availability::Present,
            None => Availability::Missing("dcf not installed — enable custom.hydramesh"),
        }
    }

    fn collect(&mut self) -> anyhow::Result<Panel> {
        // `dcf status` is the load-bearing call: if it fails we have nothing.
        let status_out = crate::exec::run("dcf", &["status"], TIMEOUT)?;
        let status = parse_json(&status_out)?;

        let running = status.get("running").and_then(Value::as_bool);
        let udp_active = status.get("udp_active").and_then(Value::as_bool);
        let mode = status.get("mode").and_then(Value::as_str);
        let udp_port = status.get("udp_port").and_then(Value::as_u64);
        let peer_count = status.get("peer_count").and_then(Value::as_u64);

        let mut panel = Panel::new(Health::Unknown, String::new());
        let mut judged = Vec::new();

        match running {
            // A node that is not running is not a *fault* — the mesh is opt-in
            // and `services.dcfCommunityNode` is off by default — but it is
            // definitively not Good either.
            Some(true) => {
                judged.push(Health::Good);
                panel = panel.row("node", "running", Health::Good);
            }
            Some(false) => {
                judged.push(Health::Unknown);
                panel = panel.row("node", "stopped", Health::Unknown);
            }
            None => {
                judged.push(Health::Unknown);
                panel = panel.row("node", "--", Health::Unknown);
            }
        }

        match (running, udp_active) {
            (Some(true), Some(true)) => {
                judged.push(Health::Good);
                panel = panel.row("udp", "active", Health::Good);
            }
            // Running but with a dead socket is the genuinely broken case.
            (Some(true), Some(false)) => {
                judged.push(Health::Bad);
                panel = panel.row("udp", "inactive", Health::Bad);
            }
            (_, Some(false)) => panel = panel.row("udp", "inactive", Health::Unknown),
            (_, Some(true)) => panel = panel.row("udp", "active", Health::Unknown),
            (_, None) => panel = panel.row("udp", "--", Health::Unknown),
        }

        panel = panel.plain("mode", mode.unwrap_or("--"));
        panel = panel.plain(
            "port",
            udp_port.map(|p| p.to_string()).unwrap_or_else(|| "--".into()),
        );

        // A failed peer list must not take the pane down: the node status we
        // already have is worth rendering on its own.
        let peers = crate::exec::run("dcf", &["list-peers"], TIMEOUT)
            .ok()
            .and_then(|out| parse_json(&out).ok())
            .and_then(|v| v.as_array().cloned());

        let listed = match &peers {
            Some(list) => {
                if !list.is_empty() {
                    let (headers, rows) = peer_table(list);
                    panel = panel.table(headers, rows);
                }
                Some(list.len())
            }
            None => None,
        };

        // `peer_count` from `status` and the length of `list-peers` are two
        // separate answers from the same daemon; disagreeing is worth saying
        // out loud rather than silently preferring one.
        let peers_value = match (peer_count, listed) {
            (Some(c), Some(l)) if c as usize == l => format!("{c}"),
            (Some(c), Some(l)) => format!("{c} reported / {l} listed"),
            (Some(c), None) => format!("{c} (list unavailable)"),
            (None, Some(l)) => format!("{l} listed"),
            (None, None) => "--".to_string(),
        };
        let peers_health = match (peer_count, listed) {
            (Some(c), Some(l)) if c as usize != l => Health::Warn,
            (None, None) => Health::Unknown,
            _ => Health::Unknown,
        };
        if peers_health == Health::Warn {
            judged.push(Health::Warn);
        }
        panel = panel.row("peers", peers_value, peers_health);

        panel.health = Health::worst(judged);
        panel.summary = match running {
            Some(true) => format!(
                "{} · {} peers · udp {}",
                mode.unwrap_or("?"),
                listed.map(|l| l.to_string()).or_else(|| peer_count.map(|c| c.to_string())).unwrap_or_else(|| "?".into()),
                if udp_active == Some(true) { "up" } else { "down" }
            ),
            Some(false) => "node stopped".to_string(),
            None => "state unknown".to_string(),
        };

        Ok(panel)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Verbatim `dcf status` stdout, with the stderr WARN line moved onto
    /// stdout to prove the leading-log tolerance.
    const STATUS_WITH_LOG: &str = r#"[2026-09-18T06:25:32.571Z WARN  dcf] Config file not found: dcf_config.toml, using defaults
{
  "running": false,
  "mode": "p2p",
  "udp_port": 7777,
  "peer_count": 0,
  "udp_active": false
}
"#;

    #[test]
    fn a_leading_log_line_does_not_break_the_parse() {
        let v = parse_json(STATUS_WITH_LOG).expect("parses");
        assert_eq!(v.get("mode").and_then(Value::as_str), Some("p2p"));
        assert_eq!(v.get("running").and_then(Value::as_bool), Some(false));
    }

    /// Regression: `dcf`'s log prefix OPENS WITH A BRACKET, so seeking to the
    /// first `{`/`[` in the stream lands on the log line, not the document.
    #[test]
    fn a_log_line_that_itself_starts_with_a_bracket_is_skipped() {
        let out = "[2026-09-18T06:25:32.571Z WARN  dcf] nope\n[\"alpha\",\"bravo\"]\n";
        let v = parse_json(out).expect("parses the array, not the log line");
        assert_eq!(v.as_array().map(Vec::len), Some(2));
    }

    /// Trailing garbage after a document must not be accepted as that
    /// document: it is the signal that we picked the wrong start offset.
    #[test]
    fn a_truncated_document_is_an_error() {
        assert!(parse_json("{\"running\": true").is_err());
        assert!(parse_json("{\"a\":1} and then some prose").is_err());
    }

    #[test]
    fn an_empty_stream_is_an_error_not_an_empty_status() {
        assert!(parse_json("").is_err());
        assert!(parse_json("   \n").is_err());
        // Exit-0-with-a-log-line-and-no-JSON is the unprivileged-silence shape.
        assert!(parse_json("[WARN] nothing to report\n").is_err());
    }

    #[test]
    fn empty_peer_list_parses_to_an_empty_array() {
        let v = parse_json("[]\n").expect("parses");
        assert_eq!(v.as_array().map(Vec::len), Some(0));
    }

    #[test]
    fn peer_columns_prefer_the_known_order_then_append_the_rest() {
        let peers: Vec<Value> = serde_json::from_str(
            r#"[{"host":"10.0.0.2","peer_id":"alpha","port":7777,"rtt_ms":3.5},
                {"host":"10.0.0.3","peer_id":"bravo","port":7778}]"#,
        )
        .unwrap();
        let (headers, rows) = peer_table(&peers);
        assert_eq!(headers, vec!["peer_id", "host", "port", "rtt_ms"]);
        assert_eq!(rows[0], vec!["alpha", "10.0.0.2", "7777", "3.5"]);
        // The peer missing the extra field gets a placeholder, not a shift.
        assert_eq!(rows[1], vec!["bravo", "10.0.0.3", "7778", "--"]);
    }

    #[test]
    fn a_bare_string_peer_list_still_renders() {
        let peers: Vec<Value> = serde_json::from_str(r#"["alpha","bravo"]"#).unwrap();
        let (headers, rows) = peer_table(&peers);
        assert_eq!(headers, vec!["peer"]);
        assert_eq!(rows, vec![vec!["alpha"], vec!["bravo"]]);
    }

    #[test]
    fn cells_render_containers_rather_than_dropping_them() {
        assert_eq!(cell(&Value::Null), "--");
        assert_eq!(cell(&serde_json::json!("x")), "x");
        assert_eq!(cell(&serde_json::json!(true)), "true");
        assert_eq!(cell(&serde_json::json!([1, 2])), "[1,2]");
    }
}
