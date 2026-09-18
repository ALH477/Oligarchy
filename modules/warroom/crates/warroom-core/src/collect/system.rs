//! SITREP collector — sysinfo + /etc/oligarchy/persona + powerprofilesctl
//!
//! OWNER: work stream S1.
//!
//! This is the only collector on a 1s interval, so it is also the only one
//! where forking anything at all is a real cost. Load/memory/temperature come
//! from `sysinfo` (which reads /proc and /sys directly — no subprocess), the
//! kernel release is read once and cached because it cannot change without a
//! reboot, and `powerprofilesctl` — the single subprocess here — is throttled
//! to once every `POWER_PROFILE_TTL` rather than once a second. The persona
//! file is a handful of bytes off a tmpfs-backed /etc symlink, so it is read
//! every tick and not cached: it *can* change under a `nixos-rebuild switch`
//! and a stale persona on a dashboard is exactly the lie this pane exists to
//! avoid.

use crate::model::{Availability, Health, Panel};
use std::time::{Duration, Instant};
use sysinfo::{CpuRefreshKind, MemoryRefreshKind, RefreshKind, System};

/// Plain-text single-line file written by `modules/personas.nix`.
const PERSONA_FILE: &str = "/etc/oligarchy/persona";
const OSRELEASE: &str = "/proc/sys/kernel/osrelease";

/// `powerprofilesctl` talks to power-profiles-daemon over D-Bus; at a 1s
/// cadence that is a fork and a bus round trip per frame for a value that
/// changes when a human clicks something. Ten seconds is plenty.
const POWER_PROFILE_TTL: Duration = Duration::from_secs(10);
const POWER_PROFILE_TIMEOUT: Duration = Duration::from_millis(700);

pub struct SystemCollector {
    sys: System,
    components: sysinfo::Components,
    /// Cached because `/proc/sys/kernel/osrelease` cannot change while this
    /// process lives.
    kernel: Option<String>,
    power_profile: Option<String>,
    power_checked: Option<Instant>,
}

impl SystemCollector {
    pub fn new() -> Self {
        let refresh = RefreshKind::new()
            .with_memory(MemoryRefreshKind::everything())
            .with_cpu(CpuRefreshKind::new().with_cpu_usage());
        SystemCollector {
            sys: System::new_with_specifics(refresh),
            components: sysinfo::Components::new_with_refreshed_list(),
            kernel: None,
            power_profile: None,
            power_checked: None,
        }
    }

    fn kernel(&mut self) -> Option<&str> {
        if self.kernel.is_none() {
            self.kernel = std::fs::read_to_string(OSRELEASE)
                .ok()
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty());
        }
        self.kernel.as_deref()
    }

    /// `None` when power-profiles-daemon is absent or did not answer. Never an
    /// error: a laptop without ppd is a normal laptop, not a broken one.
    fn power_profile(&mut self) -> Option<&str> {
        let due = match self.power_checked {
            None => true,
            Some(t) => t.elapsed() >= POWER_PROFILE_TTL,
        };
        if due {
            self.power_checked = Some(Instant::now());
            self.power_profile = crate::exec::which("powerprofilesctl").and_then(|_| {
                crate::exec::run("powerprofilesctl", &["get"], POWER_PROFILE_TIMEOUT)
                    .ok()
                    .map(|s| s.trim().to_string())
                    .filter(|s| !s.is_empty())
            });
        }
        self.power_profile.as_deref()
    }
}

impl Default for SystemCollector {
    fn default() -> Self {
        Self::new()
    }
}

/// The persona is a single bare word (`dev`, `studio`, ...) with no trailing
/// newline guaranteed. Anything multi-line or empty is treated as absent
/// rather than rendered raw into a one-line pane.
fn read_persona() -> Option<String> {
    let raw = std::fs::read_to_string(PERSONA_FILE).ok()?;
    let first = raw.lines().next()?.trim();
    (!first.is_empty()).then(|| first.to_string())
}

fn fmt_gib(bytes: u64) -> String {
    format!("{:.1} GiB", bytes as f64 / 1_073_741_824.0)
}

