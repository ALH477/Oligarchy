// SPDX-License-Identifier: MIT
// Transport abstraction — all DSP coprocessor access goes through this trait.
//
// The same dsp-ctl binary works with:
//   - Local QEMU VM (Unix socket to orchestrator + systemctl on the host)
//   - Direct hardware over SSH (systemctl + socat tunnel over SSH)
//   - TCP/IP (socat bridge on the DSP coprocessor → orchestrator Unix socket)
//   - USB networking (TCP over RNDIS/CDC-ECM, appears as a network interface)
//   - Raw HydraMesh ethernet (AF_PACKET — stubbed)
//
// Two command types:
//   - SystemCommand: start/stop/restart services (systemctl) — local + SSH only
//   - OrchCommand: audio control (orchestrator JSON-lines) — all transports
//
// The orchestrator protocol is JSON-lines: one JSON object per line.
// Request:  {"op":"ping","id":"req-001"}
// Response: {"v":1,"id":"req-001","ok":true,"data":{"pong":true,...}}

use anyhow::{Result, anyhow};
use serde::{Deserialize, Serialize};
use std::io::{BufRead, BufReader, Write};
use std::process::Command;
use std::time::Duration;

// ── Status struct ─────────────────────────────────────────────────────────

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct DspStatus {
    pub vm_active: bool,
    pub netjack_active: bool,
    pub demod_rt_active: bool,
    pub jack_running: bool,
    pub sample_rate: u32,
    pub buffer_size: u32,
    pub periods: u32,
    pub xrun_count: u64,
    pub callback_count: u64,
    pub cpu_load: f32,
    pub isolated_cpus: String,
    pub hugepages_total: u32,
    pub vfio_bound: bool,
    pub jack_ports: Vec<String>,
    pub latency_input_ms: f32,
    pub latency_output_ms: f32,
    pub latency_roundtrip_ms: f32,
    pub transport: String,
}

impl Default for DspStatus {
    fn default() -> Self {
        Self {
            vm_active: false,
            netjack_active: false,
            demod_rt_active: false,
            jack_running: false,
            sample_rate: 96000,
            buffer_size: 32,
            periods: 2,
            xrun_count: 0,
            callback_count: 0,
            cpu_load: 0.0,
            isolated_cpus: String::new(),
            hugepages_total: 0,
            vfio_bound: false,
            jack_ports: Vec::new(),
            latency_input_ms: 0.46,
            latency_output_ms: 0.67,
            latency_roundtrip_ms: 1.1,
            transport: "local".to_string(),
        }
    }
}

// ── System commands (systemctl — local + SSH only) ───────────────────────

#[derive(Debug, Clone)]
pub enum SystemCommand {
    VmStart,
    VmStop,
    VmRestart,
    NetjackStart,
    NetjackStop,
    NetjackRestart,
    DemodRtStart,
    DemodRtStop,
    DemodRtRestart,
}

impl SystemCommand {
    pub fn service_pair(&self) -> (&'static str, &'static str) {
        match self {
            SystemCommand::VmStart       => ("start",   VM_SERVICE),
            SystemCommand::VmStop        => ("stop",    VM_SERVICE),
            SystemCommand::VmRestart     => ("restart", VM_SERVICE),
            SystemCommand::NetjackStart  => ("start",   NETJACK_SERVICE),
            SystemCommand::NetjackStop   => ("stop",    NETJACK_SERVICE),
            SystemCommand::NetjackRestart=> ("restart", NETJACK_SERVICE),
            SystemCommand::DemodRtStart  => ("start",   DEMOD_RT_SERVICE),
            SystemCommand::DemodRtStop   => ("stop",    DEMOD_RT_SERVICE),
            SystemCommand::DemodRtRestart=> ("restart", DEMOD_RT_SERVICE),
        }
    }
}

// ── Orchestrator commands (JSON-lines — all transports) ──────────────────

