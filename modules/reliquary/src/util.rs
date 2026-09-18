use std::io::Write;
use std::path::Path;
use std::process::{Command, Output, Stdio};

use crate::error::{Error, Result};

pub fn require_tool(name: &'static str) -> Result<String> {
    if let Ok(path) = which(name) {
        return Ok(path);
    }
    Err(Error::MissingTool(name))
}

fn which(name: &str) -> std::result::Result<String, ()> {
    if let Ok(paths) = std::env::var("PATH") {
        for dir in paths.split(':') {
            let candidate = Path::new(dir).join(name);
            if candidate.is_file() {
                use std::os::unix::fs::PermissionsExt;
                if candidate.metadata().map(|m| m.permissions().mode() & 0o111 != 0).unwrap_or(false) {
                    return Ok(candidate.to_string_lossy().into_owned());
                }
            }
        }
    }
    Err(())
}

pub fn run(args: &[&str], cwd: Option<&Path>) -> Result<Output> {
    let mut cmd = Command::new(args[0]);
    cmd.args(&args[1..]).stdout(Stdio::piped()).stderr(Stdio::piped());
    if let Some(dir) = cwd {
        cmd.current_dir(dir);
    }
    let out = cmd.output()?;
    if !out.status.success() {
        return Err(Error::Command {
            cmd: args.join(" "),
            code: out.status.code().unwrap_or(1),
            stderr: String::from_utf8_lossy(&out.stderr).trim().to_string(),
        });
    }
    Ok(out)
}

pub fn run_unchecked(args: &[&str], cwd: Option<&Path>) -> Result<Output> {
    let mut cmd = Command::new(args[0]);
    cmd.args(&args[1..]).stdout(Stdio::piped()).stderr(Stdio::piped());
    if let Some(dir) = cwd {
        cmd.current_dir(dir);
    }
    Ok(cmd.output()?)
}

pub fn pipe_tar_zstd(tar_args: &[&str], zstd_args: &[&str], dest: &Path) -> Result<()> {
    let mut tar = Command::new(&tar_args[0])
        .args(&tar_args[1..])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?;
    let tar_stdout = tar.stdout.take().ok_or_else(|| Error::store("tar produced no stdout"))?;
    let mut zstd = Command::new(&zstd_args[0])
        .args(&zstd_args[1..])
        .stdin(Stdio::from(tar_stdout))
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?;
    let zstd_out = zstd.wait_with_output()?;
    let tar_status = tar.wait()?;
    if !tar_status.success() || !zstd_out.status.success() {
        let mut err = String::from_utf8_lossy(&zstd_out.stderr).into_owned();
        err.push_str(&format!(
            " tar={} zstd={}",
            tar_status.code().unwrap_or(-1),
            zstd_out.status.code().unwrap_or(-1)
        ));
        return Err(Error::store(err));
    }
    if let Some(parent) = dest.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let mut f = std::fs::File::create(dest)?;
    f.write_all(&zstd_out.stdout)?;
    Ok(())
}

pub fn copy_dir_all(src: &Path, dst: &Path) -> Result<()> {
    std::fs::create_dir_all(dst)?;
    for entry in walkdir::WalkDir::new(src) {
        let entry = entry.map_err(|e| Error::store(e.to_string()))?;
        let rel = entry.path().strip_prefix(src).unwrap();
        let target = dst.join(rel);
        if entry.file_type().is_dir() {
            std::fs::create_dir_all(&target)?;
        } else if entry.file_type().is_file() {
            if let Some(p) = target.parent() {
                std::fs::create_dir_all(p)?;
            }
            std::fs::copy(entry.path(), &target)?;
        }
    }
    Ok(())
}

pub fn remove_dir_if_exists(path: &Path) -> Result<()> {
    if path.exists() {
        std::fs::remove_dir_all(path)?;
    }
    Ok(())
}
