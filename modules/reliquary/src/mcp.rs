use std::io::{self, BufRead, Read, Write};

use serde_json::{json, Value};

use crate::config::{Config, VERSION};
use crate::optical;
use crate::store::Store;
use crate::usb;

const TOOLS: &str = r#"
[
  {"name":"reliquary_status","description":"Local store path, block count, and USB-A / USB-B presence.","inputSchema":{"type":"object","properties":{}}},
  {"name":"reliquary_list_blocks","description":"List preservation blocks in the local store.","inputSchema":{"type":"object","properties":{}}},
  {"name":"reliquary_show_block","description":"Show the full manifest for one block.","inputSchema":{"type":"object","properties":{"block_id":{"type":"string"}},"required":["block_id"]}},
  {"name":"reliquary_ingest","description":"Pack a path into a tarball+checksum+PAR2 block. profile=cd sizes for an 80-minute CD-R.","inputSchema":{"type":"object","properties":{"path":{"type":"string"},"profile":{"type":"string","enum":["cd","usb"]},"notes":{"type":"string"},"force":{"type":"boolean"}},"required":["path"]}},
  {"name":"reliquary_verify","description":"Verify SHA-256/512 and PAR2. Optionally repair.","inputSchema":{"type":"object","properties":{"block_id":{"type":"string"},"repair":{"type":"boolean"}},"required":["block_id"]}},
  {"name":"reliquary_extract","description":"Verify and extract a block tarball to dest.","inputSchema":{"type":"object","properties":{"block_id":{"type":"string"},"dest":{"type":"string"},"verify":{"type":"boolean"}},"required":["block_id","dest"]}},
  {"name":"reliquary_push_usb","description":"Copy a block onto mounted USB data partitions and refresh META catalogs.","inputSchema":{"type":"object","properties":{"block_id":{"type":"string"},"roles":{"type":"string"}},"required":["block_id"]}},
  {"name":"reliquary_pull_usb","description":"Copy a block from a mounted USB into the local store.","inputSchema":{"type":"object","properties":{"block_id":{"type":"string"},"role":{"type":"string","enum":["A","B"]}},"required":["block_id"]}},
  {"name":"reliquary_make_cd_iso","description":"Build an ISO 9660 / Rock Ridge / Joliet image of one block for an 80-minute CD-R.","inputSchema":{"type":"object","properties":{"block_id":{"type":"string"}},"required":["block_id"]}},
  {"name":"reliquary_burn_cd","description":"Burn an ISO to a CD writer with xorriso. dummy=true is a laser-off rehearsal.","inputSchema":{"type":"object","properties":{"iso":{"type":"string"},"device":{"type":"string"},"dummy":{"type":"boolean"}},"required":["iso","device"]}},
  {"name":"reliquary_usb_status","description":"Detailed USB-A / USB-B detection via lsblk labels.","inputSchema":{"type":"object","properties":{}}}
]
"#;

pub fn run_stdio() -> anyhow::Result<()> {
    let cfg = Config::load();
    let store = Store::new(cfg.clone())?;
    let stdin = io::stdin();
    let mut stdout = io::stdout();
    loop {
        let Some(msg) = read_message(&mut stdin.lock())? else {
            return Ok(());
        };
        if let Some(reply) = handle(&store, msg) {
            write_message(&mut stdout, &reply)?;
        }
    }
}

fn handle(store: &Store, msg: Value) -> Option<Value> {
    let method = msg.get("method")?.as_str()?.to_string();
    let id = msg.get("id").cloned();
    if method.starts_with("notifications/") {
        return None;
    }
    let params = msg.get("params").cloned().unwrap_or_else(|| json!({}));
    let result = dispatch(store, &method, params);
    Some(match result {
        Ok(value) => json!({"jsonrpc":"2.0","id": id, "result": value}),
        Err(err) => json!({
            "jsonrpc":"2.0",
            "id": id,
            "error": {"code": -32000, "message": err}
        }),
    })
}

