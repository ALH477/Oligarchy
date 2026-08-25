//! oligarchy-plugind: registry manager, sandbox launcher, and plugin host.
//!
//! One binary, three roles:
//!   plugind <verb>        - CLI, runs as the invoking user
//!   plugind daemon        - the supervisor, runs as oligarchy
//!   plugind shim <id>     - runs INSIDE the bwrap namespace; applies
//!                           landlock+seccomp to itself and then loads the
//!                           artifact. Never invoked by hand.

mod manifest;
mod plugin;
mod policy;
mod registry;
mod sandbox;
mod tiers;

use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use std::path::PathBuf;

use policy::Policy;
use registry::Store;

const DEFAULT_STATE: &str = "/var/lib/oligarchy/plugins";
const DEFAULT_POLICY: &str = "/etc/oligarchy/plugins/policy.json";
const DEFAULT_RUNTIME: &str = "/run/oligarchy/plugins";

#[derive(Parser)]
#[command(name = "plugind", version, about = "Oligarchy plugin runtime")]
struct Cli {
    #[arg(long, default_value = DEFAULT_STATE, env = "OLIGARCHY_STATE_DIR")]
    state_dir: PathBuf,
    #[arg(long, default_value = DEFAULT_POLICY, env = "OLIGARCHY_POLICY")]
    policy: PathBuf,
    #[arg(long, default_value = DEFAULT_RUNTIME, env = "OLIGARCHY_RUNTIME_DIR")]
    runtime_dir: PathBuf,
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// Fetch, verify, and register a plugin. Does not start it.
    Install {
        source: String,
        /// Skip signature enforcement. Development only; policy may forbid.
        #[arg(long)]
        allow_unsigned: bool,
    },
    /// Unregister. Keeps state and config.
    Remove { id: String },
    /// Unregister and delete state and config.
    Purge { id: String },
    /// Write the sandbox drop-in and start the unit.
    Enable {
        id: String,
        /// Do everything except start the unit: write the drop-in, reload the
        /// manager, and record the plugin as enabled so it comes up on the
        /// next boot. For staging a plugin you are not ready to run yet, and
        /// for testing unit generation without a working artifact.
        #[arg(long)]
        no_start: bool,
    },
    Disable { id: String },
    /// Stop, re-read the manifest from the store path, start.
    Reload { id: String },
    List,
    /// Print exactly what sandbox a plugin would get and why.
    Explain { id: String },
    /// Check manifests for things that are legal but unwise.
    Lint { id: Option<String> },
    /// Report kernel and userspace sandbox capability on this machine.
    Doctor,
    /// Regenerate /run drop-ins from the registry; re-authorize everything.
    Reconcile,
    /// The supervisor. Started by oligarchy-plugind.service.
    Daemon,
    /// Internal: runs inside the bwrap namespace.
    #[command(hide = true)]
    Shim { id: String },
    /// Internal: the host side of one plugin instance, started by the
    /// template unit.
    #[command(hide = true)]
    Run { id: String },
}