#[derive(Debug, Clone)]
pub enum OrchCommand {
    Ping,
    GetHealth,
    ListSlots,
    LoadFx { slot: u8, path: String },
    UnloadFx { slot: u8 },
    SetParam { slot: u8, idx: u8, value: f32 },
    BypassFx { slot: u8, on: bool },
    SetBpm { bpm: f32 },
    SetGain { gain: f32 },
    SetSlotGain { slot: u8, gain: f32 },
    SetSlotMute { slot: u8, on: bool },
    SetSlotPan { slot: u8, pan: f32 },
    SetSlotSolo { slot: u8, on: bool },
}

// ── Orchestrator protocol wire format ─────────────────────────────────────

#[derive(Debug, Serialize, Deserialize)]
pub struct OrchRequest {
    pub op: String,
    pub id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub slot: Option<u8>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub idx: Option<u8>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub value: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub on: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub bpm: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub gain: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pan: Option<f64>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct OrchResponse {
    pub v: u32,
    pub id: String,
    pub ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub data: Option<serde_json::Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub err: Option<String>,
}

impl OrchCommand {
    pub fn to_request(&self, id: &str) -> OrchRequest {
        match self {
            OrchCommand::Ping => OrchRequest { op: "ping".into(), id: id.into(), slot: None, path: None, idx: None, value: None, on: None, bpm: None, gain: None, pan: None },
            OrchCommand::GetHealth => OrchRequest { op: "get_health".into(), id: id.into(), slot: None, path: None, idx: None, value: None, on: None, bpm: None, gain: None, pan: None },
            OrchCommand::ListSlots => OrchRequest { op: "list_slots".into(), id: id.into(), slot: None, path: None, idx: None, value: None, on: None, bpm: None, gain: None, pan: None },
            OrchCommand::LoadFx { slot, path } => OrchRequest { op: "load_fx".into(), id: id.into(), slot: Some(*slot), path: Some(path.clone()), idx: None, value: None, on: None, bpm: None, gain: None, pan: None },
            OrchCommand::UnloadFx { slot } => OrchRequest { op: "unload_fx".into(), id: id.into(), slot: Some(*slot), path: None, idx: None, value: None, on: None, bpm: None, gain: None, pan: None },
            OrchCommand::SetParam { slot, idx, value } => OrchRequest { op: "set_param".into(), id: id.into(), slot: Some(*slot), path: None, idx: Some(*idx), value: Some(*value as f64), on: None, bpm: None, gain: None, pan: None },
            OrchCommand::BypassFx { slot, on } => OrchRequest { op: "bypass_fx".into(), id: id.into(), slot: Some(*slot), path: None, idx: None, value: None, on: Some(*on), bpm: None, gain: None, pan: None },
            OrchCommand::SetBpm { bpm } => OrchRequest { op: "set_bpm".into(), id: id.into(), slot: None, path: None, idx: None, value: None, on: None, bpm: Some(*bpm as f64), gain: None, pan: None },
            OrchCommand::SetGain { gain } => OrchRequest { op: "set_gain".into(), id: id.into(), slot: None, path: None, idx: None, value: None, on: None, bpm: None, gain: Some(*gain as f64), pan: None },
            OrchCommand::SetSlotGain { slot, gain } => OrchRequest { op: "set_slot_gain".into(), id: id.into(), slot: Some(*slot), path: None, idx: None, value: None, on: None, bpm: None, gain: Some(*gain as f64), pan: None },
            OrchCommand::SetSlotMute { slot, on } => OrchRequest { op: "set_slot_mute".into(), id: id.into(), slot: Some(*slot), path: None, idx: None, value: None, on: Some(*on), bpm: None, gain: None, pan: None },
            OrchCommand::SetSlotPan { slot, pan } => OrchRequest { op: "set_slot_pan".into(), id: id.into(), slot: Some(*slot), path: None, idx: None, value: None, on: None, bpm: None, gain: None, pan: Some(*pan as f64) },
            OrchCommand::SetSlotSolo { slot, on } => OrchRequest { op: "set_slot_solo".into(), id: id.into(), slot: Some(*slot), path: None, idx: None, value: None, on: Some(*on), bpm: None, gain: None, pan: None },
        }
    }
}

// ── Meters (parsed from get_health response) ──────────────────────────────

#[derive(Debug, Default, Clone)]
pub struct DspMeters {
    pub cpu_load: f32,
    pub xrun_count: u64,
    pub callback_count: u64,
}

// ── Transport trait ───────────────────────────────────────────────────────

pub trait Transport {
    fn name(&self) -> &str;