fn dispatch(store: &Store, method: &str, params: Value) -> std::result::Result<Value, String> {
    match method {
        "initialize" => Ok(json!({
            "protocolVersion": params.get("protocolVersion").and_then(|v| v.as_str()).unwrap_or("2024-11-05"),
            "capabilities": {"tools": {}, "resources": {}},
            "serverInfo": {"name": "reliquary", "version": VERSION}
        })),
        "ping" => Ok(json!({})),
        "tools/list" => {
            let tools: Value = serde_json::from_str(TOOLS).map_err(|e| e.to_string())?;
            Ok(json!({"tools": tools}))
        }
        "tools/call" => {
            let name = params
                .get("name")
                .and_then(|v| v.as_str())
                .ok_or_else(|| "missing tool name".to_string())?;
            let args = params.get("arguments").cloned().unwrap_or_else(|| json!({}));
            call_tool(store, name, args)
        }
        "resources/list" => {
            let blocks = store.list_blocks().map_err(|e| e.to_string())?;
            let resources: Vec<Value> = blocks
                .iter()
                .filter_map(|b| b.get("id").and_then(|v| v.as_str()))
                .map(|id| {
                    json!({
                        "uri": format!("reliquary://block/{id}"),
                        "name": id,
                        "mimeType": "application/json"
                    })
                })
                .collect();
            Ok(json!({"resources": resources}))
        }
        "resources/read" => {
            let uri = params
                .get("uri")
                .and_then(|v| v.as_str())
                .unwrap_or_default();
            let prefix = "reliquary://block/";
            if let Some(id) = uri.strip_prefix(prefix) {
                let man = store.load_manifest(id).map_err(|e| e.to_string())?;
                Ok(json!({
                    "contents": [{
                        "uri": uri,
                        "mimeType": "application/json",
                        "text": serde_json::to_string_pretty(&man).unwrap_or_default()
                    }]
                }))
            } else {
                Err(format!("unknown resource {uri}"))
            }
        }
        other => Err(format!("unknown method {other}")),
    }
}

