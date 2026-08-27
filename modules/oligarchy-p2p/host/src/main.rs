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
mod declared;
mod decompress;
mod http;
mod narinfo;
mod nixhash;
mod nixstore;
mod peer;
mod resolve;
mod route;
mod scope;
mod selftest;
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
    /// Mint and sign narinfo for the declared packages, so peers can fetch
    /// paths this host BUILT.
    ///
    /// Run from `oligarchy-p2p-seed.service`, as root, and deliberately not
    /// from the daemon: this needs a signing key and the Nix database, and
    /// `daemon` is allowed neither. Neither the key nor the path list is in
    /// the config file — they arrive here and nowhere else.
    /// Assert, on this host, that the things this daemon claims are true.
    ///
    /// Not a config dump — `check` is that. This exercises the real surface and
    /// reports what happened: whether anything is listening, whether the
    /// declared tier is coherent, whether `ReadOnlyPaths` actually refuses a
    /// write, and whether a published artifact round-trips through our own HTTP
    /// and hashes to what its narinfo promised. Non-zero exit if any check
    /// fails.
    ///
    /// Available in release builds on purpose, for the same reason
    /// `plugind selftest` is: every failure this subsystem has shipped was one
    /// a passing test could not distinguish from working.
    Selftest,
    Seed {
        /// `${closureInfo}/store-paths` for `custom.p2pCache.servePackages`.
        #[arg(long)]
        store_paths: PathBuf,
        /// The Ed25519 secret key, `nix key generate-secret` format.
        #[arg(long)]
        key_file: PathBuf,
    },
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
            println!("declared    : {}", if cfg.serve_declared {
                match cache::Cache::open(std::path::Path::new(&cfg.state_dir), 1)
                    .and_then(|c| c.list_declared())
                {
                    Ok(v) => format!("{} package(s) published", v.len()),
                    Err(e) => format!("enabled, unreadable ({e})"),
                }
            } else {
                "disabled".to_string()
            });
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
        Cmd::Selftest => {
            let checks = selftest::run(&cfg);
            let (report, ok) = selftest::render(&checks);
            print!("{report}");
            if !ok {
                std::process::exit(1);
            }
            Ok(())
        }
        Cmd::Seed { store_paths, key_file } => seed(&cfg, &store_paths, &key_file),
        Cmd::Daemon => {
            let rt = tokio::runtime::Builder::new_multi_thread()
                .enable_all()
                .build()
                .context("building the tokio runtime")?;
            rt.block_on(daemon(cfg))
        }
    }
}

fn seed(cfg: &config::Config, store_paths: &std::path::Path, key_file: &PathBuf) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;

    let meta = std::fs::metadata(key_file)
        .with_context(|| format!("reading signing key {}", key_file.display()))?;
    declared::check_key_mode(meta.permissions().mode(), key_file)?;
    let secret = std::fs::read_to_string(key_file)
        .with_context(|| format!("reading signing key {}", key_file.display()))?;

    let paths = declared::read_path_list(store_paths)?;
    let max = cache::parse_size(&cfg.max_cache_size)?;
    // `open`, not `new`: `new` sweeps tmp/, and this process can run while the
    // daemon is mid-fetch.
    let cache = cache::Cache::open(std::path::Path::new(&cfg.state_dir), max)?;

    let sum = declared::seed(&cache, "nix", key_file, &secret, &paths)?;
    tracing::info!(
        published = sum.published,
        signed = sum.signed,
        unpublished = sum.unpublished,
        skipped = sum.skipped,
        "seeded declared packages"
    );
    if sum.published == 0 && !paths.is_empty() {
        // Not fatal — a seeding failure must never take the substituter down —
        // but it must be visible. "Serving nothing" otherwise looks identical
        // to "serving fine" from outside.
        tracing::warn!(
            declared = paths.len(),
            "nothing was published: every declared path already carries a \
             signature, so nothing here is locally built"
        );
    }
    Ok(())
}

