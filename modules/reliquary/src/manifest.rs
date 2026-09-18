use std::path::Path;

use chrono::Utc;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::config::{CATALOG_SCHEMA, SCHEMA};
use crate::error::Result;

pub fn utcnow() -> String {
    Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string()
}

pub fn hostname() -> String {
    std::env::var("HOSTNAME")
        .or_else(|_| std::fs::read_to_string("/etc/hostname").map(|s| s.trim().to_string()))
        .unwrap_or_else(|_| "unknown".into())
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CopyRecord {
    pub medium: String,
    pub location: String,
    pub at: String,
}

pub fn write_json(path: &Path, value: &Value) -> Result<()> {
    let mut text = serde_json::to_string_pretty(value)?;
    text.push('\n');
    std::fs::write(path, text)?;
    Ok(())
}

pub fn read_json(path: &Path) -> Result<Value> {
    let raw = std::fs::read_to_string(path)?;
    Ok(serde_json::from_str(&raw)?)
}

pub fn new_block_manifest(
    block_id: &str,
    origin: &str,
    payload: Value,
    par2: Value,
    profile: &str,
    notes: &str,
) -> Value {
    serde_json::json!({
        "schema": SCHEMA,
        "id": block_id,
        "created": utcnow(),
        "source_host": hostname(),
        "origin": origin,
        "profile": profile,
        "notes": notes,
        "payload": payload,
        "par2": par2,
        "copies": []
    })
}

pub fn empty_catalog() -> Value {
    serde_json::json!({
        "schema": CATALOG_SCHEMA,
        "updated": utcnow(),
        "blocks": []
    })
}

pub fn record_copy(manifest: &mut Value, medium: &str, location: &str) {
    let rec = serde_json::json!({
        "medium": medium,
        "location": location,
        "at": utcnow(),
    });
    if let Some(arr) = manifest.get_mut("copies").and_then(|v| v.as_array_mut()) {
        arr.push(rec);
    } else {
        manifest["copies"] = serde_json::json!([rec]);
    }
}
