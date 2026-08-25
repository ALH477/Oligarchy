//! oligarchy-plugind: registry manager, sandbox launcher, and plugin host.
//!
//! One binary, three roles:
//!   plugind <verb>        - CLI, runs as the invoking user
//!   plugind daemon        - the supervisor, runs as oligarchy
//!   plugind shim <id>     - runs INSIDE the bwrap namespace; applies
//!                           landlock+seccomp to itself and then loads the
//!                           artifact. Never invoked by hand.

mod control;
mod manifest;
mod plugin;
mod policy;
mod registry;
mod sandbox;
mod tiers;

use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use std::path::{Path, PathBuf};

use control::{Reply, Request};
use policy::Policy;
use registry::{Authority, Store};

const DEFAULT_STATE: &str = "/var/lib/oligarchy/plugins";
const DEFAULT_POLICY: &str = "/etc/oligarchy/plugins/policy.json";
const DEFAULT_RUNTIME: &str = "/run/oligarchy/plugins";
/// The supervisor's own runtime directory, deliberately NOT the one the plugin
/// instances share.
///
/// systemd chowns a RuntimeDirectory to the owning unit's User, and removes it
/// when that unit stops. With the control socket in the instances' directory,
/// `disable`-ing any plugin would stop an instance and take the socket with it
/// — a member of the install group could permanently break the install path
/// with one legitimate request — and once an instance had run, the directory
/// would be owned by the unprivileged plugin user, who could then unlink the
/// socket and bind their own in its place.
const DEFAULT_CONTROL: &str = "/run/oligarchy/plugind";

#[derive(Parser)]
#[command(name = "plugind", version, about = "Oligarchy plugin runtime")]
struct Cli {
    #[arg(long, default_value = DEFAULT_STATE, env = "OLIGARCHY_STATE_DIR")]
    state_dir: PathBuf,
    #[arg(long, default_value = DEFAULT_POLICY, env = "OLIGARCHY_POLICY")]
    policy: PathBuf,
    #[arg(long, default_value = DEFAULT_RUNTIME, env = "OLIGARCHY_RUNTIME_DIR")]
    runtime_dir: PathBuf,
    #[arg(long, default_value = DEFAULT_CONTROL, env = "OLIGARCHY_CONTROL_DIR")]
    control_dir: PathBuf,
    /// Group allowed to reach the control socket, i.e. allowed to ask the
    /// supervisor to install a *signed* plugin. Daemon only. Absent means
    /// root only, which is the safe default: handing this out is opt-in.
    #[arg(long, env = "OLIGARCHY_CONTROL_GROUP")]
    control_group: Option<String>,
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
    Shim {
        /// The plugin's store path. Passed explicitly because the registry is
        /// root-owned and deliberately not visible inside the sandbox — and a
        /// confined plugin has no business reading the list of every other
        /// plugin on the machine.
        #[arg(long)]
        store_path: PathBuf,
        id: String,
    },
    /// Prove, on this kernel, that the W^X filter does what the manifest says.
    ///
    /// Builds the filter for a synthetic manifest at each `jit` setting,
    /// applies it in a forked child, and has that child attempt exactly what
    /// the filter is supposed to stop. Available in release builds on purpose:
    /// a seccomp filter that silently failed to install is the worst outcome in
    /// this design, and "we ran the unit tests" does not detect it.
    Selftest,
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

    // The registry-mutating verbs go through one dispatcher, `apply`, whether
    // they execute here or in the supervisor. An account that cannot write the
    // registry is not locked out: the same request is forwarded over the control
    // socket and the supervisor — which holds the policy — applies it. See
    // control.rs for why that is the seam, rather than loosening the registry or
    // trusting the user to Nix.
    if let Some(req) = wire_request(&cli.cmd) {
        let reply = if registry_writable(&cli.state_dir) {
            apply(
                &mut Store::open(&cli.state_dir)?,
                &req,
                &policy,
                Authority::Local {
                    allow_unsigned: asked_for_unsigned(&cli.cmd),
                },
            )
        } else {
            anyhow::ensure!(
                !asked_for_unsigned(&cli.cmd),
                "--allow-unsigned needs write access to the registry, which this \
                 account does not have. It is not available over the control \
                 socket at all: the request format has no field for it, so an \
                 unprivileged install is always signature-checked."
            );
            control::request(&cli.control_dir, &req)
        }?;
        print!("{}", render(reply));
        return Ok(());
    }

