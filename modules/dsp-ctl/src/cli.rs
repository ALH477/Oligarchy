// SPDX-License-Identifier: MIT
// CLI subcommands — all go through the Transport trait.
// System commands (start/stop/restart) use send_system (local/ssh only).
// Orchestrator commands (ping/health/slots/load_fx/etc) use send_orch (all transports).

use anyhow::Result;
use crate::transport::{TransportSpec, SystemCommand, OrchCommand, DspStatus};

pub fn cmd_status(transport: &TransportSpec) -> Result<()> {
    let mut t = transport.create();
    let status = t.get_status()?;
    print_status_table(&status);
    Ok(())
}

pub fn cmd_start(transport: &TransportSpec) -> Result<()> {
    let mut t = transport.create();
    println!("Starting DSP VM...");
    let _ = t.send_system(SystemCommand::VmStart);
    println!("Waiting for boot...");
    std::thread::sleep(std::time::Duration::from_secs(15));
    println!("Starting NETJACK bridge...");
    let _ = t.send_system(SystemCommand::NetjackStart);
    std::thread::sleep(std::time::Duration::from_secs(3));
    println!("Starting demod-rt...");
    let _ = t.send_system(SystemCommand::DemodRtStart);
    println!("✓ DSP coprocessor online");
    let status = t.get_status()?;
    print_status_table(&status);
    Ok(())
}

pub fn cmd_stop(transport: &TransportSpec) -> Result<()> {
    let mut t = transport.create();
    let _ = t.send_system(SystemCommand::DemodRtStop);
    let _ = t.send_system(SystemCommand::NetjackStop);
    let _ = t.send_system(SystemCommand::VmStop);
    println!("✓ DSP coprocessor offline");
    Ok(())
}

pub fn cmd_restart_netjack(transport: &TransportSpec) -> Result<()> {
    let mut t = transport.create();
    t.send_system(SystemCommand::NetjackRestart)?;
    std::thread::sleep(std::time::Duration::from_secs(3));
    println!("✓ NETJACK bridge restarted");
    Ok(())
}

pub fn cmd_service(transport: &TransportSpec, service: &str, action: &str) -> Result<()> {
    let mut t = transport.create();
    let cmd = match (service, action) {
        ("vm", "start") => SystemCommand::VmStart,
        ("vm", "stop") => SystemCommand::VmStop,
        ("vm", "restart") => SystemCommand::VmRestart,
        ("netjack", "start") => SystemCommand::NetjackStart,
        ("netjack", "stop") => SystemCommand::NetjackStop,
        ("netjack", "restart") => SystemCommand::NetjackRestart,
        ("demod-rt", "start") => SystemCommand::DemodRtStart,
        ("demod-rt", "stop") => SystemCommand::DemodRtStop,
        ("demod-rt", "restart") => SystemCommand::DemodRtRestart,
        _ => return Err(anyhow::anyhow!("unknown service/action: {} {}", service, action)),
    };
    if action == "status" {
        let status = t.get_status()?;
        let active = match service {
            "vm" => status.vm_active,
            "netjack" => status.netjack_active,
            "demod-rt" => status.demod_rt_active,
            _ => false,
        };
        println!("{}: {}", service, if active { "● ACTIVE" } else { "○ INACTIVE" });
        return Ok(());
    }
    t.send_system(cmd)?;
    println!("✓ {} {}", service, action);
    Ok(())
}

// ── Orchestrator commands (all transports) ────────────────────────────────

pub fn cmd_ping(transport: &TransportSpec) -> Result<()> {
    let mut t = transport.create();
    let resp = t.send_orch(OrchCommand::Ping)?;
    if resp.ok {
        println!("✓ pong (queued)");
    } else {
        println!("✗ ping failed: {}", resp.err.unwrap_or_default());
    }
    Ok(())
}

pub fn cmd_health(transport: &TransportSpec) -> Result<()> {
    let mut t = transport.create();
    let resp = t.send_orch(OrchCommand::GetHealth)?;
    if !resp.ok {
        return Err(anyhow::anyhow!("get_health failed: {}", resp.err.unwrap_or_default()));
    }
    if let Some(data) = resp.data {
        println!("╔══════════════════════════════════════════════════════════════╗");
        println!("║           Orchestrator Health                                ║");
        println!("╠══════════════════════════════════════════════════════════════╣");
        println!("║  Alive:       {:>10}                                       ║", data.get("alive").and_then(|v| v.as_bool()).unwrap_or(false));
        println!("║  Callbacks:   {:>10}                                       ║", data.get("callbacks").and_then(|v| v.as_u64()).unwrap_or(0));
        println!("║  Xruns:       {:>10}                                       ║", data.get("xruns").and_then(|v| v.as_u64()).unwrap_or(0));
        println!("║  CPU Load:    {:>9.1}%                                      ║", data.get("cpu_load").and_then(|v| v.as_f64()).unwrap_or(0.0) * 100.0);
        println!("╚══════════════════════════════════════════════════════════════╝");
    }
    Ok(())
}