/// `1d 04:31` / `4h 31m` / `12m`. Deliberately compact: this shares a line
/// with three other values.
fn fmt_uptime(secs: u64) -> String {
    let d = secs / 86_400;
    let h = (secs % 86_400) / 3_600;
    let m = (secs % 3_600) / 60;
    if d > 0 {
        format!("{d}d {h}h {m}m")
    } else if h > 0 {
        format!("{h}h {m}m")
    } else {
        format!("{m}m")
    }
}

/// Load average relative to core count. One runnable task per core is the
/// point at which latency starts being paid, which is what a war room cares
/// about — an absolute threshold would be meaningless across hosts.
fn load_health(one: f64, cores: usize) -> Health {
    if cores == 0 {
        return Health::Unknown;
    }
    let per_core = one / cores as f64;
    if per_core >= 1.5 {
        Health::Bad
    } else if per_core >= 0.9 {
        Health::Warn
    } else {
        Health::Good
    }
}

fn mem_health(used: u64, total: u64) -> Health {
    if total == 0 {
        return Health::Unknown;
    }
    let frac = used as f64 / total as f64;
    if frac >= 0.92 {
        Health::Bad
    } else if frac >= 0.80 {
        Health::Warn
    } else {
        Health::Good
    }
}

/// Judge an instantaneous `k10temp Tctl` sample.
///
/// Calibrated against the real sensor on this host: ~45C idle, 83C moments
/// after a build, 99.8C *during* one. AMD's 7040 boost algorithm deliberately
/// runs the package up to Tjmax (100C) and clocks back — so a reading in the
/// high 90s is the governor working, not a cooling failure.
///
/// Which is why nothing here returns `Bad`. A single sample cannot distinguish
/// "boosting as designed" from "the fan died", and the difference is *duration*,
/// which this collector does not measure. Claiming `Bad` would be exactly the
/// dishonest-health case the pane is built to avoid; `Warn` says the true thing
/// — the package is thermally saturated right now.
fn temp_health(c: f32) -> Health {
    if !c.is_finite() || c <= 0.0 {
        Health::Unknown
    } else if c >= 90.0 {
        Health::Warn
    } else {
        Health::Good
    }
}

/// Pick the component that actually represents the CPU package.
///
/// `Components` on this platform yields a mix of `k10temp Tctl`, per-NVMe
/// `Composite`, battery and wifi sensors. Taking the hottest would happily
/// report an SSD; taking the first would report whatever hwmon enumerated
/// first. So: match the known CPU-package labels in preference order, and
/// return `None` — not a guess — when none of them is present.
fn cpu_temp(components: &sysinfo::Components) -> Option<(String, f32)> {
    const PREFERRED: [&str; 4] = ["tctl", "package id", "tdie", "coretemp"];
    for want in PREFERRED {
        for c in components.list() {
            let label = c.label().to_ascii_lowercase();
            if label.contains(want) {
                let t = c.temperature();
                if t.is_finite() && t > 0.0 {
                    return Some((c.label().to_string(), t));
                }
            }
        }
    }
    None
}

