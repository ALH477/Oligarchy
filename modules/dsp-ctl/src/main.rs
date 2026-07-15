// SPDX-License-Identifier: MIT
// dsp-ctl — DSP Coprocessor Control
// TUI/CLI for managing the ArchibaldOS DSP coprocessor over any transport:
//   local    — QEMU/KVM VM on this host (Unix socket + systemctl)
//   ssh      — remote ArchibaldOS direct hardware over SSH
//   tcp      — IP network (socat bridge → orchestrator socket, port 7777)
//   usb      — USB networking (RNDIS/CDC-ECM, appears as TCP)
//   hydramesh — raw ethernet DCF frames (stubbed)
//
// Usage:
//   dsp-ctl                                    — TUI dashboard (local)
//   dsp-ctl --transport tcp --host 10.0.0.2    — TUI over TCP
//   dsp-ctl status                             — full status (local)
//   dsp-ctl --transport ssh --host pi status   — status over SSH
//   dsp-ctl start                              — start all services (local/ssh)
//   dsp-ctl stop                               — stop all services
//   dsp-ctl health                             — orchestrator get_health
//   dsp-ctl slots                              — list FX slots
//   dsp-ctl ping                               — ping orchestrator
//   dsp-ctl load-fx 0 /path/to/effect.so       — load Faust effect
//   dsp-ctl unload-fx 0                        — unload Faust effect
//   dsp-ctl set-param 0 0 0.75                 — set FX parameter
//   dsp-ctl bypass-fx 1 true                   — bypass FX slot
//   dsp-ctl set-bpm 120                        — set BPM
//   dsp-ctl set-gain 0.8                       — set master gain
//   dsp-ctl latency                            — show latency budget
//   dsp-ctl ports                              — list JACK ports

use anyhow::Result;
use clap::{Parser, Subcommand};
use crate::transport::TransportSpec;

mod cli;
mod tui;
mod transport;

#[derive(Parser)]
#[command(name = "dsp-ctl")]
#[command(about = "DSP Coprocessor Control — manage ArchibaldOS DSP over local/SSH/TCP/USB/HydraMesh")]
struct Cli {
    /// Transport method for communicating with the DSP coprocessor
    #[arg(long, default_value = "local")]
    transport: String,

    /// Remote host (for ssh, tcp, usb transports)
    #[arg(long)]
    host: Option<String>,

    /// SSH user (for ssh transport)
    #[arg(long)]
    user: Option<String>,

    /// SSH port (for ssh transport)
    #[arg(long, default_value = "22")]
    ssh_port: u16,

    /// TCP control port (for tcp, usb transports — socat bridge on DSP coprocessor)
    #[arg(long, default_value = "7777")]
    port: u16,

    /// USB networking IP (for usb transport — shortcut for tcp --host <ip>)
    #[arg(long)]
    ip: Option<String>,

    /// Network interface (for hydramesh transport)
    #[arg(long)]
    interface: Option<String>,

    /// Peer MAC address (for hydramesh transport, format: aa:bb:cc:dd:ee:ff)
    #[arg(long)]
    peer_mac: Option<String>,

    #[command(subcommand)]
    command: Option<Commands>,
}