fn main() -> Result<()> {
    let cli = Cli::parse();

    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "info".into()),
        )
        .with_target(false)
        .init();

    let policy = Policy::load(&cli.policy)?;

    match cli.cmd {
        Cmd::Install {
            source,
            allow_unsigned,
        } => {
            let mut store = Store::open(&cli.state_dir)?;
            let id = store.install(&source, &policy, allow_unsigned)?;
            println!("installed {id}");
            let entry = store
                .get(&id)
                .context("plugin vanished from the registry immediately after install")?;
            println!("{}", tiers::explain(&entry.manifest, &policy));
            println!("run `plugind enable {id}` to start it");
        }

        Cmd::Remove { id } => {
            Store::open(&cli.state_dir)?.remove(&id)?;
            println!("removed {id} (state and config kept; `purge` to delete them)");
        }

        Cmd::Purge { id } => {
            Store::open(&cli.state_dir)?.purge(&id)?;
            println!("purged {id}");
        }

        Cmd::Enable { id, no_start } => {
            let mut store = Store::open(&cli.state_dir)?;
            store.enable(&id, !no_start)?;
            println!("enabled {id}");
        }

        Cmd::Disable { id } => {
            Store::open(&cli.state_dir)?.disable(&id)?;
            println!("disabled {id}");
        }

        Cmd::Reload { id } => {
            let mut store = Store::open(&cli.state_dir)?;
            store.disable(&id)?;
            store.enable(&id, true)?;
            println!("reloaded {id}");
        }

        Cmd::List => {
            let store = Store::open(&cli.state_dir)?;
            println!(
                "{:<28} {:<9} {:<8} {:<7} {:<6} {}",
                "ID", "TIER", "JIT", "W^X", "SIG", "STATE"
            );
            for e in store.entries() {
                println!(
                    "{:<28} {:<9} {:<8} {:<7} {:<6} {}",
                    e.manifest.id,
                    format!("{:?}", e.manifest.tier).to_lowercase(),
                    format!("{:?}", e.manifest.jit).to_lowercase(),
                    if e.manifest.wx_enforced() { "on" } else { "OFF" },
                    if e.signature_verified { "ok" } else { "NONE" },
                    if e.enabled { "enabled" } else { "installed" },
                );
            }
        }

        Cmd::Explain { id } => {
            let store = Store::open(&cli.state_dir)?;
            let e = store
                .get(&id)
                .with_context(|| format!("no such plugin {id}"))?;
            print!("{}", tiers::explain(&e.manifest, &policy));
            if matches!(e.manifest.tier, manifest::Tier::Native | manifest::Tier::Lua) {
                let plan = sandbox::bwrap::plan(
                    &e.manifest,
                    sandbox::bwrap::Paths {
                        store_path: &e.store_path,
                        state_dir: &cli.state_dir,
                        abi_dir: &cli.runtime_dir.join("abi"),
                    },
                    PathBuf::from("bwrap"),
                    &std::env::current_exe()?,
                )?;
                println!("\nsandbox invocation:\n  {}", sandbox::bwrap::render(&plan));
            }
        }

        Cmd::Lint { id } => {
            let store = Store::open(&cli.state_dir)?;
            let mut findings = 0;
            for e in store.entries() {
                if id.as_deref().is_some_and(|want| want != e.manifest.id) {
                    continue;
                }
                if let Some((better, why)) = tiers::recommend(&e.manifest) {
                    findings += 1;
                    println!("{}: consider tier={:?}\n  {}", e.manifest.id, better, why);
                }
                if e.manifest.grants_wx_to_plugin() {
                    findings += 1;
                    println!(
                        "{}: granted writable-executable memory (jit=self). \
                         Confirm it genuinely generates code at runtime; if not, \
                         set jit=none and get the filter back.",
                        e.manifest.id
                    );
                }
                if !e.signature_verified {
                    findings += 1;
                    println!("{}: no valid signature", e.manifest.id);
                }
            }
            if findings == 0 {
                println!("no findings");
            }
        }

        Cmd::Doctor => {
            print!("{}", sandbox::doctor());
            println!("policy: {}", cli.policy.display());
            println!("  self-JIT permitted: {}", policy.allow_self_jit);
            println!("  microvm permitted:  {}", policy.allow_microvm);
            println!("  tiers:              {:?}", policy.allowed_tiers);
            println!("  signatures required:{}", policy.require_signature);
        }

        Cmd::Reconcile => {
            let mut store = Store::open(&cli.state_dir)?;
            store.reconcile(&policy)?;
            println!("reconciled");
        }

        Cmd::Daemon => daemon(&cli, &policy)?,

        // By reference: these arms pass the whole `cli` on, which a partial
        // move out of `cli.cmd` would forbid.
        Cmd::Run { ref id } => run_one(&cli, &policy, id)?,

        Cmd::Shim { ref id } => shim(&cli, id)?,
    }

    Ok(())
}

/// The supervisor. Its only jobs are to reconcile at boot and to keep the
/// control socket open; individual plugins live in their own units so a
/// crashing plugin cannot take the supervisor with it.
fn daemon(cli: &Cli, policy: &Policy) -> Result<()> {
    let mut store = Store::open(&cli.state_dir)?;
    std::fs::create_dir_all(&cli.runtime_dir)?;

    tracing::info!("{}", sandbox::doctor().trim());
    store
        .reconcile(policy)
        .context("reconciling registry against policy")?;

    let enabled: Vec<String> = store
        .entries()
        .filter(|e| e.enabled)
        .map(|e| e.manifest.id.clone())
        .collect();
    tracing::info!(count = enabled.len(), "plugins enabled: {enabled:?}");

    #[cfg(target_os = "linux")]
    let _ = sd_notify::notify(false, &[sd_notify::NotifyState::Ready]);

    // The control socket handler is omitted here; it accepts the same verbs
    // as the CLI over a unix socket at $RUNTIME_DIR/control.sock so the
    // desktop and the FX Bazaar UI do not have to shell out.
    loop {
        std::thread::park();
    }
}