impl super::Collector for SystemCollector {
    fn id(&self) -> &'static str {
        "system"
    }

    fn title(&self) -> &'static str {
        "SITREP"
    }

    fn interval(&self) -> Duration {
        Duration::from_secs(1)
    }

    fn probe(&self) -> Availability {
        // Always available: /proc and sysinfo need no external binary.
        Availability::Present
    }

    fn collect(&mut self) -> anyhow::Result<Panel> {
        self.sys.refresh_memory();
        self.sys.refresh_cpu();
        self.components.refresh();

        let cores = self.sys.cpus().len();
        let load = System::load_average();
        let total = self.sys.total_memory();
        let used = self.sys.used_memory();

        let lh = load_health(load.one, cores);
        let mh = mem_health(used, total);

        let mut panel = Panel::new(Health::Unknown, String::new());

        panel = panel.row(
            "load",
            format!("{:.2} {:.2} {:.2} / {cores} cpu", load.one, load.five, load.fifteen),
            lh,
        );

        panel = if total > 0 {
            panel.row(
                "memory",
                format!(
                    "{} / {} ({:.0}%)",
                    fmt_gib(used),
                    fmt_gib(total),
                    used as f64 / total as f64 * 100.0
                ),
                mh,
            )
        } else {
            panel.row("memory", "--", Health::Unknown)
        };

        let th = match cpu_temp(&self.components) {
            Some((label, c)) => {
                let h = temp_health(c);
                panel = panel.row("cpu temp", format!("{c:.1} C ({label})"), h);
                h
            }
            None => {
                // No CPU package sensor is a missing optional field, not a
                // failure: degrade to "--"/Unknown and keep the pane alive.
                panel = panel.row("cpu temp", "--", Health::Unknown);
                Health::Unknown
            }
        };

        panel = panel.plain("uptime", fmt_uptime(System::uptime()));

        let persona = read_persona();
        panel = panel.plain("persona", persona.clone().unwrap_or_else(|| "--".into()));

        let profile = self.power_profile().map(str::to_string);
        panel = panel.plain("power", profile.clone().unwrap_or_else(|| "--".into()));

        panel = panel.plain(
            "kernel",
            self.kernel().map(str::to_string).unwrap_or_else(|| "--".into()),
        );

        // Only the three measurements we actually judged roll up. The
        // informational rows (persona, power, kernel, uptime) carry no
        // health and must not drag the card to Unknown.
        panel.health = Health::worst([lh, mh, th]);
        panel.summary = format!(
            "load {:.2} · mem {:.0}% · {} · {}",
            load.one,
            if total > 0 { used as f64 / total as f64 * 100.0 } else { 0.0 },
            persona.unwrap_or_else(|| "no persona".into()),
            profile.unwrap_or_else(|| "no ppd".into()),
        );

        Ok(panel)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn uptime_formats_by_magnitude() {
        assert_eq!(fmt_uptime(0), "0m");
        assert_eq!(fmt_uptime(59), "0m");
        assert_eq!(fmt_uptime(12 * 60), "12m");
        assert_eq!(fmt_uptime(4 * 3600 + 31 * 60), "4h 31m");
        assert_eq!(fmt_uptime(86_400 + 4 * 3600 + 31 * 60), "1d 4h 31m");
    }

    #[test]
    fn gib_is_binary_not_decimal() {
        assert_eq!(fmt_gib(1_073_741_824), "1.0 GiB");
        assert_eq!(fmt_gib(0), "0.0 GiB");
    }

    #[test]
    fn load_is_judged_per_core() {
        // 8.0 is healthy on 16 cores and fatal on 4.
        assert_eq!(load_health(8.0, 16), Health::Good);
        assert_eq!(load_health(8.0, 4), Health::Bad);
        assert_eq!(load_health(15.0, 16), Health::Warn);
        // No core count is not zero load — it is no answer.
        assert_eq!(load_health(1.0, 0), Health::Unknown);
    }

    #[test]
    fn memory_thresholds() {
        assert_eq!(mem_health(1, 100), Health::Good);
        assert_eq!(mem_health(85, 100), Health::Warn);
        assert_eq!(mem_health(95, 100), Health::Bad);
        // A total of zero means sysinfo told us nothing, never "0% used".
        assert_eq!(mem_health(0, 0), Health::Unknown);
    }

    #[test]
    fn a_missing_sensor_is_unknown_not_good() {
        assert_eq!(temp_health(0.0), Health::Unknown);
        assert_eq!(temp_health(f32::NAN), Health::Unknown);
        assert_eq!(temp_health(-1.0), Health::Unknown);
    }

    #[test]
    fn temps_are_judged_against_the_real_k10temp_range() {
        // Measured on this host: idle, just-after-build, mid-build.
        assert_eq!(temp_health(45.0), Health::Good);
        assert_eq!(temp_health(83.1), Health::Good);
        assert_eq!(temp_health(99.8), Health::Warn);
    }

    /// A single sample cannot tell boost from a cooling failure, so no
    /// temperature may ever be reported as `Bad`. If this starts failing,
    /// someone has added a threshold that makes a claim the data cannot back.
    #[test]
    fn no_instantaneous_temperature_is_ever_fatal() {
        for t in [50.0, 90.0, 95.0, 99.9, 105.0, 150.0f32] {
            assert_ne!(temp_health(t), Health::Bad, "{t}C reported Bad");
        }
    }
}
