//! Landlock: the filesystem and network allowlist, derived directly from
//! `[caps]` in the manifest.
//!
//! This is the layer that keeps working even if the userns/bwrap setup is
//! imperfect, which matters because bubblewrap dropped its setuid mode and
//! unprivileged user namespaces are disabled on some hardened kernels.
//! Landlock needs no privilege and no namespace.
//!
//! ABI targeting:
//!   V1 (5.13) filesystem
//!   V2 (5.19) + REFER (rename/link across dirs)
//!   V3 (6.2)  + TRUNCATE
//!   V4 (6.7)  + TCP bind/connect          <- we want at least this
//!   V5 (6.10) + IOCTL_DEV
//!   V6 (6.12) + scoped: abstract unix sockets, signals
//!   V7 (6.15) + audit logging
//!   V8        + RESTRICT_SELF_TSYNC       <- matters for audio threads
//!
//! We ask for TARGET_ABI and degrade with BestEffort. The degradation is
//! *reported*, not silent: on a kernel below V4 the network rules are dropped
//! entirely and we escalate to a netns instead, because a silently-unenforced
//! network policy is worse than no policy.
//!
//! TARGET_ABI is deliberately below the newest ABI the `landlock` crate knows
//! about. Raising it widens the set of access rights we *handle*, which on an
//! older kernel means more of the ruleset gets dropped by BestEffort, so it is
//! a policy change and not a version bump. Raise it on purpose or not at all.

use anyhow::{Context, Result};
use landlock::{
    Access, AccessFs, AccessNet, BitFlags, CompatLevel, Compatible, NetPort, PathBeneath, PathFd,
    Ruleset, RulesetAttr, RulesetCreatedAttr, RulesetStatus, ABI,
};
use std::path::{Path, PathBuf};

/// Highest ABI this build asks for. See the module docs before raising it.
const TARGET_ABI: ABI = ABI::V5;
/// Below this, network confinement is not available and the caller must
/// fall back to an empty network namespace.
const NET_ABI: ABI = ABI::V4;

/// The Landlock ABI the *running* kernel implements, or `ABI::Unsupported`.
///
/// The `landlock` crate keeps its own equivalent private on the grounds that
/// callers should let the Ruleset compat machinery handle version differences
/// rather than branching themselves. That is right for choosing access rights
/// and wrong for the one decision we have to make anyway: below ABI v4 there is
/// no network confinement at all and the caller must escalate to an empty
/// network namespace. Believing ourselves confined because BestEffort dropped
/// the net rules is the failure mode this exists to prevent.
fn running_abi() -> ABI {
    // SAFETY: LANDLOCK_CREATE_RULESET_VERSION with a null attribute and size 0
    // is the documented version query. It creates no ruleset and no fd.
    let v = unsafe {
        libc::syscall(
            libc::SYS_landlock_create_ruleset,
            std::ptr::null::<libc::c_void>(),
            0usize,
            1u32, // LANDLOCK_CREATE_RULESET_VERSION
        )
    };
    // `From<i32> for ABI` maps <= 0 (EOPNOTSUPP: built in but not enabled at
    // boot; ENOSYS: not built in) to Unsupported and saturates above at the
    // newest ABI the crate knows, which is the effective ABI we want.
    ABI::from(v as i32)
}

#[derive(Debug, Default, Clone)]
pub struct FsPolicy {
    pub read: Vec<PathBuf>,
    pub read_write: Vec<PathBuf>,
    /// Executable-but-not-writable. The Nix store lives here, always.
    pub read_exec: Vec<PathBuf>,
    pub tcp_connect: Vec<u16>,
    pub tcp_bind: Vec<u16>,
    pub allow_all_tcp: bool,
}

#[derive(Debug, PartialEq, Eq)]
pub enum Enforcement {
    /// Everything we asked for is enforced by the kernel.
    Full,
    /// Some access rights were dropped because the kernel is older.
    Partial { net_enforced: bool },
    /// Landlock is unavailable entirely.
    None,
}

impl FsPolicy {
    /// The baseline every plugin gets regardless of manifest: read+execute on
    /// the Nix store (it needs its own closure), read on /etc/oligarchy's
    /// public bits, and nothing else. Note the store is read_exec, never
    /// read_write — combined with the store being read-only anyway, this is
    /// what makes `jit=none` + noexec-writable-mounts actually hold.
    pub fn baseline(store_path: &Path) -> Self {
        FsPolicy {
            read_exec: vec![PathBuf::from("/nix/store")],
            read: vec![store_path.to_path_buf()],
            ..Default::default()
        }
    }