#[derive(Subcommand)]
enum Commands {
    /// Show full status (system + orchestrator health)
    Status,
    /// Start all DSP services (VM + NETJACK + demod-rt) — local/ssh only
    Start,
    /// Stop all DSP services — local/ssh only
    Stop,
    /// Restart NETJACK bridge — local/ssh only
    Restart,
    /// Control the QEMU/KVM VM (local/ssh only)
    Vm { #[command(subcommand)] action: ServiceAction },
    /// Control the NETJACK bridge (local/ssh only)
    Netjack { #[command(subcommand)] action: ServiceAction },
    /// Control the demod-rt engine (local/ssh only)
    DemodRt { #[command(subcommand)] action: ServiceAction },
    /// Ping the orchestrator (all transports)
    Ping,
    /// Get orchestrator health (all transports)
    Health,
    /// List FX slots (all transports)
    Slots,
    /// List JACK ports (local/ssh only)
    Ports,
    /// Show latency budget breakdown
    Latency,
    /// Load a Faust .so into an FX slot (all transports)
    LoadFx { slot: u8, path: String },
    /// Unload a Faust FX slot (all transports)
    UnloadFx { slot: u8 },
    /// Set an FX parameter (all transports)
    SetParam { slot: u8, idx: u8, value: f32 },
    /// Bypass/unbypass an FX slot (all transports)
    BypassFx { slot: u8, on: bool },
    /// Set BPM (all transports)
    SetBpm { bpm: f32 },
    /// Set master gain (all transports)
    SetGain { gain: f32 },
}

#[derive(Subcommand)]
enum ServiceAction {
    Start,
    Stop,
    Restart,
    Status,
}

fn parse_mac(s: &str) -> Result<[u8; 6]> {
    let parts: Vec<&str> = s.split(':').collect();
    if parts.len() != 6 {
        return Err(anyhow::anyhow!("MAC must be aa:bb:cc:dd:ee:ff"));
    }
    let mut mac = [0u8; 6];
    for (i, p) in parts.iter().enumerate() {
        mac[i] = u8::from_str_radix(p, 16)
            .map_err(|e| anyhow::anyhow!("invalid MAC byte {}: {}", p, e))?;
    }
    Ok(mac)
}

fn build_transport_spec(cli: &Cli) -> Result<TransportSpec> {
    match cli.transport.as_str() {
        "local" => Ok(TransportSpec::Local),
        "ssh" => {
            let host = cli.host.as_deref().ok_or_else(|| anyhow::anyhow!("--host required for ssh transport"))?;
            let user = cli.user.as_deref().unwrap_or("dsp");
            Ok(TransportSpec::Ssh { host: host.to_string(), user: user.to_string(), port: cli.ssh_port })
        }
        "tcp" => {
            let host = cli.host.as_deref().ok_or_else(|| anyhow::anyhow!("--host required for tcp transport"))?;
            Ok(TransportSpec::Tcp { host: host.to_string(), port: cli.port })
        }
        "usb" => {
            let ip = cli.ip.as_deref().or(cli.host.as_deref())
                .ok_or_else(|| anyhow::anyhow!("--ip required for usb transport"))?;
            Ok(TransportSpec::Usb { ip: ip.to_string(), port: cli.port })
        }
        "hydramesh" => {
            let interface = cli.interface.as_deref()
                .ok_or_else(|| anyhow::anyhow!("--interface required for hydramesh transport"))?;
            let peer_mac = parse_mac(cli.peer_mac.as_deref()
                .ok_or_else(|| anyhow::anyhow!("--peer-mac required for hydramesh transport"))?)?;
            Ok(TransportSpec::HydraMesh { interface: interface.to_string(), peer_mac })
        }
        _ => Err(anyhow::anyhow!("unknown transport: {} (use: local, ssh, tcp, usb, hydramesh)", cli.transport)),
    }
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    let transport = build_transport_spec(&cli)?;

    match cli.command {
        Some(Commands::Status) => cli::cmd_status(&transport),
        Some(Commands::Start) => cli::cmd_start(&transport),
        Some(Commands::Stop) => cli::cmd_stop(&transport),
        Some(Commands::Restart) => cli::cmd_restart_netjack(&transport),
        Some(Commands::Vm { action }) => cli::cmd_service(&transport, "vm", match action {
            ServiceAction::Start => "start", ServiceAction::Stop => "stop",
            ServiceAction::Restart => "restart", ServiceAction::Status => "status",
        }),
        Some(Commands::Netjack { action }) => cli::cmd_service(&transport, "netjack", match action {
            ServiceAction::Start => "start", ServiceAction::Stop => "stop",
            ServiceAction::Restart => "restart", ServiceAction::Status => "status",
        }),
        Some(Commands::DemodRt { action }) => cli::cmd_service(&transport, "demod-rt", match action {
            ServiceAction::Start => "start", ServiceAction::Stop => "stop",
            ServiceAction::Restart => "restart", ServiceAction::Status => "status",
        }),
        Some(Commands::Ping) => cli::cmd_ping(&transport),
        Some(Commands::Health) => cli::cmd_health(&transport),
        Some(Commands::Slots) => cli::cmd_slots(&transport),
        Some(Commands::Ports) => cli::cmd_ports(&transport),
        Some(Commands::Latency) => cli::cmd_latency(&transport),
        Some(Commands::LoadFx { slot, path }) => cli::cmd_load_fx(&transport, slot, &path),
        Some(Commands::UnloadFx { slot }) => cli::cmd_unload_fx(&transport, slot),
        Some(Commands::SetParam { slot, idx, value }) => cli::cmd_set_param(&transport, slot, idx, value),
        Some(Commands::BypassFx { slot, on }) => cli::cmd_bypass_fx(&transport, slot, on),
        Some(Commands::SetBpm { bpm }) => cli::cmd_set_bpm(&transport, bpm),
        Some(Commands::SetGain { gain }) => cli::cmd_set_gain(&transport, gain),
        None => tui::run_dashboard(transport),
    }
}