pub fn cmd_slots(transport: &TransportSpec) -> Result<()> {
    let mut t = transport.create();
    let resp = t.send_orch(OrchCommand::ListSlots)?;
    if !resp.ok {
        return Err(anyhow::anyhow!("list_slots failed: {}", resp.err.unwrap_or_default()));
    }
    if let Some(data) = resp.data {
        if let Some(slots) = data.as_array() {
            println!("FX Slots ({}):", slots.len());
            for slot in slots {
                let idx = slot.get("slot").and_then(|v| v.as_u64()).unwrap_or(0);
                let loaded = slot.get("loaded").and_then(|v| v.as_bool()).unwrap_or(false);
                let path = slot.get("path").and_then(|v| v.as_str()).unwrap_or("");
                let bypassed = slot.get("bypassed").and_then(|v| v.as_bool()).unwrap_or(false);
                println!("  Slot {:>2}: {} {}{}", idx,
                    if loaded { "● LOADED" } else { "○ empty" },
                    if bypassed { "(BYPASSED) " } else { "" },
                    path);
            }
        }
    }
    Ok(())
}

pub fn cmd_ports(transport: &TransportSpec) -> Result<()> {
    let mut t = transport.create();
    let status = t.get_status()?;
    if status.jack_ports.is_empty() {
        println!("No JACK ports visible (is JACK running?)");
    } else {
        println!("JACK Ports ({}):", status.jack_ports.len());
        for p in &status.jack_ports {
            println!("  {}", p);
        }
    }
    Ok(())
}

pub fn cmd_latency(transport: &TransportSpec) -> Result<()> {
    let mut t = transport.create();
    let status = t.get_status()?;
    let period_ms = status.buffer_size as f32 / status.sample_rate as f32 * 1000.0;

    println!("╔══════════════════════════════════════════════════════════╗");
    println!("║         DSP Coprocessor Latency Budget                    ║");
    println!("╠══════════════════════════════════════════════════════════╣");
    println!("║  Transport:     {:<41}║", t.name());
    println!("║  Sample Rate:   {:>6} Hz                            ║", status.sample_rate);
    println!("║  Buffer Size:   {:>6} samples                        ║", status.buffer_size);
    println!("║  Periods (n):   {:>6}                                ║", status.periods);
    println!("║  Period time:   {:>6.3} ms                           ║", period_ms);
    println!("║                                                          ║");
    println!("║  INPUT (instrument → DSP):                               ║");
    println!("║    USB micro-frame:  {:>6.3} ms                         ║", 0.125_f32);
    println!("║    ALSA period:      {:>6.3} ms                         ║", period_ms);
    println!("║    Input total:      {:>6.3} ms                         ║", status.latency_input_ms);
    println!("║                                                          ║");
    println!("║  OUTPUT (DSP → speakers):                                ║");
    println!("║    NETJACK+PipeWire: {:>6.3} ms                         ║", status.latency_output_ms);
    println!("║                                                          ║");
    println!("║  ROUND-TRIP:         {:>6.3} ms                         ║", status.latency_roundtrip_ms);
    println!("║  Xruns:              {:>6}                              ║", status.xrun_count);
    println!("║  CPU Load:           {:>5.1}%                            ║", status.cpu_load * 100.0);
    println!("║                                                          ║");
    println!("╚══════════════════════════════════════════════════════════╝");
    Ok(())
}

pub fn cmd_load_fx(transport: &TransportSpec, slot: u8, path: &str) -> Result<()> {
    let mut t = transport.create();
    let resp = t.send_orch(OrchCommand::LoadFx { slot, path: path.to_string() })?;
    if resp.ok { println!("✓ Loading Faust .so into slot {} ← {}", slot, path); }
    else { println!("✗ load_fx failed: {}", resp.err.unwrap_or_default()); }
    Ok(())
}