    pub fn allow_read(&mut self, p: impl Into<PathBuf>) -> &mut Self {
        self.read.push(p.into());
        self
    }
    pub fn allow_read_write(&mut self, p: impl Into<PathBuf>) -> &mut Self {
        self.read_write.push(p.into());
        self
    }
}

/// Apply the policy to the calling thread. Irrevocable.
///
/// On ABI >= 8 this covers every thread in the process; below that it covers
/// only the caller, so a multithreaded host must call this from each thread
/// before spawning workers, or (better) apply it in the child immediately
/// after fork and before exec.
pub fn restrict(policy: &FsPolicy) -> Result<Enforcement> {
    let abi = TARGET_ABI;
    // What the RUNNING kernel supports, which is the only thing that decides
    // whether a rule we add is actually enforced. Comparing TARGET_ABI here
    // (as the first version did) made net_available a tautology and silently
    // disabled the netns fallback on every kernel below 6.7.
    let running = running_abi();

    let mut ruleset = Ruleset::default()
        .set_compatibility(CompatLevel::BestEffort)
        .handle_access(AccessFs::from_all(abi))
        .context("handle_access(fs)")?;

    // Only ask for network handling if the running kernel can do it;
    // otherwise BestEffort would quietly drop it and we'd believe we were
    // confined when we weren't.
    // ABI derives Ord; compare the values rather than casting a non_exhaustive
    // enum to an integer.
    let net_available = running >= NET_ABI;
    if net_available {
        ruleset = ruleset
            .handle_access(AccessNet::from_all(abi))
            .context("handle_access(net)")?;
    }

    let mut created = ruleset.create().context("landlock_create_ruleset")?;

    for p in &policy.read_exec {
        created = add(created, p, AccessFs::from_read(abi))?;
    }
    for p in &policy.read {
        // from_read minus EXECUTE: data directories must not be a code source.
        let acc = AccessFs::from_read(abi) & !BitFlags::from(AccessFs::Execute);
        created = add(created, p, acc)?;
    }
    for p in &policy.read_write {
        let acc = (AccessFs::from_read(abi) | AccessFs::from_write(abi))
            & !BitFlags::from(AccessFs::Execute);
        created = add(created, p, acc)?;
    }

    if net_available && !policy.allow_all_tcp {
        for port in &policy.tcp_connect {
            created = created
                .add_rule(NetPort::new(*port, AccessNet::ConnectTcp))
                .with_context(|| format!("landlock allow connect :{port}"))?;
        }
        for port in &policy.tcp_bind {
            created = created
                .add_rule(NetPort::new(*port, AccessNet::BindTcp))
                .with_context(|| format!("landlock allow bind :{port}"))?;
        }
        // No rules added => all TCP denied. That is the intent for
        // `network = false`.
    }

    let status = created.restrict_self().context("landlock_restrict_self")?;

    Ok(match status.ruleset {
        RulesetStatus::FullyEnforced => Enforcement::Full,
        RulesetStatus::PartiallyEnforced => Enforcement::Partial {
            net_enforced: net_available,
        },
        RulesetStatus::NotEnforced => Enforcement::None,
    })
}

fn add(
    rs: landlock::RulesetCreated,
    path: &Path,
    access: BitFlags<AccessFs>,
) -> Result<landlock::RulesetCreated> {
    // A missing path is a manifest bug, not a reason to fall open. We create
    // state dirs ahead of time in the caller; anything still missing here
    // means the plugin asked for something that does not exist.
    let fd = PathFd::new(path).with_context(|| format!("landlock open {}", path.display()))?;
    rs.add_rule(PathBeneath::new(fd, access))
        .with_context(|| format!("landlock rule for {}", path.display()))
}

/// Report what the running kernel supports, for `plugind doctor`.
pub fn probe() -> String {
    match running_abi() {
        ABI::Unsupported => "landlock: UNSUPPORTED (kernel < 5.13 or disabled)".into(),
        v => format!(
            "landlock: {:?} (net={}, requested={:?})",
            v,
            if v >= NET_ABI { "yes" } else { "no (falls back to netns)" },
            TARGET_ABI
        ),
    }
}