fn call_tool(store: &Store, name: &str, args: Value) -> std::result::Result<Value, String> {
    let ok = |payload: Value| {
        json!({
            "content": [{"type": "text", "text": serde_json::to_string_pretty(&payload).unwrap_or_default()}]
        })
    };
    match name {
        "reliquary_status" => Ok(ok(json!({
            "store_root": store.cfg.store_root.display().to_string(),
            "blocks": store.list_blocks().map_err(|e| e.to_string())?.len(),
            "usb": usb::volume_status(&store.cfg).map_err(|e| e.to_string())?
        }))),
        "reliquary_list_blocks" => {
            let rows: Vec<Value> = store
                .list_blocks()
                .map_err(|e| e.to_string())?
                .into_iter()
                .map(|m| {
                    json!({
                        "id": m.get("id"),
                        "created": m.get("created"),
                        "profile": m.get("profile"),
                        "bytes": m.get("payload").and_then(|p| p.get("bytes")),
                        "origin": m.get("origin"),
                    })
                })
                .collect();
            Ok(ok(Value::Array(rows)))
        }
        "reliquary_show_block" => {
            let id = req_str(&args, "block_id")?;
            Ok(ok(store.load_manifest(id).map_err(|e| e.to_string())?))
        }
        "reliquary_ingest" => {
            let path = req_str(&args, "path")?;
            let profile = args.get("profile").and_then(|v| v.as_str()).unwrap_or("cd");
            let notes = args.get("notes").and_then(|v| v.as_str()).unwrap_or("");
            let force = args.get("force").and_then(|v| v.as_bool()).unwrap_or(false);
            Ok(ok(store
                .ingest(std::path::Path::new(path), profile, notes, force)
                .map_err(|e| e.to_string())?))
        }
        "reliquary_verify" => {
            let id = req_str(&args, "block_id")?;
            let repair = args.get("repair").and_then(|v| v.as_bool()).unwrap_or(false);
            Ok(ok(store.verify(id, repair).map_err(|e| e.to_string())?))
        }
        "reliquary_extract" => {
            let id = req_str(&args, "block_id")?;
            let dest = req_str(&args, "dest")?;
            let verify = args.get("verify").and_then(|v| v.as_bool()).unwrap_or(true);
            let dest = store
                .extract(id, std::path::Path::new(dest), verify)
                .map_err(|e| e.to_string())?;
            Ok(ok(json!({"extracted_to": dest.display().to_string()})))
        }
        "reliquary_push_usb" => {
            let id = req_str(&args, "block_id")?;
            let roles = args.get("roles").and_then(|v| v.as_str()).unwrap_or("AB");
            Ok(ok(usb::push_block(&store.cfg, store, id, roles).map_err(|e| e.to_string())?))
        }
        "reliquary_pull_usb" => {
            let id = req_str(&args, "block_id")?;
            let role = args.get("role").and_then(|v| v.as_str()).unwrap_or("A");
            let dest = usb::pull_block(&store.cfg, store, id, role).map_err(|e| e.to_string())?;
            Ok(ok(json!({"pulled_to": dest.display().to_string()})))
        }
        "reliquary_make_cd_iso" => {
            let id = req_str(&args, "block_id")?;
            let iso = optical::make_iso(&store.cfg, store, id).map_err(|e| e.to_string())?;
            Ok(ok(optical::iso_info(&iso)))
        }
        "reliquary_burn_cd" => {
            let iso = req_str(&args, "iso")?;
            let device = req_str(&args, "device")?;
            let dummy = args.get("dummy").and_then(|v| v.as_bool()).unwrap_or(false);
            Ok(ok(optical::burn_iso(
                std::path::Path::new(iso),
                std::path::Path::new(device),
                dummy,
            )
            .map_err(|e| e.to_string())?))
        }
        "reliquary_usb_status" => Ok(ok(usb::volume_status(&store.cfg).map_err(|e| e.to_string())?)),
        other => Err(format!("unknown tool {other}")),
    }
}

fn req_str<'a>(args: &'a Value, key: &str) -> std::result::Result<&'a str, String> {
    args.get(key)
        .and_then(|v| v.as_str())
        .ok_or_else(|| format!("missing {key}"))
}

/// Largest single MCP message accepted. Generous next to any real request —
/// the biggest thing this server takes is a path plus a note — and small enough
/// that a hostile or runaway host cannot grow the process without bound.
const MAX_MESSAGE_BYTES: u64 = 8 * 1024 * 1024;

/// MCP's stdio transport is newline-delimited JSON: one JSON object per line,
/// terminated by `\n`, no headers of any kind. (The LSP-style `Content-Length`
/// framing this used to implement is a different protocol; no MCP host speaks
/// it.) Blank lines are skipped, EOF is `Ok(None)`.
///
/// The read is bounded at [`MAX_MESSAGE_BYTES`].
///
/// Dropping the old `Content-Length` header removed a caller-supplied *number*
/// driving one `vec![0u8; length]` allocation, but not the unbounded growth:
/// `BufRead::read_line` grows its buffer until it sees `\n` or EOF, so a writer
/// that streams bytes and never sends a newline walks this process to an
/// OOM kill just as effectively. The framing changed; the DoS did not. The cap
/// is what actually closes it.
///
/// This matters beyond this repo. Reliquary's MCP server is deliberately kept
/// out of Oligarchy's own `.mcp.json` (its tools burn, format and extract), but
/// `examples/mcp.json` documents wiring it into someone else's client, so an
/// external host drives this parser directly.
fn read_message(stdin: &mut impl BufRead) -> io::Result<Option<Value>> {
    loop {
        let mut buf = Vec::new();
        // `by_ref` so the limit applies to this message, not to the stream: a
        // fresh `Take` per line, with the underlying buffer preserved.
        let n = stdin
            .by_ref()
            .take(MAX_MESSAGE_BYTES + 1)
            .read_until(b'\n', &mut buf)?;
        if n == 0 {
            return Ok(None);
        }
        if n as u64 > MAX_MESSAGE_BYTES {
            // The rest of the oversized line is still queued, so there is no
            // resynchronising to a message boundary from here — refuse and let
            // the caller tear the session down.
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("MCP message exceeds {MAX_MESSAGE_BYTES} bytes"),
            ));
        }
        let text = String::from_utf8(buf)
            .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
        let trimmed = text.trim();
        if trimmed.is_empty() {
            continue;
        }
        return Ok(Some(serde_json::from_str(trimmed).map_err(|e| {
            io::Error::new(io::ErrorKind::InvalidData, e)
        })?));
    }
}

