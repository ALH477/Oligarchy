//! Static table of well-known local API endpoints the project exposes.
//!
//! Source of truth for both `egress_coverage` and `local_api_scan`. Built by
//! hand from a one-time scan of the repo. **Add to this table when you add a
//! new API to the project** — `egress_coverage` will then know to expect it
//! and `local_api_scan` will probe it.
//!
//! Entries carry:
//! - `name`      — human-readable identifier
//! - `host`      — bind address (must be loopback for TCP entries)
//! - `port`      — TCP/UDP port, or `None` for "no TCP port" (unix socket /
//!   DBus / stdio-only — flagged GOOD/no-port)
//! - `proto`     — `Tcp`, `Unix`, `DBus`, or `Stdio`
//! - `remote_endpoints` — remote hosts the service is *expected* to talk to.
//!   Used by `egress_coverage` to verify the strict-egress allowlist covers
//!   them. Empty for purely local services.

use serde::Serialize;

#[derive(Debug, Clone, Serialize)]
pub enum Proto {
    Tcp,
    Udp,
    Unix,
    Dbus,
    Stdio,
}

#[derive(Debug, Clone, Serialize)]
pub struct KnownEndpoint {
    pub name: &'static str,
    pub host: &'static str,
    pub port: Option<u16>,
    pub proto: Proto,
    /// Remote hosts this service is expected to reach (for egress coverage).
    pub remote_endpoints: &'static [&'static str],
}

/// The static table. Scan the repo once, then keep this in sync.
pub const KNOWN: &[KnownEndpoint] = &[
    KnownEndpoint {
        name: "ollama",
        host: "127.0.0.1",
        port: Some(11434),
        proto: Proto::Tcp,
        remote_endpoints: &["ollama.com", "registry.ollama.ai", "huggingface.co"],
    },
    KnownEndpoint {
        name: "blipply-assistant",
        host: "(user)",
        port: None,
        proto: Proto::Unix,
        // Uses the user's Pipewire socket only; reaches HF for Whisper model
        // download.
        remote_endpoints: &["huggingface.co"],
    },
    KnownEndpoint {
        name: "dcf-tray",
        host: "(session)",
        port: None,
        proto: Proto::Dbus,
        remote_endpoints: &[],
    },
    KnownEndpoint {
        name: "boot-intro-streamdb",
        host: "127.0.0.1",
        port: Some(9000),
        proto: Proto::Tcp,
        remote_endpoints: &[],
    },
    KnownEndpoint {
        name: "oligarchy-mcp-umbrella",
        host: "(stdio)",
        port: None,
        proto: Proto::Stdio,
        remote_endpoints: &[],
    },
    KnownEndpoint {
        name: "oligarchy-system-mcp",
        host: "(stdio)",
        port: None,
        proto: Proto::Stdio,
        remote_endpoints: &[],
    },
    KnownEndpoint {
        name: "oligarchy-net-mcp",
        host: "(stdio)",
        port: None,
        proto: Proto::Stdio,
        remote_endpoints: &[],
    },
    KnownEndpoint {
        name: "oligarchy-dcf-mcp",
        host: "(stdio)",
        port: None,
        proto: Proto::Stdio,
        remote_endpoints: &[],
    },
    KnownEndpoint {
        name: "oligarchy-dsp-mcp",
        host: "(stdio)",
        port: None,
        proto: Proto::Stdio,
        remote_endpoints: &[],
    },
    KnownEndpoint {
        name: "oligarchy-ai-mcp",
        host: "(stdio)",
        port: None,
        proto: Proto::Stdio,
        remote_endpoints: &[],
    },
    KnownEndpoint {
        name: "oligarchy-secrets-mcp",
        host: "(stdio)",
        port: None,
        proto: Proto::Stdio,
        remote_endpoints: &[],
    },
    KnownEndpoint {
        name: "oligarchy-vm-mcp",
        host: "(stdio)",
        port: None,
        proto: Proto::Stdio,
        remote_endpoints: &[],
    },
    KnownEndpoint {
        name: "oligarchy-ports-sec-mcp",
        host: "(stdio)",
        port: None,
        proto: Proto::Stdio,
        remote_endpoints: &[],
    },
    KnownEndpoint {
        name: "oligarchy-hydramesh-mcp",
        host: "(stdio)",
        port: None,
        proto: Proto::Stdio,
        remote_endpoints: &[],
    },
    // The live HydraMesh / DCF community node listeners. These bind on
    // 0.0.0.0 (see modules/dcf-community-node.nix), so `listening_ports` will
    // flag them as `exposed_to_lan` — that is expected for a mesh node, but it
    // is why they belong in this table rather than being a surprise.
    KnownEndpoint {
        name: "dcf-node-binary",
        host: "0.0.0.0",
        port: Some(7777),
        proto: Proto::Udp,
        remote_endpoints: &["api.demod.ltd"],
    },
    KnownEndpoint {
        name: "dcf-node-grpc",
        host: "0.0.0.0",
        port: Some(50051),
        proto: Proto::Tcp,
        remote_endpoints: &[],
    },
    KnownEndpoint {
        name: "dcf-node-shim",
        host: "0.0.0.0",
        port: Some(8888),
        proto: Proto::Udp,
        remote_endpoints: &[],
    },
    // Opt-in, default off (services.dcf-mesh-agent). NOT part of the read-only
    // MCP surface: mesh_mcp.py binds UDP at import and `mesh_send` transmits.
    KnownEndpoint {
        name: "dcf-mesh-agent",
        host: "0.0.0.0",
        port: Some(7801),
        proto: Proto::Udp,
        remote_endpoints: &[],
    },
    // Opt-in, default off (services.dcf-hypr-agent, modules/hypr-controller).
    // NOT part of the read-only MCP surface: the bridge relays Hyprland
    // dispatch commands AND a byte-for-byte oligarchy-ctl passthrough, i.e.
    // arbitrary command execution from a paired controller device.
    KnownEndpoint {
        name: "dcf-hypr-agent",
        host: "0.0.0.0",
        port: Some(7100),
        proto: Proto::Udp,
        remote_endpoints: &[],
    },
    // Opt-in, default off (networking.firewall.spaGate, pulled in by
    // services.dcf-hypr-agent.spaGated). The DCF-SPA knock channel: silent by
    // design — it never replies, so a scan sees nothing — but it IS a
    // LAN-exposed bind, and it is the one port that must stay open for the
    // gate on 7100 to be openable at all.
    KnownEndpoint {
        name: "dcf-spa-knock",
        host: "0.0.0.0",
        port: Some(62201),
        proto: Proto::Udp,
        remote_endpoints: &[],
    },
];

/// Gives a one-line summary used by `egress_coverage` and other reporters.
pub fn summary(ep: &KnownEndpoint) -> String {
    let port_str = match ep.port {
        Some(p) => format!("{}:{}", ep.host, p),
        None => format!("{} ({:?}, no port)", ep.host, ep.proto),
    };
    let remotes = if ep.remote_endpoints.is_empty() {
        "(no remote endpoints)".to_string()
    } else {
        ep.remote_endpoints.join(", ")
    };
    format!("{:<28} {:<28} remote: {}", ep.name, port_str, remotes)
}