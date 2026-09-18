use std::path::{Path, PathBuf};

use serde_json::{json, Value};

use crate::config::Config;
use crate::error::{Error, Result};
use crate::store::Store;
use crate::util::{require_tool, run};

pub fn make_iso(cfg: &Config, store: &Store, block_id: &str) -> Result<PathBuf> {
    // Must be the first thing that happens: block_id is joined onto BOTH the
    // store root (block_dir) and the ISO root, and the ISO path is removed if
    // it already exists. Without this, `../..`-style ids make an ISO of an
    // arbitrary directory and silently delete an arbitrary existing file.
    crate::store::validate_block_id(block_id)?;
    let block = store.block_dir(block_id);
    if !block.exists() {
        return Err(Error::UnknownBlock(block_id.into()));
    }
    let volid: String = format!("RLQ{}", block_id.replace('-', ""))
        .chars()
        .take(32)
        .collect();
    let iso = cfg.iso_root().join(format!("{block_id}.iso"));
    std::fs::create_dir_all(cfg.iso_root())?;
    if iso.exists() {
        std::fs::remove_file(&iso)?;
    }
    let xorriso = require_tool("xorriso")?;
    run(
        &[
            &xorriso,
            "-as",
            "mkisofs",
            "-R",
            "-J",
            "-V",
            &volid,
            "-o",
            &iso.to_string_lossy(),
            &block.to_string_lossy(),
        ],
        None,
    )?;
    let size = iso.metadata()?.len();
    if size > cfg.cd_capacity_bytes {
        let _ = std::fs::remove_file(&iso);
        return Err(Error::store(format!(
            "ISO is {size} bytes, larger than an 80-minute CD-R ({}). Use profile=usb or split the source.",
            cfg.cd_capacity_bytes
        )));
    }
    Ok(iso)
}

pub fn burn_iso(iso: &Path, device: &Path, dummy: bool) -> Result<Value> {
    // The iso argument is appended as a bare positional to a cdrecord-emulation
    // command line, and cdrecord's grammar reads `word=value` arguments as
    // options -- `blank=all` would blank the disc instead of naming a file, and
    // a leading `-` is read as a flag. xorriso's `-as cdrecord` emulation is not
    // documented to honour a `--` end-of-options separator, so instead pin the
    // argument into a shape that grammar cannot misread: an existing regular
    // file, canonicalised to an absolute path (always starts with `/`, so it
    // matches neither a flag nor an option keyword).
    let iso_str = iso.to_string_lossy();
    if iso_str.starts_with('-') {
        return Err(Error::store(format!(
            "refusing iso path {iso_str:?}: a leading '-' is parsed as a cdrecord flag"
        )));
    }
    let iso = iso
        .canonicalize()
        .map_err(|_| Error::MissingSource(iso.to_path_buf()))?;
    if !iso.is_file() {
        return Err(Error::store(format!(
            "refusing to burn {}: not a regular file",
            iso.display()
        )));
    }
    // canonicalize() yields an absolute path, but assert it rather than assume:
    // this is the property that makes the positional un-misparseable.
    if !iso.is_absolute() {
        return Err(Error::store(format!(
            "refusing iso path {}: not absolute after canonicalisation",
            iso.display()
        )));
    }
    let xorriso = require_tool("xorriso")?;
    let mut args = vec![
        xorriso.clone(),
        "-as".into(),
        "cdrecord".into(),
        format!("dev={}", device.display()),
        "-v".into(),
    ];
    if dummy {
        args.push("-dummy".into());
    }
    args.push(iso.display().to_string());
    let refs: Vec<&str> = args.iter().map(|s| s.as_str()).collect();
    let out = run(&refs, None)?;
    Ok(json!({
        "ok": true,
        "device": device.display().to_string(),
        "iso": iso.display().to_string(),
        "log": String::from_utf8_lossy(&out.stdout),
    }))
}

pub fn iso_info(iso: &Path) -> Value {
    json!({
        "path": iso.display().to_string(),
        "bytes": iso.metadata().map(|m| m.len()).unwrap_or(0),
        "exists": iso.exists(),
    })
}