fn write_message(stdout: &mut impl Write, msg: &Value) -> io::Result<()> {
    // Compact, never pretty: an embedded newline would split one message in two.
    let raw = serde_json::to_string(msg)?;
    stdout.write_all(raw.as_bytes())?;
    stdout.write_all(b"\n")?;
    stdout.flush()?;
    Ok(())
}

#[cfg(test)]
mod read_bound_tests {
    use super::*;
    use std::io::Cursor;

    /// The bug the cap closes: newline-delimited framing removed the
    /// attacker-supplied *length*, but `read_line` still grew without bound, so
    /// a writer that never sends `\n` walks the process to an OOM kill.
    #[test]
    fn a_message_without_a_newline_cannot_grow_without_bound() {
        let huge = "x".repeat((MAX_MESSAGE_BYTES + 1024) as usize);
        let mut cur = Cursor::new(huge.into_bytes());
        let err = read_message(&mut cur).unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::InvalidData);
        assert!(err.to_string().contains("exceeds"), "{err}");
    }

    #[test]
    fn an_oversized_but_newline_terminated_message_is_still_refused() {
        let mut line = "{\"a\":\"".to_string();
        line.push_str(&"y".repeat((MAX_MESSAGE_BYTES + 16) as usize));
        line.push_str("\"}\n");
        let mut cur = Cursor::new(line.into_bytes());
        assert!(read_message(&mut cur).is_err());
    }

    #[test]
    fn ordinary_messages_still_round_trip() {
        let mut cur = Cursor::new(b"\n  \n{\"jsonrpc\":\"2.0\",\"id\":1}\n".to_vec());
        let got = read_message(&mut cur).unwrap().unwrap();
        assert_eq!(got["id"], 1);
        assert!(read_message(&mut cur).unwrap().is_none(), "EOF is None");
    }

    #[test]
    fn a_message_just_under_the_cap_is_accepted() {
        let filler = (MAX_MESSAGE_BYTES as usize) - 32;
        let line = format!("{{\"a\":\"{}\"}}\n", "z".repeat(filler));
        assert!(line.len() as u64 <= MAX_MESSAGE_BYTES);
        let mut cur = Cursor::new(line.into_bytes());
        assert!(read_message(&mut cur).unwrap().is_some());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn framing_is_newline_delimited_json() {
        let input = b"{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}\n\n{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"ping\"}\r\n";
        let mut cur = io::Cursor::new(&input[..]);
        let first = read_message(&mut cur).unwrap().unwrap();
        assert_eq!(first["id"], json!(1));
        // The blank line between the two is skipped, not treated as EOF.
        let second = read_message(&mut cur).unwrap().unwrap();
        assert_eq!(second["id"], json!(2));
        assert!(read_message(&mut cur).unwrap().is_none());
    }

    #[test]
    fn a_written_message_is_one_line_with_a_trailing_newline() {
        let mut out: Vec<u8> = Vec::new();
        write_message(&mut out, &json!({"a": 1, "b": {"c": [1, 2]}})).unwrap();
        let s = String::from_utf8(out).unwrap();
        assert!(s.ends_with('\n'), "{s:?}");
        assert_eq!(s.matches('\n').count(), 1, "must not be pretty-printed: {s:?}");
        assert!(!s.contains("Content-Length"), "{s:?}");
    }
}
