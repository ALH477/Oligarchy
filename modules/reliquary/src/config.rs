use std::env;
use std::path::{Path, PathBuf};

pub const VERSION: &str = env!("CARGO_PKG_VERSION");
pub const SCHEMA: &str = "reliquary.block/v1";
pub const CATALOG_SCHEMA: &str = "reliquary.catalog/v1";

/// 80-minute CD-R: 80 * 60 * 75 * 2048 bytes
pub const CD_R_80_BYTES: u64 = 80 * 60 * 75 * 2048;
pub const DEFAULT_CD_PAYLOAD_BYTES: u64 = 520 * 1024 * 1024;
pub const USB_META_MIB: u64 = 2048;
pub const WIPE_PHRASE: &str = "WIPE-THIS-USB";

#[derive(Debug, Clone)]
pub struct UsbRole {
    pub role: &'static str,
    pub meta_label: &'static str,
    pub data_label: &'static str,
    pub disk_label: &'static str,
}

impl UsbRole {
    pub fn a() -> Self {
        Self {
            role: "A",
            meta_label: "RLQ-META-A",
            data_label: "RLQ-DATA-A",
            disk_label: "RELIQUARY-A",
        }
    }

    pub fn b() -> Self {
        Self {
            role: "B",
            meta_label: "RLQ-META-B",
            data_label: "RLQ-DATA-B",
            disk_label: "RELIQUARY-B",
        }
    }
}

#[derive(Debug, Clone)]
pub struct Config {
    pub store_root: PathBuf,
    pub work_root: PathBuf,
    pub par2_redundancy: u8,
    pub par2_volumes: u8,
    pub zstd_level: u8,
    pub cd_capacity_bytes: u64,
    pub cd_payload_bytes: u64,
    pub usb_a: UsbRole,
    pub usb_b: UsbRole,
}

impl Config {
    pub fn load() -> Self {
        let store_root = default_store_root();
        let work_root = env::var("RELIQUARY_WORK")
            .map(PathBuf::from)
            .unwrap_or_else(|_| store_root.join("work"));
        let par2_redundancy = env::var("RELIQUARY_PAR2_REDUNDANCY")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(20);
        let cfg = Self {
            store_root,
            work_root,
            par2_redundancy,
            par2_volumes: 4,
            zstd_level: 19,
            cd_capacity_bytes: CD_R_80_BYTES,
            cd_payload_bytes: DEFAULT_CD_PAYLOAD_BYTES,
            usb_a: UsbRole::a(),
            usb_b: UsbRole::b(),
        };
        cfg.ensure_dirs();
        cfg
    }

    pub fn staging(&self) -> PathBuf {
        self.store_root.join("staging")
    }

    pub fn blocks(&self) -> PathBuf {
        self.store_root.join("blocks")
    }

    pub fn catalog_path(&self) -> PathBuf {
        self.store_root.join("catalog.json")
    }

    pub fn iso_root(&self) -> PathBuf {
        self.store_root.join("iso")
    }

    pub fn ensure_dirs(&self) {
        for p in [
            &self.store_root,
            &self.work_root,
            &self.staging(),
            &self.blocks(),
            &self.iso_root(),
        ] {
            let _ = std::fs::create_dir_all(p);
        }
    }

    pub fn role(&self, name: &str) -> &UsbRole {
        if name.eq_ignore_ascii_case("B") {
            &self.usb_b
        } else {
            &self.usb_a
        }
    }
}

pub fn default_store_root() -> PathBuf {
    if let Ok(env) = env::var("RELIQUARY_STORE") {
        return PathBuf::from(env);
    }
    if let Ok(xdg) = env::var("XDG_DATA_HOME") {
        return Path::new(&xdg).join("reliquary");
    }
    dirs_home().join(".local/share/reliquary")
}

fn dirs_home() -> PathBuf {
    env::var("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("."))
}
