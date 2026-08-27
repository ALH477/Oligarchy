//! oligarchy-p2pd — the Oligarchy P2P substituter.
//!
//! Stage 1: a loopback HTTP binary-cache adapter that proxies upstream caches.
//! There is no peer-to-peer transport yet and no local artifact cache; those
//! are stages 3-5 and 2 respectively. What exists now is the seam Nix talks to,
//! and the verification funnel every later source of bytes will pass through.
//!
//! The trust argument, which does not change in any later stage: this daemon is
//! **untrusted**. It runs unprivileged, it cannot write the Nix store, it is not
//! in `trusted-users`, and the substituter URI the module registers carries no
//! `trusted=` parameter. Every path it serves is signature-checked and
//! hash-checked by nix-daemon afterwards. P2P provides availability; Nix
//! provides trust.
//!
//! Design record: docs/p2p-substituter-roadmap.md

mod cache;
mod config;
mod decompress;
mod http;
mod narinfo;
mod nixhash;
mod nixstore;
mod peer;
mod resolve;
mod route;
mod torrent;
mod transport;
mod upstream;
mod verify;

use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use std::net::{IpAddr, SocketAddr};
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

const DEFAULT_CONFIG: &str = "/etc/oligarchy/p2p/config.json";

#[derive(Parser)]
#[command(name = "oligarchy-p2pd", version, about = "Oligarchy P2P substituter")]
struct Cli {
    #[arg(long, default_value = DEFAULT_CONFIG, env = "OLIGARCHY_P2P_CONFIG")]
    config: PathBuf,

    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// Run the adapter.
    Daemon,
    /// Parse and validate the config, print what would be served, exit.
    Check,
    /// Report what the running daemon is advertising to Nix.
    Status,
}

fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "info".into()),
        )
        .init();

    let cli = Cli::parse();
    let cfg = config::Config::load(&cli.config)?;

    match cli.cmd {
        Cmd::Check => {
            println!("config      : {}", cli.config.display());
            println!("bind        : {}:{}", cfg.bind_address, cfg.port);
            println!("store dir   : {}", cfg.store_dir);
            println!("priority    : {}", cfg.priority);
            println!("upstreams   : {}", cfg.upstreams.join(", "));
            println!("cache       : {}/nar, max {}", cfg.state_dir, cfg.max_cache_size);
            println!("from store  : {}", cfg.serve_from_store);
            println!("transport   : {}", cfg.transport);
            println!("peers       : {}", if cfg.peers.is_empty() {
                "(none)".to_string()
            } else {
                cfg.peers.join(", ")
            });
            println!("peer surface: {}", match &cfg.peer_listen {
                Some(a) => format!("{a}:{}", cfg.peer_port),
                None => "disabled".to_string(),
            });
            if cfg.transport == "bittorrent" {
                println!("swarm       : port {} , min artifact {}", cfg.swarm_port, cfg.min_artifact_size);
            }
            println!("OK");
            Ok(())
        }
        Cmd::Status => status(&cfg),
        Cmd::Daemon => {
            let rt = tokio::runtime::Builder::new_multi_thread()
                .enable_all()
                .build()
                .context("building the tokio runtime")?;
            rt.block_on(daemon(cfg))
        }
    }
}