    match cli.cmd {
        Cmd::Purge { id } => {
            Store::open(&cli.state_dir)?.purge(&id)?;
            println!("purged {id}");
        }

        Cmd::Reload { id } => {
            let mut store = Store::open(&cli.state_dir)?;
            store.disable(&id)?;
            store.enable(&id, true)?;
            println!("reloaded {id}");
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
                        policy_file: &cli.policy,
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

        Cmd::Shim {
            ref store_path,
            ref id,
        } => shim(&cli, store_path, id)?,

        Cmd::Selftest => print!("{}", sandbox::selftest()?),

        // Handled above by `apply`, locally or over the socket. Listed rather
        // than caught by `_` so adding a verb is a compile error here until it
        // has been decided which side it belongs on.
        Cmd::Install { .. }
        | Cmd::Remove { .. }
        | Cmd::Enable { .. }
        | Cmd::Disable { .. }
        | Cmd::List => unreachable!("dispatched by wire_request/apply"),
    }

    Ok(())
}

/// The supervisor. Its only jobs are to reconcile at boot and to keep the
/// control socket open; individual plugins live in their own units so a
/// crashing plugin cannot take the supervisor with it.
fn daemon(cli: &Cli, policy: &Policy) -> Result<()> {
    std::fs::create_dir_all(&cli.runtime_dir)?;
    tracing::info!("{}", sandbox::doctor().trim());

    // SCOPED, and it has to be. A Store holds the registry lock for its whole
    // lifetime, and the serve loop below opens one per request — so a Store
    // that outlived this block would make the supervisor deadlock against
    // itself on the first request, which is exactly what happened the first
    // time the lock was introduced. It presents as a client timing out.
    let enabled: Vec<String> = {
        let mut store = Store::open(&cli.state_dir)?;
        store
            .reconcile(policy)
            .context("reconciling registry against policy")?;
        store
            .entries()
            .filter(|e| e.enabled)
            .map(|e| e.manifest.id.clone())
            .collect()
    };
    tracing::info!(count = enabled.len(), "plugins enabled: {enabled:?}");

    // Bind before signalling readiness, so `systemctl start` returning means
    // the socket is there and a script can use it on the next line.
    let listener = control::bind(&cli.control_dir, cli.control_group.as_deref())?;

    #[cfg(target_os = "linux")]
    let _ = sd_notify::notify(false, &[sd_notify::NotifyState::Ready]);

    let state_dir = cli.state_dir.clone();
    let policy = policy.clone();
    control::serve(listener, move |req| {
        // Re-open per request rather than holding one Store for the daemon's
        // lifetime: root can still run `plugind install` directly, and a
        // long-lived in-memory copy would silently overwrite whatever that did.
        // The registry is one small JSON file; re-reading it is cheaper than the
        // class of bug it removes.
        let mut store = Store::open(&state_dir)?;
        // Authority::Socket is not a check that could be forgotten in a
        // refactor: the wire type has no field that could express either
        // concession it withholds. See control.rs.
        apply(&mut store, &req, &policy, Authority::Socket)
    })
}

/// The registry-mutating verbs, dispatched in exactly one place.
///
/// Shared by the CLI and the supervisor deliberately. An earlier version had
/// three parallel matches over the same five verbs — the CLI's arms, the
/// CLI-to-wire mapping, and the daemon's arms — and they had already drifted
/// into printing two different messages for `remove`.
///
/// `who` is the one input the two callers do not agree on, and that is the
/// point: `control::Request` can express neither of the concessions
/// `Authority::Local` carries, so a request that arrived over the socket can
/// only ever be `Authority::Socket`.
fn apply(store: &mut Store, req: &Request, policy: &Policy, who: Authority) -> Result<Reply> {
    Ok(match req {
        Request::Install { source } => {
            let id = store.install(source, policy, who)?;
            let e = store
                .get(&id)
                .context("plugin vanished from the registry immediately after install")?;
            // The sandbox explanation travels with it, so an install done for
            // you reads exactly like an install you did yourself.
            Reply::text(format!(
                "installed {id}\n{}run `plugind enable {id}` to start it\n",
                tiers::explain(&e.manifest, policy)
            ))
        }
        Request::Remove { id } => {
            store.remove(id)?;
            Reply::text(format!(
                "removed {id} (state and config kept; `purge` deletes them)\n"
            ))
        }
        Request::Enable { id, no_start } => {
            store.enable(id, !no_start)?;
            Reply::text(format!("enabled {id}\n"))
        }
        Request::Disable { id } => {
            store.disable(id)?;
            Reply::text(format!("disabled {id}\n"))
        }
        Request::List => Reply::Entries {
            entries: store.entries().cloned().collect(),
        },
    })
}

/// Turn a reply into terminal output. Formatting is the client's job: the
/// daemon returns the registry, not a table. See control::Reply.
fn render(reply: Reply) -> String {
    match reply {
        Reply::Text { text } => text,
        Reply::Entries { entries } => render_list(&entries),
    }
}

fn render_list(entries: &[registry::Entry]) -> String {
    let mut out = format!(
        "{:<28} {:<9} {:<8} {:<7} {:<6} {}\n",
        "ID", "TIER", "JIT", "W^X", "SIG", "STATE"
    );
    for e in entries {
        out.push_str(&format!(
            "{:<28} {:<9} {:<8} {:<7} {:<6} {}\n",
            e.manifest.id,
            format!("{:?}", e.manifest.tier).to_lowercase(),
            format!("{:?}", e.manifest.jit).to_lowercase(),
            if e.manifest.wx_enforced() { "on" } else { "OFF" },
            if e.signature_verified { "ok" } else { "NONE" },
            if e.enabled { "enabled" } else { "installed" },
        ));
    }
    out
}

/// Can this process mutate the registry in place?
///
/// Probed rather than discovered by failing: `Store::open` succeeds for a
/// reader, so an unprivileged install would otherwise do all its work — a
/// substitution included — and only then hit EACCES in `flush()`.
fn registry_writable(state_dir: &Path) -> bool {
    nix::unistd::access(
        &state_dir.join("registry"),
        nix::unistd::AccessFlags::W_OK,
    )
    .is_ok()
}

/// The request a CLI verb corresponds to, or None for verbs that are not
/// registry mutations and never travel.
///
/// `purge` is deliberately absent: it destroys presets, and doing that on
/// someone else's plugin is not something membership of the install group
/// should buy. `reconcile`, `daemon` and `shim` are the supervisor's own
/// business, and `doctor`/`explain`/`lint` need no write access.
fn wire_request(cmd: &Cmd) -> Option<Request> {
    Some(match cmd {
        Cmd::Install { source, .. } => Request::Install {
            source: source.clone(),
        },
        Cmd::Remove { id } => Request::Remove { id: id.clone() },
        Cmd::Enable { id, no_start } => Request::Enable {
            id: id.clone(),
            no_start: *no_start,
        },
        Cmd::Disable { id } => Request::Disable { id: id.clone() },
        Cmd::List => Request::List,
        _ => return None,
    })
}

/// Did the caller ask to skip signature enforcement? Only `install` can.
fn asked_for_unsigned(cmd: &Cmd) -> bool {
    matches!(
        cmd,
        Cmd::Install {
            allow_unsigned: true,
            ..
        }
    )
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
                    policy_file: &cli.policy,
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
fn shim(cli: &Cli, store_path: &Path, id: &str) -> Result<()> {
    // No Store here. The manifest comes from the artifact itself, which is in
    // the Nix store, immutable, and the only thing this process is allowed to
    // see besides its own state. It has already been signature-verified and
    // policy-authorised at install time; re-reading it and re-authorising is
    // defence in depth, not the primary gate.
    let manifest = manifest::Manifest::load(&store_path.join("plugin.toml"))?;
    anyhow::ensure!(
        manifest.id == id,
        "shim asked for {id} but {} contains {}",
        store_path.display(),
        manifest.id
    );
    let policy = Policy::load(&cli.policy)?;
    let config = registry::config_for(&cli.state_dir, id);

    let conf = sandbox::prepare(&manifest, &cli.state_dir, store_path)?;
    sandbox::apply(&conf, &manifest)?;
    // From here the process cannot see the filesystem outside its allowlist
    // and, unless jit=self, cannot obtain executable memory.

    // No Engine here. `shim` is only ever reached for native/lua — run_one
    // dispatches wasm and microvm in-process — and neither tier reads
    // ctx.engine, so building one would reserve the pooling allocator's
    // address space on every tier 1 plugin start for nothing. Same waste that
    // run_one already avoids for microvm.
    let mut p = tiers::load(
        manifest,
        tiers::Ctx {
            engine: None,
            store_path,
            state_dir: &cli.state_dir,
            runtime_dir: &cli.runtime_dir,
            policy: &policy,
            config,
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
