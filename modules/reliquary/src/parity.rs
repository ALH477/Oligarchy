use std::path::{Path, PathBuf};

use serde::Serialize;

use crate::error::Result;
use crate::util::{require_tool, run, run_unchecked};

#[derive(Debug, Clone, Serialize)]
pub struct Par2Info {
    pub redundancy_percent: u8,
    pub volumes: u8,
    pub index: Option<String>,
    pub files: Vec<String>,
    pub recovery_files: Vec<String>,
    pub bytes: u64,
}

#[derive(Debug, Clone, Serialize)]
pub struct Par2Result {
    pub ok: bool,
    pub returncode: i32,
    pub output: String,
}

pub fn create_par2(target: &Path, redundancy: u8, volumes: u8) -> Result<Par2Info> {
    let par2 = require_tool("par2")?;
    let parent = target.parent().unwrap_or_else(|| Path::new("."));
    let r = format!("-r{redundancy}");
    let n = format!("-n{volumes}");
    run(
        &[&par2, "create", &r, &n, "-u", "-q", &target.to_string_lossy()],
        Some(parent),
    )?;
    let name = target.file_name().unwrap().to_string_lossy();
    let mut siblings = Vec::new();
    let mut extra = Vec::new();
    let mut bytes = 0u64;
    if let Ok(rd) = std::fs::read_dir(parent) {
        for e in rd.flatten() {
            let fname = e.file_name().to_string_lossy().into_owned();
            if fname.starts_with(&*name) && fname.ends_with(".par2") {
                bytes += e.metadata().map(|m| m.len()).unwrap_or(0);
                if fname.contains(".vol") {
                    extra.push(fname.clone());
                }
                siblings.push(fname);
            }
        }
    }
    siblings.sort();
    extra.sort();
    let index = parent.join(format!("{name}.par2"));
    Ok(Par2Info {
        redundancy_percent: redundancy,
        volumes,
        index: if index.exists() {
            Some(format!("{name}.par2"))
        } else {
            siblings.first().cloned()
        },
        files: siblings,
        recovery_files: extra,
        bytes,
    })
}

pub fn verify_par2(index: &Path) -> Result<Par2Result> {
    invoke(index, "verify")
}

pub fn repair_par2(index: &Path) -> Result<Par2Result> {
    invoke(index, "repair")
}

fn invoke(index: &Path, verb: &str) -> Result<Par2Result> {
    let par2 = require_tool("par2")?;
    let parent = index.parent().unwrap_or_else(|| Path::new("."));
    let out = run_unchecked(&[&par2, verb, "-q", &index.to_string_lossy()], Some(parent))?;
    let mut text = String::from_utf8_lossy(&out.stdout).into_owned();
    text.push_str(&String::from_utf8_lossy(&out.stderr));
    Ok(Par2Result {
        ok: out.status.success(),
        returncode: out.status.code().unwrap_or(1),
        output: text,
    })
}

#[allow(dead_code)]
pub fn index_for(payload: &Path) -> PathBuf {
    let mut s = payload.as_os_str().to_os_string();
    s.push(".par2");
    PathBuf::from(s)
}