fn status(cfg: &config::Config) -> Result<()> {
    let url = format!("http://{}:{}", cfg.bind_address, cfg.port);

    // ASK the daemon rather than describing the config, because "is it up" is
    // the question someone running this actually has. Printing the configured
    // URL and stopping there produced a cheerful report on a host where the
    // daemon was dead — every line was true and the machine was serving
    // nothing.
    let live = transport::lan::ureq_like::Client::new(Duration::from_secs(3))
        .get_text(&format!("{url}/nix-cache-info"), Duration::from_secs(3), 64 * 1024);
    match &live {
        Ok(Some(body)) if body.contains(&format!("StoreDir: {}", cfg.store_dir)) => {
            println!("substituter : {url}  (up)")
        }
        Ok(Some(_)) => println!("substituter : {url}  (ANSWERING, but not for {})", cfg.store_dir),
        Ok(None) | Err(_) => println!("substituter : {url}  (NOT RESPONDING)"),
    }
    println!("upstreams   : {}", cfg.upstreams.join(", "));

    // Built here rather than asked of the running daemon: `status` has to work
    // when the unit is down, which is exactly when someone runs it.
    let t: Box<dyn transport::ArtifactTransport> = match cfg.transport.as_str() {
        "lan" => Box::new(transport::lan::LanTransport::new(
            &cfg.peers,
            Duration::from_secs(cfg.peer_timeout_secs),
            scope::PeerScope::new(&cfg.peer_public_keys, &cfg.accept_from_peers),
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
    // `open`, NOT `new`. `new` sweeps tmp/, and the doc comment on it says only
    // the daemon may do that — a sweep under a running fetch deletes the slot
    // being written and turns a good fetch into a rename of a file that is no
    // longer there. `check` was fixed for this and `status` was missed, so a
    // routine status call could break a download in flight.
    let cache = cache::Cache::open(std::path::Path::new(&cfg.state_dir), 0);
    match cache.as_ref().map_err(|e| e.to_string()).and_then(|c| c.total_bytes().map_err(|e| e.to_string())) {
        Ok(b) => println!(
            "cache       : {:.1} MiB of {} used",
            b as f64 / (1024.0 * 1024.0),
            cfg.max_cache_size
        ),
        Err(e) => println!("cache       : unreadable ({e})"),
    }
    // The declared tier, because "publishing nothing" was invisible from here
    // and visible only from `check`.
    if cfg.serve_declared {
        match cache.as_ref().map_err(|e| e.to_string()).and_then(|c| c.list_declared().map_err(|e| e.to_string())) {
            Ok(v) if v.is_empty() => {
                println!("declared    : NOTHING PUBLISHED — check oligarchy-p2p-seed.service")
            }
            Ok(v) => println!("declared    : {} package(s) published", v.len()),
            Err(e) => println!("declared    : unreadable ({e})"),
        }
    }
    let sc = scope::PeerScope::new(&cfg.peer_public_keys, &cfg.accept_from_peers);
    if sc.is_active() {
        println!("peer trust  : {}", sc.describe());
    }
    println!();
    println!("Assert all of this rather than reading it:");
    println!("  oligarchy-p2p-selftest");
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

    // Report the declared tier explicitly. A host configured to seed its own
    // builds whose seed unit failed looks, from outside and from every other
    // log line, exactly like one that is working — it answers, it proxies, it
    // just quietly serves none of what it was set up to serve.
    if cfg.serve_declared {
        match cache.list_declared() {
            Ok(v) if v.is_empty() => tracing::warn!(
                "servePackages is set but nothing is published in {}/declared — \
                 check oligarchy-p2p-seed.service",
                cfg.state_dir
            ),
            Ok(v) => tracing::info!(count = v.len(), "publishing declared packages to peers"),
            Err(e) => tracing::warn!(error = %e, "cannot read the declared tier"),
        }
    }

    let up = upstream::Upstream::new(
        cfg.upstream_bases().into_iter().map(String::from).collect(),
        Duration::from_secs(cfg.upstream_timeout_secs),
    )?;

    let peer_deadline = Duration::from_secs(cfg.peer_timeout_secs);
    let mut swarm_port = None;

    // Resolved once. `is_active()` is false on every host that has not trusted
    // a peer key, which is all of stages 1-4, and the check is then inert.
    let peer_scope = scope::PeerScope::new(&cfg.peer_public_keys, &cfg.accept_from_peers);
    if peer_scope.is_active() {
        tracing::info!(scope = %peer_scope.describe(), "peer keys are bounded");
    }

    let transport: std::sync::Arc<dyn transport::ArtifactTransport> = match cfg.transport.as_str() {
        "lan" => std::sync::Arc::new(transport::lan::LanTransport::new(
            &cfg.peers,
            peer_deadline,
            peer_scope.clone(),
        )?),

        "bittorrent" => {
            use std::num::NonZeroU32;
            let lan = transport::lan::LanTransport::new(&cfg.peers, peer_deadline, peer_scope.clone())?;
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
        peer_scope,
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