fn status(cfg: &config::Config) -> Result<()> {
    let url = format!("http://{}:{}", cfg.bind_address, cfg.port);
    println!("substituter : {url}");
    println!("upstreams   : {}", cfg.upstreams.join(", "));

    // Built here rather than asked of the running daemon: `status` has to work
    // when the unit is down, which is exactly when someone runs it.
    let t: Box<dyn transport::ArtifactTransport> = match cfg.transport.as_str() {
        "lan" => Box::new(transport::lan::LanTransport::new(
            &cfg.peers,
            Duration::from_secs(cfg.peer_timeout_secs),
        )?),
        _ => Box::new(transport::NullTransport),
    };
    let ts = t.status();
    println!("transport   : {}", ts.name);
    if ts.peers_known > 0 {
        println!(
            "peers       : {}/{} reachable — {}",
            ts.peers_reachable, ts.peers_known, ts.detail
        );
    }
    println!("peer surface: {}", match &cfg.peer_listen {
        Some(a) => format!("{a}:{}", cfg.peer_port),
        None => "disabled".to_string(),
    });
    match cache::Cache::new(std::path::Path::new(&cfg.state_dir), 0)
        .and_then(|c| c.total_bytes())
    {
        Ok(b) => println!(
            "cache       : {:.1} MiB of {} used",
            b as f64 / (1024.0 * 1024.0),
            cfg.max_cache_size
        ),
        Err(e) => println!("cache       : unreadable ({e})"),
    }
    println!();
    println!("Verify from the outside with:");
    println!("  curl -s {url}/nix-cache-info");
    Ok(())
}