pub fn cmd_unload_fx(transport: &TransportSpec, slot: u8) -> Result<()> {
    let mut t = transport.create();
    let resp = t.send_orch(OrchCommand::UnloadFx { slot })?;
    if resp.ok { println!("✓ Unloaded Faust slot {}", slot); }
    else { println!("✗ unload_fx failed: {}", resp.err.unwrap_or_default()); }
    Ok(())
}

pub fn cmd_set_param(transport: &TransportSpec, slot: u8, idx: u8, value: f32) -> Result<()> {
    let mut t = transport.create();
    let resp = t.send_orch(OrchCommand::SetParam { slot, idx, value })?;
    if resp.ok { println!("✓ Set slot {} param {} = {}", slot, idx, value); }
    else { println!("✗ set_param failed: {}", resp.err.unwrap_or_default()); }
    Ok(())
}

pub fn cmd_bypass_fx(transport: &TransportSpec, slot: u8, on: bool) -> Result<()> {
    let mut t = transport.create();
    let resp = t.send_orch(OrchCommand::BypassFx { slot, on })?;
    if resp.ok { println!("✓ Slot {} bypass = {}", slot, on); }
    else { println!("✗ bypass_fx failed: {}", resp.err.unwrap_or_default()); }
    Ok(())
}

pub fn cmd_set_bpm(transport: &TransportSpec, bpm: f32) -> Result<()> {
    let mut t = transport.create();
    let resp = t.send_orch(OrchCommand::SetBpm { bpm })?;
    if resp.ok { println!("✓ BPM = {}", bpm); }
    else { println!("✗ set_bpm failed: {}", resp.err.unwrap_or_default()); }
    Ok(())
}

pub fn cmd_set_gain(transport: &TransportSpec, gain: f32) -> Result<()> {
    let mut t = transport.create();
    let resp = t.send_orch(OrchCommand::SetGain { gain })?;
    if resp.ok { println!("✓ Master gain = {}", gain); }
    else { println!("✗ set_gain failed: {}", resp.err.unwrap_or_default()); }
    Ok(())
}

pub fn print_status_table(status: &DspStatus) {
    println!("╔══════════════════════════════════════════════════════════════╗");
    println!("║           DSP Coprocessor Status                              ║");
    println!("╠══════════════════════════════════════════════════════════════╣");
    println!("║  Transport:     {:<44}║", status.transport);
    println!("║                                                              ║");
    println!("║  DSP VM:        {:>10}                                      ║", if status.vm_active { "● ACTIVE" } else { "○ INACTIVE" });
    println!("║  NETJACK:       {:>10}                                      ║", if status.netjack_active { "● ACTIVE" } else { "○ INACTIVE" });
    println!("║  demod-rt:      {:>10}                                      ║", if status.demod_rt_active { "● ACTIVE" } else { "○ INACTIVE" });
    println!("║  JACK:          {:>10}                                      ║", if status.jack_running { "● RUNNING" } else { "○ STOPPED" });
    println!("╠══════════════════════════════════════════════════════════════╣");
    println!("║  Sample Rate:   {:>6} Hz                                    ║", status.sample_rate);
    println!("║  Buffer Size:   {:>6} samples ({:.2}ms period)               ║", status.buffer_size, status.buffer_size as f32 / status.sample_rate as f32 * 1000.0);
    println!("║  Xruns:         {:>6}                                       ║", status.xrun_count);
    println!("║  CPU Load:      {:>5.1}%                                      ║", status.cpu_load * 100.0);
    println!("║  Callbacks:     {:>6}                                       ║", status.callback_count);
    println!("╠══════════════════════════════════════════════════════════════╣");
    println!("║  CPU Isolated:  {:<44}║", if status.isolated_cpus.is_empty() { "none" } else { &status.isolated_cpus });
    println!("║  Hugepages:     {:>6}                                       ║", status.hugepages_total);
    println!("║  VFIO c7:00.3:  {:>10}                                      ║", if status.vfio_bound { "● BOUND" } else { "○ HOST" });
    println!("║  JACK Ports:    {:>3} visible                                 ║", status.jack_ports.len());
    println!("╠══════════════════════════════════════════════════════════════╣");
    println!("║  Latency:       input {:.3}ms → output {:.3}ms = {:.3}ms RT   ║", status.latency_input_ms, status.latency_output_ms, status.latency_roundtrip_ms);
    println!("╚══════════════════════════════════════════════════════════════╝");
}
