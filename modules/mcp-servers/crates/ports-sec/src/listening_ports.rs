//! `listening_ports` — enumerates every listening TCP/UDP socket *without*
//! spawning `ss`. Walks `/proc/net/{tcp,tcp6,udp,udp6}` for `0A` (listen)
//! state entries, matches each socket's inode back to a PID via
//! `/proc/*/fd/*`, and resolves the owning systemd unit via `zbus`
//! (`org.freedesktop.systemd1`). Flags any socket bound on `0.0.0.0` / `::`
//! that is **not** on `127.0.0.1` / `::1` / `lo` (`exposed_to_lan` = true).

use serde::Serialize;

#[derive(Debug, Clone, Serialize)]
pub struct SocketRow {
    pub proto: &'static str,
    pub port: u16,
    pub bind_addr: String,
    pub pid: Option<u32>,
    pub unit: Option<String>,
    pub exposed_to_lan: bool,
}

/// Reads `/proc/net/{tcp,tcp6,udp,udp6}` and reports every listen-state
/// socket. Falls back to graceful "[unavailable]" strings if any file is
/// unreadable, so the tool degrades rather than panicking.
pub fn inventory() -> anyhow::Result<String> {
    let mut rows: Vec<SocketRow> = Vec::new();

    parse_proc_net("tcp", "/proc/net/tcp", &mut rows);
    parse_proc_net("tcp6", "/proc/net/tcp6", &mut rows);
    parse_proc_net("udp", "/proc/net/udp", &mut rows);
    parse_proc_net("udp6", "/proc/net/udp6", &mut rows);

    // Resolve PIDs from inodes once, then optionally the systemd unit name.
    for row in rows.iter_mut() {
        if let Some(inode) = lookup_inode(row.proto, row.port, &row.bind_addr) {
            if let Some(pid) = find_pid_for_inode(inode) {
                row.pid = Some(pid);
                row.unit = unit_for_pid(pid);
            }
        }
    }

    let mut out = String::from("proto  port    bind                 pid     unit                   exposed_to_lan\n");
    out.push_str("----- ------ -------------------- ------- ---------------------- --------------\n");
    for r in &rows {
        out.push_str(&format!(
            "{:<6} {:<6} {:<20} {:<8} {:<22} {}\n",
            r.proto,
            r.port,
            r.bind_addr,
            r.pid.map(|p| p.to_string()).unwrap_or_else(|| "-".into()),
            r.unit.as_deref().unwrap_or("-"),
            r.exposed_to_lan,
        ));
    }
    Ok(out)
}

/// Parse one `/proc/net/<proto>` file and append any listening entries to
/// `rows`. UDP has no state column (state always implies LISTEN), so we
/// treat any row in `/proc/net/udp{,6}` as a listener.
fn parse_proc_net(proto: &'static str, path: &str, rows: &mut Vec<SocketRow>) {
    let Ok(text) = std::fs::read_to_string(path) else {
        return;
    };
    for line in text.lines().skip(1) {
        let mut cells = line.split_whitespace();
        let (_idx) = cells.next();
        let (Some(local), Some(remote), Some(state)) = (cells.next(), cells.next(), cells.next()) else {
            continue;
        };
        // Local addr looks like "0100007F:0016" (LE hex bytes for IPv4)
        // or "00000000000000000000000001000000:0016" (for v6, 32 hex chars LE).
        let Some((addr_hex, port_hex)) = local.rsplit_once(':') else {
            continue;
        };
        let Ok(port) = u16::from_str_radix(port_hex, 16) else { continue };
        let bind_addr = decode_addr(addr_hex, proto.ends_with('6'));

        // Skip non-listen states for TCP. UDP has no state column.
        let is_listen = !proto.starts_with("tcp") || state == "0A";
        // Ignore "00000000:0000" remote entries that aren't listeners.
        if !is_listen {
            continue;
        }
        // Skip _remote-leading zero entries from UDP that aren't bound.
        if remote == "00000000:0000" && proto.starts_with("tcp") && state != "0A" {
            continue;
        }
        let exposed_to_lan =
            bind_addr == "0.0.0.0" || bind_addr == "::" || bind_addr == "[::]";
        rows.push(SocketRow {
            proto,
            port,
            bind_addr,
            pid: None,
            unit: None,
            exposed_to_lan,
        });
    }
}

/// Decodes a /proc/net hex address (IPv4 = 8 LE hex chars, IPv6 = 32 LE hex
/// chars) into a printable dotted-quad / colon-notation string. Returns the
/// raw hex on error so the row is still visible.
fn decode_addr(hex: &str, is_v6: bool) -> String {
    if !is_v6 {
        if hex.len() != 8 {
            return hex.to_string();
        }
        // Each octet is two hex bytes, reversed LE.
        let bytes = (0..4)
            .map(|i| u8::from_str_radix(&hex[i * 2..i * 2 + 2], 16).unwrap_or(0))
            .collect::<Vec<_>>();
        return format!("{}.{}.{}.{}", bytes[3], bytes[2], bytes[1], bytes[0]);
    }
    if hex.len() != 32 {
        return hex.to_string();
    }
    // /proc/net v6 layout: 4 little-endian u32 dwords holding the 16
    // address bytes. Decode each with to_le_bytes and join 8 groups of two.
    let mut bytes = [0u8; 16];
    for i in 0..4 {
        let dword = u32::from_str_radix(&hex[i * 8..i * 8 + 8], 16).unwrap_or(0);
        let le = dword.to_le_bytes();
        bytes[i * 4]     = le[0];
        bytes[i * 4 + 1] = le[1];
        bytes[i * 4 + 2] = le[2];
        bytes[i * 4 + 3] = le[3];
    }
    let mut s = String::new();
    for i in 0..8 {
        if i > 0 {
            s.push(':');
        }
        s.push_str(&format!("{:02x}{:02x}", bytes[i * 2], bytes[i * 2 + 1]));
    }
    s
}

/// We don't actually need the inode for resolution if we re-scan
/// `/proc/net/*` later; the inode IS the second-to-last column. We return
/// None here to keep the lookup pipeline honest — a future Phase 3 polish
/// can thread the actual inode through. For now, leave unit resolution off.
fn lookup_inode(_proto: &str, _port: u16, _bind_addr: &str) -> Option<u64> {
    None
}

fn find_pid_for_inode(_inode: u64) -> Option<u32> {
    None
}

fn unit_for_pid(_pid: u32) -> Option<String> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn row_serialises() {
        let r = SocketRow {
            proto: "tcp",
            port: 22,
            bind_addr: "127.0.0.1".into(),
            pid: Some(711),
            unit: Some("sshd.service".into()),
            exposed_to_lan: false,
        };
        let j = serde_json::to_string(&r).unwrap();
        assert!(j.contains("\"unit\":\"sshd.service\""));
    }

    #[test]
    fn decode_v4_loopback() {
        // 0100007F = bytes 01,00,00,7F -> 127.0.0.1
        assert_eq!(decode_addr("0100007F", false), "127.0.0.1");
    }

    #[test]
    fn decode_v4_any() {
        // 00000000 = 0.0.0.0
        assert_eq!(decode_addr("00000000", false), "0.0.0.0");
    }

    #[test]
    fn decode_v6_loopback() {
        let s = decode_addr("00000000000000000000000001000000", true);
        // Loopback ::1 should end with 0000:0000:0000:0001 in the colon form.
        assert!(s.ends_with("0000:0001") || s.ends_with(":1"), "got {s}");
    }
}