async fn daemon(cfg: config::Config) -> Result<()> {
    let ip: IpAddr = cfg.bind_address.parse().context("bind_address")?;
    // Third place this is checked, after the NixOS module's assertion and
    // Config::validate. It is checked here because this is the only one that
    // cannot be bypassed by editing a file: nothing between this line and the
    // syscall can widen it.
    anyhow::ensure!(
        ip.is_loopback(),
        "refusing to bind {ip}: the adapter is loopback-only by design"
    );
    let addr = SocketAddr::new(ip, cfg.port);

    // Stage 1 stores nothing, but the state dir is where stage 2's artifact
    // cache lands and it is created by tmpfiles, not by us. Checking it now
    // means a missing or unwritable dir is a startup failure with a clear
    // message rather than a first-cache-write failure much later.
    let state_dir = std::path::Path::new(&cfg.state_dir);
    anyhow::ensure!(
        state_dir.is_dir(),
        "state dir {} does not exist — systemd-tmpfiles should have created it",
        state_dir.display()
    );
    let max_bytes = cache::parse_size(&cfg.max_cache_size)?;
    let cache = cache::Cache::new(state_dir, max_bytes)?;
    match cache.evict() {
        Ok((before, after)) if before != after => {
            tracing::info!(before, after, "evicted to fit the cache budget at startup")
        }
        Ok(_) => {}
        Err(e) => tracing::warn!(error = %e, "startup eviction failed"),
    }

    let up = upstream::Upstream::new(
        cfg.upstream_bases().into_iter().map(String::from).collect(),
        Duration::from_secs(cfg.upstream_timeout_secs),
    )?;

    let peer_deadline = Duration::from_secs(cfg.peer_timeout_secs);
    let mut swarm_port = None;

    let transport: std::sync::Arc<dyn transport::ArtifactTransport> = match cfg.transport.as_str() {
        "lan" => std::sync::Arc::new(transport::lan::LanTransport::new(&cfg.peers, peer_deadline)?),

        "bittorrent" => {
            use std::num::NonZeroU32;
            let lan = transport::lan::LanTransport::new(&cfg.peers, peer_deadline)?;
            let scratch = state_dir.join("swarm");

            let opts = librqbit::SessionOptions {
                // No DHT and no trackers. Discovery is the LAN peer surface,
                // and every address dialled came from a private-range peer
                // list — which is what makes this work under strict-egress
                // with no firewall change. Turning either on would put the
                // daemon in touch with arbitrary internet hosts.
                disable_dht: true,
                disable_dht_persistence: true,
                // The swarm listens on exactly the advertised port, not a
                // range: peers learn it from /peer/v1/info and the firewall
                // opens one port.
                listen_port_range: Some(cfg.swarm_port..cfg.swarm_port + 1),
                ratelimits: librqbit::limits::LimitsConfig {
                    upload_bps: NonZeroU32::new(cfg.swarm_upload_bps),
                    download_bps: NonZeroU32::new(cfg.swarm_download_bps),
                },
                ..Default::default()
            };
            let session = librqbit::Session::new_with_opts(scratch.clone(), opts)
                .await
                .context("starting the BitTorrent session")?;
            swarm_port = Some(cfg.swarm_port);

            std::sync::Arc::new(transport::bittorrent::BitTorrentTransport::new(
                session,
                tokio::runtime::Handle::current(),
                lan,
                cfg.peers
                    .iter()
                    .filter_map(|p| p.parse().ok())
                    .collect(),
                cache::parse_size(&cfg.min_artifact_size)?,
                scratch,
            )?)
        }

        // Validated in Config::validate; this arm is the only other value.
        _ => std::sync::Arc::new(transport::NullTransport),
    };

    let state = Arc::new(http::AppState::new(
        up,
        cache,
        cfg.store_dir.clone(),
        cfg.priority,
        Duration::from_secs(cfg.upstream_timeout_secs),
        cfg.cache_downloaded,
        cfg.serve_from_store,
        transport.clone(),
        Duration::from_secs(cfg.peer_timeout_secs),
        swarm_port,
    ));

    // Bind before announcing readiness, so `systemctl start` returning means a
    // client can use the socket on the next line. Same rule as plugind.
    let listener = tokio::net::TcpListener::bind(addr)
        .await
        .with_context(|| format!("binding {addr}"))?;

    tracing::info!(
        %addr,
        upstreams = %cfg.upstreams.join(","),
        store_dir = %cfg.store_dir,
        priority = cfg.priority,
        cache_max = %cfg.max_cache_size,
        transport = %cfg.transport,
        peers = cfg.peers.len(),
        swarm_port = ?swarm_port,
        "oligarchy-p2pd ready"
    );

    // Re-announce what we already hold. A restart otherwise silently stops
    // seeding everything in the cache — the daemon looks healthy, peers see it as
    // reachable, and no artifact is ever served from it again.
    if transport.name() == "bittorrent" {
        let t = transport.clone();
        let dir = state_dir.join("nar");
        tokio::task::spawn_blocking(move || {
            let Ok(rd) = std::fs::read_dir(&dir) else { return };
            let mut n = 0usize;
            for e in rd.flatten() {
                let p = e.path();
                let Some(stem) = p.file_name().and_then(|s| s.to_str()) else { continue };
                let Some(stem) = stem.strip_suffix(".nar") else { continue };
                let Ok(h) = nixhash::Sha256Digest::from_nix32(stem) else { continue };
                let Ok(md) = e.metadata() else { continue };
                let art = transport::ArtifactRef {
                    hash_part: String::new(),
                    nar_hash: h,
                    nar_size: md.len(),
                };
                if t.provide(&art, &p).is_ok() {
                    n += 1;
                }
            }
            if n > 0 {
                tracing::info!(artifacts = n, "re-announced the cache to the swarm");
            }
        });
    }

    // The peer surface is a SEPARATE listener on a real interface, serving a
    // deliberately smaller route set. See peer.rs for why it is not simply the
    // substituter surface with a wider bind.
    if let Some(addr) = &cfg.peer_listen {
        let pip: IpAddr = addr.parse().context("peer_listen")?;
        let paddr = SocketAddr::new(pip, cfg.peer_port);
        let plistener = tokio::net::TcpListener::bind(paddr)
            .await
            .with_context(|| format!("binding the peer surface on {paddr}"))?;
        tracing::info!(%paddr, "peer surface listening");
        let pstate = state.clone();
        tokio::spawn(async move {
            if let Err(e) = axum::serve(plistener, peer::router(pstate)).await {
                tracing::error!(error = %e, "peer surface stopped");
            }
        });
    }

    axum::serve(listener, http::router(state))
        .with_graceful_shutdown(async {
            let _ = tokio::signal::ctrl_c().await;
        })
        .await
        .context("serving")?;
    Ok(())
}
