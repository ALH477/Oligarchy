//! Drives `nix build` and the selected container backend (`podman` by
//! default, `docker` per `runtime.backend`) as subprocesses. No FFI, no
//! daemon — shelling out is the deliberate Stage 0 choice (see
//! docs/oligarchy-forge-roadmap.md §Deferred: nix-bindings-rust).

use crate::schema::{Backend, ForgeConfig, NetworkMode, VolumeMode};
use anyhow::{bail, Context, Result};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

/// `$XDG_STATE_HOME/oligarchy-forge` (falls back to `$HOME/.local/state`) —
/// the root under which every project gets its own subdirectory.
pub fn state_root() -> Result<PathBuf> {
    let base = std::env::var_os("XDG_STATE_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".local/state")))
        .context("neither XDG_STATE_HOME nor HOME is set")?;
    Ok(base.join("oligarchy-forge"))
}

/// `<state_root>/<project>`, where the generated `flake.nix` (and a
/// persisted `oligarchy-forge.toml` snapshot — see `persist_config`) are
/// written. Kept out of the user's project repo — both are derived
/// artifacts, regenerated deterministically on every build.
pub fn state_dir(project_name: &str) -> Result<PathBuf> {
    Ok(state_root()?.join(project_name))
}

/// Every project subdirectory under `state_root()` that has been `build`-
/// invoked at least once. Used by the TUI's session list (`forge-tui`) to
/// discover known projects without depending on the caller's CWD.
pub fn known_project_dirs() -> Result<Vec<PathBuf>> {
    let root = state_root()?;
    if !root.exists() {
        return Ok(Vec::new());
    }
    let mut dirs: Vec<PathBuf> = std::fs::read_dir(&root)
        .with_context(|| format!("reading {}", root.display()))?
        .filter_map(|entry| entry.ok())
        .filter(|entry| entry.file_type().map(|t| t.is_dir()).unwrap_or(false))
        .map(|entry| entry.path())
        .collect();
    dirs.sort();
    Ok(dirs)
}

pub fn write_flake(dir: &Path, flake_nix: &str) -> Result<()> {
    std::fs::create_dir_all(dir).with_context(|| format!("creating state dir {}", dir.display()))?;
    std::fs::write(dir.join("flake.nix"), flake_nix)
        .with_context(|| format!("writing {}/flake.nix", dir.display()))
}

/// Snapshots the config that produced this project's `flake.nix`, so a
/// later `known_project_dirs()` scan (from any CWD) can reload it. Written
/// unconditionally on every `ensure_image` call — even a cache-hit build —
/// so the snapshot always reflects the most recently requested config.
pub fn persist_config(dir: &Path, cfg: &ForgeConfig) -> Result<()> {
    std::fs::create_dir_all(dir).with_context(|| format!("creating state dir {}", dir.display()))?;
    let toml_str = toml::to_string_pretty(cfg).context("serializing config for persistence")?;
    std::fs::write(dir.join("oligarchy-forge.toml"), toml_str)
        .with_context(|| format!("writing {}/oligarchy-forge.toml", dir.display()))
}

/// Writes `cfg` as pretty TOML to an exact file path — the TUI extension
/// picker's write-back target (`./oligarchy-forge.toml` in the project the
/// user is editing), as opposed to `persist_config`'s fixed-filename
/// snapshot under a state directory.
pub fn write_project_toml(path: &Path, cfg: &ForgeConfig) -> Result<()> {
    let toml_str = cfg.to_toml_string().context("serializing config")?;
    std::fs::write(path, toml_str).with_context(|| format!("writing {}", path.display()))
}

/// Loads `path` if it exists; otherwise bootstraps a fresh config named
/// after `project_name` (just the implicit `base` extension). Lets the
/// TUI's edit mode open a project directory that has no
/// `oligarchy-forge.toml` yet.
pub fn load_or_default_project_toml(path: &Path, project_name: &str) -> Result<ForgeConfig> {
    if path.exists() {
        let raw = std::fs::read_to_string(path).with_context(|| format!("reading {}", path.display()))?;
        ForgeConfig::parse(&raw)
    } else {
        ForgeConfig::parse(&format!("[project]\nname = \"{project_name}\"\n"))
    }
}

/// `nix build path:<dir>#default --no-link --print-out-paths`. Returns the
/// store path of the built `streamLayeredImage` script.
pub fn nix_build(dir: &Path) -> Result<PathBuf> {
    let flake_ref = format!("path:{}#default", dir.display());
    let output = Command::new("nix")
        .args(["build", &flake_ref, "--no-link", "--print-out-paths"])
        .output()
        .context("spawning `nix build` — is nix on PATH?")?;
    if !output.status.success() {
        bail!("nix build failed:\n{}", String::from_utf8_lossy(&output.stderr));
    }
    let out_path = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if out_path.is_empty() {
        bail!("nix build produced no output path");
    }
    Ok(PathBuf::from(out_path))
}

/// Streams the built image script into `<backend> load`.
pub fn container_load(backend: Backend, image_script: &Path) -> Result<()> {
    let mut script = Command::new(image_script)
        .stdout(Stdio::piped())
        .spawn()
        .with_context(|| format!("running image stream script {}", image_script.display()))?;
    let stdout = script.stdout.take().context("capturing image stream stdout")?;

    let bin = backend.binary();
    let status = Command::new(bin)
        .arg("load")
        .stdin(Stdio::from(stdout))
        .status()
        .with_context(|| format!("spawning `{bin} load` — is {bin} on PATH?"))?;

    let stream_status = script.wait().context("waiting on image stream script")?;
    if !stream_status.success() {
        bail!("image stream script failed");
    }
    if !status.success() {
        bail!("{bin} load failed");
    }
    Ok(())
}

/// Podman has a dedicated `image exists` subcommand; Docker doesn't — the
/// equivalent there is a quiet `image inspect` (exit 0 iff the image is
/// present). Public: the TUI's session list uses this to show built/not-built
/// per project without triggering a build.
pub fn image_exists(cfg: &ForgeConfig) -> Result<bool> {
    let bin = cfg.runtime.backend.binary();
    let image_ref = format!("{}:latest", cfg.image_name());
    let check_args: &[&str] = match cfg.runtime.backend {
        Backend::Podman => &["image", "exists", &image_ref],
        Backend::Docker => &["image", "inspect", &image_ref],
    };
    let status = Command::new(bin)
        .args(check_args)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .with_context(|| format!("spawning `{bin} image inspect/exists` — is {bin} on PATH?"))?;
    Ok(status.success())
}

/// Builds (rendering + `nix build` + `<backend> load`) unless the image
/// already exists and `rebuild` is false. Always persists the config
/// snapshot first, even on a cache-hit short-circuit.
pub fn ensure_image(cfg: &ForgeConfig, rebuild: bool) -> Result<()> {
    let dir = state_dir(&cfg.project.name)?;
    persist_config(&dir, cfg)?;

    if !rebuild && image_exists(cfg)? {
        return Ok(());
    }
    let flake_nix = crate::render::render_flake(cfg)?;
    write_flake(&dir, &flake_nix)?;
    let image_script = nix_build(&dir)?;
    container_load(cfg.runtime.backend, &image_script)
}

/// `<backend> run` with PWD mounted to `/workspace`, a per-project home
/// volume (named or ephemeral per `runtime.volume_mode`), interactive stdio
/// passthrough, and the sandbox posture from `runtime.sandbox` — locked down
/// by default: read-only rootfs, strict seccomp, no network, cgroup limits.
/// Every hardening flag is a per-project opt-OUT in `oligarchy-forge.toml`,
/// so the relaxed shape is visible in the config rather than hidden in a
/// default nobody reads. `--cap-drop=ALL` and `--security-opt
/// no-new-privileges` are NOT configurable: they are the base tier, not a
/// dial.
pub fn container_run(cfg: &ForgeConfig, cmd: &[String]) -> Result<i32> {
    let cwd = std::env::current_dir().context("resolving current directory")?;
    let args = run_argv(cfg, &cwd, cmd);

    let bin = cfg.runtime.backend.binary();
    let status = Command::new(bin)
        .args(&args)
        .status()
        .with_context(|| format!("spawning `{bin} run` — is {bin} on PATH?"))?;
    Ok(status.code().unwrap_or(1))
}

/// The strict seccomp profile shipped with the image, referenced by
/// `run_argv` as `seccomp=seccomp_strict.json` (podman/docker resolve a
/// bare filename against the image's working directory — the generated image
/// places this file at its root). Default-deny on the kernel attack surface
/// a coding-agent sandbox has no business touching: mount, ptrace, kexec,
/// module loading, and the perf/open perf events. Everything else is
/// allowed so ordinary toolchains (rustc, cargo, node, python) keep working.
pub const SECCOMP_STRICT_JSON: &str = include_str!("seccomp_strict.json");

/// Renders the argv `container_run` would pass to `<backend> run`, without
/// spawning anything. Public so the CLI can show the effective posture, and
/// so tests can assert on the flags directly.
pub fn run_argv(cfg: &ForgeConfig, cwd: &Path, cmd: &[String]) -> Vec<String> {
    let backend = cfg.runtime.backend;
    let sb = &cfg.runtime.sandbox;

    let mut args: Vec<String> = vec!["run".into(), "--rm".into(), "-it".into()];
    args.push(format!("--volume={}:/workspace", cwd.display()));
    args.push("--workdir=/workspace".into());

    match cfg.runtime.volume_mode {
        VolumeMode::Named => {
            args.push(format!("--volume={}:/home/agent", cfg.volume_name()));
        }
        VolumeMode::Ephemeral => {
            // Anonymous volume — dropped with the container on --rm.
            args.push("--volume=/home/agent".into());
        }
    }

    // The base tier — not configurable.
    args.push("--cap-drop=ALL".into());
    args.push("--security-opt=no-new-privileges".into());
    if backend == Backend::Podman {
        // Rootless-podman-specific: maps the container's root to the
        // invoking host user instead of a subuid range, so bind-mounted
        // /workspace files come out owned by the caller. No Docker
        // equivalent flag; rootless Docker handles this via its own
        // daemon-wide subuid remap instead.
        args.push("--userns=keep-id".into());
    }

    // The per-project sandbox posture (defaults: all hard).
    if sb.read_only_rootfs {
        args.push("--read-only".into());
        // A read-only rootfs leaves nowhere for /tmp scratch or for tools
        // that insist on writing under /var; tmpfs mounts cover both
        // without making the image itself writable.
        args.push("--tmpfs=/tmp".into());
        args.push("--tmpfs=/var/tmp".into());
    }
    if sb.seccomp {
        args.push("--security-opt=seccomp=seccomp_strict.json".into());
    }
    match sb.network {
        NetworkMode::None => args.push("--network=none".into()),
        NetworkMode::Host => args.push("--network=host".into()),
    }
    if sb.memory_mib > 0 {
        args.push(format!("--memory={}m", sb.memory_mib));
    }
    if sb.cpu_percent > 0 {
        args.push(format!("--cpu-quota={}", sb.cpu_percent * 10_000));
    }
    if sb.pids_limit > 0 {
        args.push(format!("--pids-limit={}", sb.pids_limit));
    }

    args.push(format!("{}:latest", cfg.image_name()));
    if cmd.is_empty() {
        args.push("/bin/bash".into());
    } else {
        args.extend(cmd.iter().cloned());
    }
    args
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::schema::{Extension, NetworkMode, Sandbox};

    fn demo_cfg(toml: &str) -> ForgeConfig {
        ForgeConfig::parse(toml).unwrap()
    }

    const DEMO_TOML: &str = r#"
        [project]
        name = "demo"
    "#;

    #[test]
    fn sandbox_defaults_to_locked_down() {
        // No [runtime.sandbox] table at all: the posture must be the strict
        // one — read-only rootfs, seccomp, no network, cgroup limits. A
        // missing table meaning "relaxed" would invert the whole point.
        let cfg = demo_cfg(DEMO_TOML);
        assert!(cfg.runtime.sandbox.read_only_rootfs);
        assert!(cfg.runtime.sandbox.seccomp);
        assert_eq!(cfg.runtime.sandbox.network, NetworkMode::None);
        assert!(cfg.runtime.sandbox.memory_mib > 0);
        assert!(cfg.runtime.sandbox.cpu_percent > 0);
        assert!(cfg.runtime.sandbox.pids_limit > 0);
    }

    #[test]
    fn run_argv_locked_down_by_default() {
        let cfg = demo_cfg(DEMO_TOML);
        let argv = run_argv(&cfg, Path::new("/tmp/proj"), &[]);
        let joined = argv.join(" ");
        // The base tier is not a dial: always present.
        assert!(argv.contains(&"--cap-drop=ALL".to_string()), "{joined}");
        assert!(argv.contains(&"--security-opt=no-new-privileges".to_string()), "{joined}");
        // The locked-down posture.
        assert!(argv.contains(&"--read-only".to_string()), "{joined}");
        assert!(argv.contains(&"--security-opt=seccomp=seccomp_strict.json".to_string()), "{joined}");
        assert!(argv.contains(&"--network=none".to_string()), "{joined}");
        assert!(argv.iter().any(|a| a.starts_with("--memory=")), "{joined}");
        assert!(argv.iter().any(|a| a.starts_with("--cpu-quota=")), "{joined}");
        assert!(argv.iter().any(|a| a.starts_with("--pids-limit=")), "{joined}");
        // The workspace mount and image ref are still there.
        assert!(argv.iter().any(|a| a.starts_with("--volume=/tmp/proj:/workspace")), "{joined}");
        assert!(argv.contains(&"oligarchy-forge/demo:latest".to_string()), "{joined}");
    }

    #[test]
    fn run_argv_opt_out_drops_exactly_that_flag() {
        // A project that opts out of everything relaxed gets the historical
        // shape back: no --read-only, no seccomp, host network, no limits —
        // but --cap-drop=ALL and no-new-privileges stay, because those are
        // the base tier, not a dial.
        let cfg = demo_cfg(
            r#"
            [project]
            name = "demo"
            [runtime.sandbox]
            read-only-rootfs = false
            seccomp = false
            network = "host"
            memory-mib = 0
            cpu-percent = 0
            pids-limit = 0
            "#,
        );
        let argv = run_argv(&cfg, Path::new("/tmp/proj"), &[]);
        let joined = argv.join(" ");
        assert!(!argv.contains(&"--read-only".to_string()), "{joined}");
        assert!(!argv.iter().any(|a| a.starts_with("--security-opt=seccomp=")), "{joined}");
        assert!(argv.contains(&"--network=host".to_string()), "{joined}");
        assert!(!argv.iter().any(|a| a.starts_with("--memory=")), "{joined}");
        assert!(!argv.iter().any(|a| a.starts_with("--cpu-quota=")), "{joined}");
        assert!(!argv.iter().any(|a| a.starts_with("--pids-limit=")), "{joined}");
        // Base tier survives every opt-out.
        assert!(argv.contains(&"--cap-drop=ALL".to_string()), "{joined}");
        assert!(argv.contains(&"--security-opt=no-new-privileges".to_string()), "{joined}");
    }

    #[test]
    fn run_argv_partial_opt_out_keeps_the_rest() {
        // Opting out of the network restriction alone must not silently
        // drop the read-only rootfs or the seccomp profile.
        let cfg = demo_cfg(
            r#"
            [project]
            name = "demo"
            [runtime.sandbox]
            network = "host"
            "#,
        );
        let argv = run_argv(&cfg, Path::new("/tmp/proj"), &[]);
        let joined = argv.join(" ");
        assert!(argv.contains(&"--network=host".to_string()), "{joined}");
        assert!(argv.contains(&"--read-only".to_string()), "{joined}");
        assert!(argv.contains(&"--security-opt=seccomp=seccomp_strict.json".to_string()), "{joined}");
    }

    #[test]
    fn seccomp_profile_is_valid_json_and_denies_mount() {
        let v: serde_json::Value = serde_json::from_str(SECCOMP_STRICT_JSON).unwrap();
        assert_eq!(v["defaultAction"], "SCMP_ACT_ALLOW");
        let names = v["syscalls"][0]["names"].as_array().unwrap();
        let names: Vec<&str> = names.iter().map(|n| n.as_str().unwrap()).collect();
        for required in ["mount", "ptrace", "kexec_load", "init_module", "perf_event_open"] {
            assert!(names.contains(&required), "seccomp profile missing {required}");
        }
        assert_eq!(v["syscalls"][0]["action"], "SCMP_ACT_ERRNO");
    }

    #[test]
    fn sandbox_toml_round_trips() {
        let cfg = demo_cfg(
            r#"
            [project]
            name = "demo"
            [runtime.sandbox]
            read-only-rootfs = false
            network = "host"
            memory-mib = 8192
            "#,
        );
        let rendered = cfg.to_toml_string().unwrap();
        let reloaded = ForgeConfig::parse(&rendered).unwrap();
        assert!(!reloaded.runtime.sandbox.read_only_rootfs);
        assert_eq!(reloaded.runtime.sandbox.network, NetworkMode::Host);
        assert_eq!(reloaded.runtime.sandbox.memory_mib, 8192);
        // Untouched fields keep their strict defaults through the round trip.
        assert!(reloaded.runtime.sandbox.seccomp);
    }

    #[test]
    fn sandbox_strict_is_the_default() {
        let sb = Sandbox::default();
        assert!(sb.read_only_rootfs);
        assert!(sb.seccomp);
        assert_eq!(sb.network, NetworkMode::None);
    }

    #[test]
    fn persist_config_round_trips_via_toml() {
        let dir = std::env::temp_dir().join(format!(
            "oligarchy-forge-core-test-{}-{}",
            std::process::id(),
            "persist-config-round-trip"
        ));
        let cfg = ForgeConfig::parse(
            r#"
            [project]
            name = "roundtrip"
            extensions = ["python"]
            "#,
        )
        .unwrap();

        persist_config(&dir, &cfg).unwrap();
        let raw = std::fs::read_to_string(dir.join("oligarchy-forge.toml")).unwrap();
        let reloaded = ForgeConfig::parse(&raw).unwrap();

        assert_eq!(reloaded.project.name, "roundtrip");
        assert!(reloaded.project.extensions.contains(&Extension::Python));
        assert!(reloaded.project.extensions.contains(&Extension::Base));

        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn load_or_default_project_toml_bootstraps_when_missing() {
        let dir = std::env::temp_dir().join(format!(
            "oligarchy-forge-core-test-{}-{}",
            std::process::id(),
            "load-or-default"
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("oligarchy-forge.toml");

        let cfg = load_or_default_project_toml(&path, "fresh-project").unwrap();
        assert_eq!(cfg.project.name, "fresh-project");
        assert_eq!(cfg.project.extensions, vec![Extension::Base]);
        assert!(!path.exists(), "load_or_default must not write anything itself");

        write_project_toml(&path, &cfg).unwrap();
        let reloaded = load_or_default_project_toml(&path, "ignored-when-file-exists").unwrap();
        assert_eq!(reloaded.project.name, "fresh-project");

        std::fs::remove_dir_all(&dir).ok();
    }
}