    /// System commands (systemctl) — only Local and SSH support these.
    /// TCP/USB/HydraMesh return an error (can't control services remotely
    /// through the orchestrator socket).
    fn send_system(&mut self, _cmd: SystemCommand) -> Result<()> {
        Err(anyhow!("system commands not supported over {} transport", self.name()))
    }

    /// Orchestrator commands (JSON-lines) — all transports support these.
    fn send_orch(&mut self, cmd: OrchCommand) -> Result<OrchResponse>;

    /// Convenience: get health and merge into DspStatus.
    fn get_status(&mut self) -> Result<DspStatus>;
}

// ── Service name constants ────────────────────────────────────────────────

const VM_SERVICE: &str = "archibaldos-dsp.service";
const NETJACK_SERVICE: &str = "dsp-netjack-bridge.service";
const DEMOD_RT_SERVICE: &str = "demod-rt.service";
const CONTROL_SOCK: &str = "/run/demod/control.sock";

// ── Local QEMU transport ──────────────────────────────────────────────────

pub struct LocalTransport;

fn systemctl(action: &str, service: &str) -> Result<()> {
    let status = Command::new("sudo")
        .args(["systemctl", action, service])
        .status()?;
    if !status.success() {
        return Err(anyhow!("systemctl {} {} failed", action, service));
    }
    Ok(())
}

fn is_active(service: &str) -> bool {
    Command::new("systemctl")
        .args(["is-active", "--quiet", service])
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

/// Send an orchestrator command to the local Unix socket at /run/demod/control.sock.
fn send_orch_unix(cmd: &OrchCommand) -> Result<OrchResponse> {
    use std::os::unix::net::UnixStream;
    let mut stream = UnixStream::connect(CONTROL_SOCK)
        .map_err(|e| anyhow!("can't connect to orchestrator socket {}: {}", CONTROL_SOCK, e))?;

    let req = cmd.to_request(&format!("dsp-ctl-{}", std::process::id()));
    let json = serde_json::to_string(&req)?;
    writeln!(stream, "{}", json)?;

    let mut reader = BufReader::new(stream);
    let mut line = String::new();
    reader.read_line(&mut line)?;

    let resp: OrchResponse = serde_json::from_str(line.trim())
        .map_err(|e| anyhow!("can't parse orchestrator response: {} (raw: {})", e, line.trim()))?;
    Ok(resp)
}

impl Transport for LocalTransport {
    fn name(&self) -> &str { "local" }

    fn send_system(&mut self, cmd: SystemCommand) -> Result<()> {
        let (action, service) = cmd.service_pair();
        systemctl(action, service)
    }

    fn send_orch(&mut self, cmd: OrchCommand) -> Result<OrchResponse> {
        send_orch_unix(&cmd)
    }

    fn get_status(&mut self) -> Result<DspStatus> {
        let mut status = DspStatus::default();
        status.transport = "local".to_string();

        // System-level checks (systemctl)
        status.vm_active = is_active(VM_SERVICE);
        status.netjack_active = is_active(NETJACK_SERVICE);
        status.isolated_cpus = std::fs::read_to_string("/sys/devices/system/cpu/isolated")
            .unwrap_or_default().trim().to_string();
        status.vfio_bound = std::path::Path::new("/sys/bus/pci/drivers/vfio-pci/0000:c7:00.3").exists();

        if let Ok(meminfo) = std::fs::read_to_string("/proc/meminfo") {
            for line in meminfo.lines() {
                if line.starts_with("HugePages_Total:") {
                    status.hugepages_total = line.split(':').nth(1)
                        .and_then(|s| s.trim().parse().ok())
                        .unwrap_or(0);
                }
            }
        }

        // JACK ports (local jack_lsp)
        if let Ok(out) = Command::new("jack_lsp").output() {
            status.jack_ports = String::from_utf8_lossy(&out.stdout)
                .lines().map(String::from).collect();
            status.jack_running = !status.jack_ports.is_empty();
        }

        // Orchestrator health (Unix socket — best effort, may not be running)
        if let Ok(resp) = send_orch_unix(&OrchCommand::GetHealth) {
            if resp.ok {
                if let Some(ref data) = resp.data {
                    status.demod_rt_active = data.get("alive")
                        .and_then(|v| v.as_bool()).unwrap_or(false);
                    status.callback_count = data.get("callbacks")
                        .and_then(|v| v.as_u64()).unwrap_or(0);
                    status.xrun_count = data.get("xruns")
                        .and_then(|v| v.as_u64()).unwrap_or(0);
                    status.cpu_load = data.get("cpu_load")
                        .and_then(|v| v.as_f64()).unwrap_or(0.0) as f32;
                }
            }
        } else {
            // Fallback: check systemctl for demod-rt
            status.demod_rt_active = is_active(DEMOD_RT_SERVICE);
        }

        // Latency budget
        let period_ms = status.buffer_size as f32 / status.sample_rate as f32 * 1000.0;
        status.latency_input_ms = period_ms + 0.125;
        status.latency_output_ms = period_ms * 2.0;
        status.latency_roundtrip_ms = status.latency_input_ms + status.latency_output_ms;

        Ok(status)
    }
}

// ── SSH transport ─────────────────────────────────────────────────────────

pub struct SshTransport {
    pub host: String,
    pub user: String,
    pub port: u16,
}

impl SshTransport {
    pub fn new(host: &str, user: &str, port: u16) -> Self {
        Self { host: host.to_string(), user: user.to_string(), port }
    }

    fn ssh(&self, cmd: &str) -> Result<String> {
        let output = Command::new("ssh")
            .args([
                "-p", &self.port.to_string(),
                "-o", "ConnectTimeout=5",
                &format!("{}@{}", self.user, self.host),
                cmd,
            ])
            .output()?;
        if !output.status.success() {
            return Err(anyhow!("SSH command failed: {}", String::from_utf8_lossy(&output.stderr)));
        }
        Ok(String::from_utf8_lossy(&output.stdout).to_string())
    }
}

impl Transport for SshTransport {
    fn name(&self) -> &str { "ssh" }

    fn send_system(&mut self, cmd: SystemCommand) -> Result<()> {
        let (action, service) = cmd.service_pair();
        self.ssh(&format!("sudo systemctl {} {}", action, service))?;
        Ok(())
    }

    fn send_orch(&mut self, cmd: OrchCommand) -> Result<OrchResponse> {
        let req = cmd.to_request("ssh-req");
        let json = serde_json::to_string(&req)?;
        // Pipe JSON through SSH to socat, which connects to the Unix socket
        let escaped = json.replace("'", "'\\''");
        let output = self.ssh(&format!(
            "echo '{}' | socat - UNIX-CONNECT:{}",
            escaped, CONTROL_SOCK
        ))?;
        let resp: OrchResponse = serde_json::from_str(output.trim())
            .map_err(|e| anyhow!("can't parse SSH orchestrator response: {} (raw: {})", e, output.trim()))?;
        Ok(resp)
    }

    fn get_status(&mut self) -> Result<DspStatus> {
        let mut status = DspStatus::default();
        status.transport = format!("ssh://{}@{}:{}", self.user, self.host, self.port);

        // Orchestrator health via SSH
        if let Ok(resp) = self.send_orch(OrchCommand::GetHealth) {
            if resp.ok {
                if let Some(ref data) = resp.data {
                    status.demod_rt_active = data.get("alive")
                        .and_then(|v| v.as_bool()).unwrap_or(false);
                    status.callback_count = data.get("callbacks")
                        .and_then(|v| v.as_u64()).unwrap_or(0);
                    status.xrun_count = data.get("xruns")
                        .and_then(|v| v.as_u64()).unwrap_or(0);
                    status.cpu_load = data.get("cpu_load")
                        .and_then(|v| v.as_f64()).unwrap_or(0.0) as f32;
                }
            }
        }

        // JACK ports via SSH
        if let Ok(ports) = self.ssh("jack_lsp 2>/dev/null") {
            status.jack_ports = ports.lines().filter(|l| !l.is_empty()).map(String::from).collect();
            status.jack_running = !status.jack_ports.is_empty();
        }

        // Service status via SSH
        let vm_state = self.ssh("systemctl is-active archibaldos-dsp.service 2>/dev/null || true").unwrap_or_default();
        status.vm_active = vm_state.trim() == "active";
        let nj_state = self.ssh("systemctl is-active jack2-netjack-master.service 2>/dev/null || true").unwrap_or_default();
        status.netjack_active = nj_state.trim() == "active";

        let period_ms = status.buffer_size as f32 / status.sample_rate as f32 * 1000.0;
        status.latency_input_ms = period_ms + 0.125;
        status.latency_output_ms = period_ms * 2.0;
        status.latency_roundtrip_ms = status.latency_input_ms + status.latency_output_ms;

        Ok(status)
    }
}

// ── TCP/IP transport ──────────────────────────────────────────────────────
// Connects to a TCP socket (port 7777) on the DSP coprocessor. On the
// coprocessor side, socat bridges TCP:7777 → /run/demod/control.sock.
// Works over any IP network including USB networking (RNDIS/CDC-ECM).

pub struct TcpTransport {
    pub host: String,
    pub port: u16,
    pub stream: Option<std::net::TcpStream>,
}

impl TcpTransport {
    pub fn new(host: &str, port: u16) -> Self {
        Self { host: host.to_string(), port, stream: None }
    }

    fn connect(&mut self) -> Result<&std::net::TcpStream> {
        if self.stream.is_none() {
            let addr = format!("{}:{}", self.host, self.port);
            let stream = std::net::TcpStream::connect_timeout(
                &addr.parse()?,
                Duration::from_secs(5),
            )?;
            stream.set_read_timeout(Some(Duration::from_secs(5)))?;
            stream.set_write_timeout(Some(Duration::from_secs(5)))?;
            self.stream = Some(stream);
        }
        Ok(self.stream.as_ref().unwrap())
    }
}

impl Transport for TcpTransport {
    fn name(&self) -> &str { "tcp" }

    // send_system returns Err — can't systemctl over the orchestrator socket

    fn send_orch(&mut self, cmd: OrchCommand) -> Result<OrchResponse> {
        let mut stream = self.connect()?;
        let req = cmd.to_request(&format!("dsp-ctl-{}", std::process::id()));
        let json = serde_json::to_string(&req)?;
        writeln!(stream, "{}", json)?;

        let mut reader = BufReader::new(stream);
        let mut line = String::new();
        reader.read_line(&mut line)?;

        let resp: OrchResponse = serde_json::from_str(line.trim())
            .map_err(|e| anyhow!("can't parse TCP response: {} (raw: {})", e, line.trim()))?;
        Ok(resp)
    }

    fn get_status(&mut self) -> Result<DspStatus> {
        let mut status = DspStatus::default();
        status.transport = format!("tcp://{}:{}", self.host, self.port);

        let resp = self.send_orch(OrchCommand::GetHealth)?;
        if !resp.ok {
            return Err(anyhow!("get_health failed: {}", resp.err.unwrap_or_default()));
        }
        if let Some(ref data) = resp.data {
            status.demod_rt_active = data.get("alive")
                .and_then(|v| v.as_bool()).unwrap_or(false);
            status.callback_count = data.get("callbacks")
                .and_then(|v| v.as_u64()).unwrap_or(0);
            status.xrun_count = data.get("xruns")
                .and_then(|v| v.as_u64()).unwrap_or(0);
            status.cpu_load = data.get("cpu_load")
                .and_then(|v| v.as_f64()).unwrap_or(0.0) as f32;
        }

        let period_ms = status.buffer_size as f32 / status.sample_rate as f32 * 1000.0;
        status.latency_input_ms = period_ms + 0.125;
        status.latency_output_ms = period_ms * 2.0;
        status.latency_roundtrip_ms = status.latency_input_ms + status.latency_output_ms;

        Ok(status)
    }
}

// ── USB networking transport ──────────────────────────────────────────────
// USB RNDIS/CDC-ECM creates a virtual network interface. The DSP coprocessor
// gets an IP like 169.254.42.1. Under the hood this is just TCP.

pub fn usb_transport(ip: &str, port: u16) -> TcpTransport {
    TcpTransport::new(ip, port)
}

// ── HydraMesh raw ethernet transport (stubbed) ────────────────────────────

pub struct HydraMeshTransport {
    pub interface: String,
    pub peer_mac: [u8; 6],
}

impl HydraMeshTransport {
    pub fn new(interface: &str, peer_mac: [u8; 6]) -> Self {
        Self { interface: interface.to_string(), peer_mac }
    }
}

impl Transport for HydraMeshTransport {
    fn name(&self) -> &str { "hydramesh" }

    fn send_orch(&mut self, cmd: OrchCommand) -> Result<OrchResponse> {
        let req = cmd.to_request("hydramesh");
        let json = serde_json::to_string(&req)?;
        Err(anyhow!(
            "HydraMesh raw ethernet transport not yet implemented.\n\
             Command: {}\n\
             Interface: {}, Peer MAC: {:02x}:{:02x}:{:02x}:{:02x}:{:02x}:{:02x}\n\
             \n\
             Requires AF_PACKET socket + DCF frame encoding. Use --transport tcp\n\
             as a fallback over the same ethernet link.",
            json,
            self.interface,
            self.peer_mac[0], self.peer_mac[1], self.peer_mac[2],
            self.peer_mac[3], self.peer_mac[4], self.peer_mac[5],
        ))
    }

    fn get_status(&mut self) -> Result<DspStatus> {
        Err(anyhow!("HydraMesh transport not yet implemented"))
    }
}

// ── Transport factory ─────────────────────────────────────────────────────

#[derive(Debug, Clone)]
pub enum TransportSpec {
    Local,
    Ssh { host: String, user: String, port: u16 },
    Tcp { host: String, port: u16 },
    Usb { ip: String, port: u16 },
    HydraMesh { interface: String, peer_mac: [u8; 6] },
}

impl TransportSpec {
    pub fn create(&self) -> Box<dyn Transport> {
        match self {
            TransportSpec::Local => Box::new(LocalTransport),
            TransportSpec::Ssh { host, user, port } => {
                Box::new(SshTransport::new(host, user, *port))
            }
            TransportSpec::Tcp { host, port } => {
                Box::new(TcpTransport::new(host, *port))
            }
            TransportSpec::Usb { ip, port } => {
                Box::new(usb_transport(ip, *port))
            }
            TransportSpec::HydraMesh { interface, peer_mac } => {
                Box::new(HydraMeshTransport::new(interface, *peer_mac))
            }
        }
    }

    pub fn name(&self) -> &str {
        match self {
            TransportSpec::Local => "local",
            TransportSpec::Ssh { .. } => "ssh",
            TransportSpec::Tcp { .. } => "tcp",
            TransportSpec::Usb { .. } => "usb",
            TransportSpec::HydraMesh { .. } => "hydramesh",
        }
    }
}