/// Host side of one plugin instance. For wasm this loads in-process; for
/// native/lua it spawns bwrap, which re-enters as `shim`.
fn run_one(cli: &Cli, policy: &Policy, id: &str) -> Result<()> {
    let store = Store::open(&cli.state_dir)?;
    let e = store.get(id).with_context(|| format!("no such plugin {id}"))?;

    match e.manifest.tier {
        manifest::Tier::Wasm | manifest::Tier::Microvm => {
            // Only Tier 0 needs an Engine. Building one for a microvm plugin
            // was pure waste on a unit that runs with MDWE=yes.
            let engine = if e.manifest.tier == manifest::Tier::Wasm {
                Some(tiers::wasm::engine()?)
            } else {
                None
            };
            let mut p = tiers::load(
                e.manifest.clone(),
                tiers::Ctx {
                    engine: engine.as_ref(),
                    store_path: &e.store_path,
                    state_dir: &cli.state_dir,
                    runtime_dir: &cli.runtime_dir,
                    policy,
                    config: store.config_for(id),
                },
            )?;
            p.init()?;
            #[cfg(target_os = "linux")]
            let _ = sd_notify::notify(false, &[sd_notify::NotifyState::Ready]);
            tracing::info!(plugin = %id, "ready");
            loop {
                std::thread::park();
            }
        }
        manifest::Tier::Native | manifest::Tier::Lua => {
            let plan = sandbox::bwrap::plan(
                &e.manifest,
                sandbox::bwrap::Paths {
                    store_path: &e.store_path,
                    state_dir: &cli.state_dir,
                    abi_dir: &cli.runtime_dir.join("abi"),
                },
                which_bwrap()?,
                &std::env::current_exe()?,
            )?;
            if !plan.notify_reachable {
                // Type=notify plus --unshare-all is a trap: an abstract
                // NOTIFY_SOCKET cannot cross the network namespace, so the
                // unit would sit there and time out with no useful message.
                anyhow::bail!(
                    "NOTIFY_SOCKET is not reachable inside the sandbox for plugin \
                     {id}. Set NotifyAccess/Type=exec on the unit, or run systemd \
                     with a pathname notify socket."
                );
            }
            tracing::debug!("exec: {}", sandbox::bwrap::render(&plan));
            let err = exec(&plan);
            Err(err).context("exec bwrap")
        }
    }
}

/// Inside the namespace. Confine, then load. Nothing between these two steps.
fn shim(cli: &Cli, id: &str) -> Result<()> {
    let store = Store::open(&cli.state_dir)?;
    let e = store.get(id).with_context(|| format!("no such plugin {id}"))?;
    let policy = Policy::load(&cli.policy)?;

    let conf = sandbox::prepare(&e.manifest, &cli.state_dir, &e.store_path)?;
    sandbox::apply(&conf, &e.manifest)?;
    // From here the process cannot see the filesystem outside its allowlist
    // and, unless jit=self, cannot obtain executable memory.

    // No Engine here. `shim` is only ever reached for native/lua — run_one
    // dispatches wasm and microvm in-process — and neither tier reads
    // ctx.engine, so building one would reserve the pooling allocator's
    // address space on every tier 1 plugin start for nothing. Same waste that
    // run_one already avoids for microvm.
    let mut p = tiers::load(
        e.manifest.clone(),
        tiers::Ctx {
            engine: None,
            store_path: &e.store_path,
            state_dir: &cli.state_dir,
            runtime_dir: &cli.runtime_dir,
            policy: &policy,
            config: store.config_for(id),
        },
    )?;
    p.init()?;

    #[cfg(target_os = "linux")]
    let _ = sd_notify::notify(false, &[sd_notify::NotifyState::Ready]);
    tracing::info!(plugin = %id, "ready (confined)");

    loop {
        std::thread::park();
    }
}

fn which_bwrap() -> Result<PathBuf> {
    for dir in std::env::split_paths(&std::env::var_os("PATH").unwrap_or_default()) {
        let p = dir.join("bwrap");
        if p.is_file() {
            return Ok(p);
        }
    }
    anyhow::bail!("bwrap not found in PATH; set custom.plugins.allowedTiers = [ \"wasm\" ] or install bubblewrap")
}

fn exec(plan: &sandbox::bwrap::BwrapPlan) -> std::io::Error {
    use std::os::unix::process::CommandExt;
    std::process::Command::new(&plan.bwrap)
        .args(&plan.argv)
        .exec()
}
