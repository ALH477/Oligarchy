use std::path::PathBuf;

use clap::{Parser, Subcommand};
use serde_json::Value;

use crate::config::{Config, VERSION, WIPE_PHRASE};
use crate::optical;
use crate::store::Store;
use crate::usb;

#[derive(Parser)]
#[command(
    name = "reliquary",
    version = VERSION,
    about = "Preserve a tree onto duplicated USB partitions and CD-R data blocks."
)]
pub struct Cli {
    #[command(subcommand)]
    pub cmd: Cmd,
}

#[derive(Subcommand)]
pub enum Cmd {
    /// Local store + USB presence
    Status,
    /// Pack a path into a verified preservation block
    Ingest {
        path: PathBuf,
        #[arg(long, default_value = "cd", value_parser = ["cd", "usb"])]
        profile: String,
        #[arg(long, default_value = "")]
        notes: String,
        #[arg(long)]
        force: bool,
    },
    /// List blocks in the local store
    List,
    /// Print one block manifest
    Show { block_id: String },
    /// Checksum + PAR2 verify a block
    Verify {
        block_id: String,
        #[arg(long)]
        repair: bool,
    },
    /// Unpack a block after verifying it
    Extract {
        block_id: String,
        dest: PathBuf,
        #[arg(long)]
        no_verify: bool,
    },
    /// Copy a block onto mounted USB data partitions
    Push {
        block_id: String,
        #[arg(long, default_value = "AB")]
        roles: String,
    },
    /// Copy a block off a mounted USB into the local store
    Pull {
        block_id: String,
        #[arg(long, default_value = "A", value_parser = ["A", "B"])]
        role: String,
    },
    /// Build a CD-R ISO of one block
    Iso { block_id: String },
    /// Burn an ISO to a CD writer
    Burn {
        iso: PathBuf,
        device: PathBuf,
        #[arg(long, help = "laser off rehearsal")]
        dummy: bool,
    },
    /// USB layout helpers
    Usb {
        #[command(subcommand)]
        cmd: UsbCmd,
    },
    /// Interactive preservation console
    Tui,
    /// Model Context Protocol server (stdio)
    Mcp,
}

#[derive(Subcommand)]
pub enum UsbCmd {
    Status,
    /// GPT + FAT32 META + ext4 DATA (DESTROYS THE DISK)
    Format {
        device: PathBuf,
        #[arg(long, value_parser = ["A", "B"])]
        role: String,
        #[arg(long)]
        confirm: String,
    },
    /// Write catalog + README onto mounted META partitions
    Seed,
}

pub fn run() -> anyhow::Result<()> {
    let cli = Cli::parse();
    match cli.cmd {
        Cmd::Tui => crate::tui::run(),
        Cmd::Mcp => crate::mcp::run_stdio(),
        other => {
            let code = dispatch(other)?;
            if code != 0 {
                std::process::exit(code);
            }
            Ok(())
        }
    }
}

fn dispatch(cmd: Cmd) -> anyhow::Result<i32> {
    let cfg = Config::load();
    let store = Store::new(cfg.clone())?;
    match cmd {
        Cmd::Status => {
            emit(&serde_json::json!({
                "version": VERSION,
                "store_root": cfg.store_root.display().to_string(),
                "blocks": store.list_blocks()?.len(),
                "usb": usb::volume_status(&cfg)?,
            }));
            Ok(0)
        }
        Cmd::Ingest {
            path,
            profile,
            notes,
            force,
        } => {
            emit(&store.ingest(&path, &profile, &notes, force)?);
            Ok(0)
        }
        Cmd::List => {
            let rows: Vec<Value> = store
                .list_blocks()?
                .into_iter()
                .map(|m| {
                    serde_json::json!({
                        "id": m.get("id"),
                        "created": m.get("created"),
                        "profile": m.get("profile"),
                        "bytes": m.get("payload").and_then(|p| p.get("bytes")),
                        "origin": m.get("origin"),
                        "copies": m.get("copies").and_then(|c| c.as_array()).map(|a| a.len()).unwrap_or(0),
                    })
                })
                .collect();
            emit(&Value::Array(rows));
            Ok(0)
        }
        Cmd::Show { block_id } => {
            emit(&store.load_manifest(&block_id)?);
            Ok(0)
        }
        Cmd::Verify { block_id, repair } => {
            let result = store.verify(&block_id, repair)?;
            let rc = if result["ok"].as_bool() == Some(true) {
                0
            } else {
                2
            };
            emit(&result);
            Ok(rc)
        }
        Cmd::Extract {
            block_id,
            dest,
            no_verify,
        } => {
            let dest = store.extract(&block_id, &dest, !no_verify)?;
            emit(&serde_json::json!({"extracted_to": dest.display().to_string()}));
            Ok(0)
        }
        Cmd::Push { block_id, roles } => {
            emit(&usb::push_block(&cfg, &store, &block_id, &roles)?);
            Ok(0)
        }
        Cmd::Pull { block_id, role } => {
            let dest = usb::pull_block(&cfg, &store, &block_id, &role)?;
            emit(&serde_json::json!({"pulled_to": dest.display().to_string()}));
            Ok(0)
        }
        Cmd::Iso { block_id } => {
            crate::store::validate_block_id(&block_id)?;
            let iso = optical::make_iso(&cfg, &store, &block_id)?;
            emit(&optical::iso_info(&iso));
            Ok(0)
        }
        Cmd::Burn { iso, device, dummy } => {
            emit(&optical::burn_iso(&iso, &device, dummy)?);
            Ok(0)
        }
        Cmd::Usb { cmd } => match cmd {
            UsbCmd::Status => {
                emit(&usb::volume_status(&cfg)?);
                Ok(0)
            }
            UsbCmd::Format {
                device,
                role,
                confirm,
            } => {
                if confirm != WIPE_PHRASE {
                    anyhow::bail!("pass --confirm {WIPE_PHRASE}");
                }
                let r = cfg.role(&role).clone();
                emit(&usb::format_usb(&cfg, &device, &r, &confirm)?);
                Ok(0)
            }
            UsbCmd::Seed => {
                let written = usb::seed_meta(&cfg, &store)?;
                emit(&serde_json::json!({"seeded": written}));
                Ok(0)
            }
        },
        Cmd::Tui | Cmd::Mcp => unreachable!(),
    }
}

fn emit(v: &Value) {
    println!("{}", serde_json::to_string_pretty(v).unwrap());
}
