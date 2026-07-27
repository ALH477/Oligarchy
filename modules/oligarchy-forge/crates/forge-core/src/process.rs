//! Drives `nix build` and the selected container backend (`podman` by
//! default, `docker` per `runtime.backend`) as subprocesses. No FFI, no
//! daemon — shelling out is the deliberate Stage 0 choice (see
//! docs/oligarchy-forge-roadmap.md §Deferred: nix-bindings-rust).

use crate::schema::{Backend, ForgeConfig, VolumeMode};
use anyhow::{bail, Context, Result};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

/// `$XDG_STATE_HOME/oligarchy-forge/<project>` (falls back to
/// `$HOME/.local/state`), where the generated `flake.nix` is written. Kept
/// out of the user's project repo — it's a derived artifact, regenerated
/// deterministically from `oligarchy-forge.toml` on every build.
pub fn state_dir(project_name: &str) -> Result<PathBuf> {
    let base = std::env::var_os("XDG_STATE_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".local/state")))
        .context("neither XDG_STATE_HOME nor HOME is set")?;
    Ok(base.join("oligarchy-forge").join(project_name))
}

pub fn write_flake(dir: &Path, flake_nix: &str) -> Result<()> {
    std::fs::create_dir_all(dir).with_context(|| format!("creating state dir {}", dir.display()))?;
    std::fs::write(dir.join("flake.nix"), flake_nix)
        .with_context(|| format!("writing {}/flake.nix", dir.display()))
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
/// present).
fn image_ready(cfg: &ForgeConfig) -> Result<bool> {
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
/// already exists and `rebuild` is false.
pub fn ensure_image(cfg: &ForgeConfig, rebuild: bool) -> Result<()> {
    if !rebuild && image_ready(cfg)? {
        return Ok(());
    }
    let dir = state_dir(&cfg.project.name)?;
    let flake_nix = crate::render::render_flake(cfg)?;
    write_flake(&dir, &flake_nix)?;
    let image_script = nix_build(&dir)?;
    container_load(cfg.runtime.backend, &image_script)
}

/// `<backend> run` with PWD mounted to `/workspace`, a per-project home
/// volume (named or ephemeral per `runtime.volume_mode`), interactive stdio
/// passthrough, and the safe-by-default flags Stage 3's tier switcher will
/// later make configurable (cap-drop, no-new-privileges, rootless UID map).
pub fn container_run(cfg: &ForgeConfig, cmd: &[String]) -> Result<i32> {
    let cwd = std::env::current_dir().context("resolving current directory")?;
    let backend = cfg.runtime.backend;

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

    args.push(format!("{}:latest", cfg.image_name()));
    if cmd.is_empty() {
        args.push("/bin/bash".into());
    } else {
        args.extend(cmd.iter().cloned());
    }

    let bin = backend.binary();
    let status = Command::new(bin)
        .args(&args)
        .status()
        .with_context(|| format!("spawning `{bin} run` — is {bin} on PATH?"))?;
    Ok(status.code().unwrap_or(1))
}
