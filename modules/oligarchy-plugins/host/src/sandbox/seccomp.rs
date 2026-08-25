//! The conditional W^X filter.
//!
//! This is the piece that makes "sandbox AND JIT" tractable instead of
//! contradictory. It reimplements systemd's `MemoryDenyWriteExecute=yes`
//! in-process so we can decide per-plugin, at load time, from the manifest —
//! and so we can close the hole systemd leaves open.
//!
//! What systemd's MDWE actually blocks:
//!     mmap(prot & (PROT_WRITE|PROT_EXEC) == both)
//!     mprotect(prot & PROT_EXEC)
//!     pkey_mprotect(prot & PROT_EXEC)
//!     shmat(shmflg & SHM_EXEC)
//!
//! What it does NOT block, and therefore what any JIT can use to walk right
//! through it (Drepper's dual-mapping):
//!     fd = memfd_create(...); ftruncate(fd, n);
//!     rw = mmap(PROT_READ|PROT_WRITE, MAP_SHARED, fd);   // write code here
//!     rx = mmap(PROT_READ|PROT_EXEC,  MAP_SHARED, fd);   // execute here
//! Neither mapping is ever simultaneously W and X, so the filter never fires.
//!
//! That is a bypass if you wanted W^X, and an *escape hatch* if you wanted a
//! JIT. We use it deliberately, in both directions:
//!
//!   jit = none | host  -> install the filter AND deny memfd_create AND
//!                         require that every writable mount is noexec.
//!                         (systemd#11473 argues MDWE should do the memfd
//!                         part itself; it doesn't, so we do.)
//!   jit = self         -> do not install the filter. Permit PROT_EXEC and
//!                         memfd_create. Compensate by tightening everything
//!                         else: Landlock down to the plugin's own dirs,
//!                         no network, hard cgroup caps, NoNewPrivileges.
//!                         If the plugin is also untrusted, manifest
//!                         validation has already forced it to tier=microvm,
//!                         so the W+X pages live in a disposable guest kernel.
//!
//! Also blocked unconditionally regardless of jit mode: `personality`, because
//! READ_IMPLIES_EXEC turns every readable page executable and makes the whole
//! filter theatre.

use anyhow::{Context, Result};
use seccompiler::{
    BpfProgram, SeccompAction, SeccompCmpArgLen as ArgLen, SeccompCmpOp as Op, SeccompCondition,
    SeccompFilter, SeccompRule, TargetArch,
};
use std::collections::BTreeMap;

use crate::manifest::Manifest;

const PROT_WRITE: u64 = 0x2;
const PROT_EXEC: u64 = 0x4;
const SHM_EXEC: u64 = 0o100000;

#[cfg(target_arch = "x86_64")]
const ARCH: TargetArch = TargetArch::x86_64;
#[cfg(target_arch = "aarch64")]
const ARCH: TargetArch = TargetArch::aarch64;
#[cfg(not(any(target_arch = "x86_64", target_arch = "aarch64")))]
compile_error!("seccompiler supports x86_64 and aarch64; this design assumes one of them");

/// Build the syscall policy for one plugin.
///
/// Deliberately a *denylist over an allow-by-default base*, not a full
/// allowlist. A full allowlist for arbitrary third-party native DSP code is
/// unmaintainable — every new libc version breaks it — and the actual
/// confinement here comes from Landlock (filesystem, network) and the
/// namespaces, not from syscall enumeration. Seccomp's job in this design is
/// narrow and specific: govern executable memory.
pub fn build(m: &Manifest) -> Result<BpfProgram> {
    let mut rules: BTreeMap<i64, Vec<SeccompRule>> = BTreeMap::new();

    // Always: no personality games.
    // READ_IMPLIES_EXEC (0x0400000) would defeat everything below.
    rules.insert(
        libc::SYS_personality,
        vec![SeccompRule::new(vec![SeccompCondition::new(
            0,
            ArgLen::Qword,
            Op::MaskedEq(0x0400_0000),
            0x0400_0000,
        )?])?],
    );

    if !m.wx_enforced() {
        tracing::warn!(
            plugin = %m.id,
            tier = ?m.tier,
            "W^X filter NOT installed. Executable-memory confinement for \
             this unit is delegated to {}.",
            match m.tier {
                crate::manifest::Tier::Wasm =>
                    "wasmtime: the host must be able to mprotect(PROT_EXEC) to \
                     publish Cranelift output, and the guest never asks the \
                     kernel for anything",
                _ => "Landlock + cgroups + namespaces (manifest declares jit=self)",
            }
        );
    } else {
        // mmap: deny only when BOTH write and exec are requested, matching
        // systemd. A plain PROT_EXEC mmap of a file is how dlopen works and
        // must keep working.
        rules.insert(
            libc::SYS_mmap,
            vec![SeccompRule::new(vec![SeccompCondition::new(
                2,
                ArgLen::Dword,
                Op::MaskedEq(PROT_WRITE | PROT_EXEC),
                PROT_WRITE | PROT_EXEC,
            )?])?],
        );

        // mprotect / pkey_mprotect: deny any upgrade to executable. This is
        // the one that actually stops a JIT, and the one that breaks
        // PCRE-JIT, LuaJIT, V8 and .NET when applied indiscriminately.
        for syscall in [libc::SYS_mprotect, libc::SYS_pkey_mprotect] {
            rules.insert(
                syscall,
                vec![SeccompRule::new(vec![SeccompCondition::new(
                    2,
                    ArgLen::Dword,
                    Op::MaskedEq(PROT_EXEC),
                    PROT_EXEC,
                )?])?],
            );
        }

        // shmat(SHM_EXEC): the SysV route to the same place.
        rules.insert(
            libc::SYS_shmat,
            vec![SeccompRule::new(vec![SeccompCondition::new(
                2,
                ArgLen::Dword,
                Op::MaskedEq(SHM_EXEC),
                SHM_EXEC,
            )?])?],
        );

        // Close the dual-mapping hole. Unconditional: there is no legitimate
        // use of memfd_create in a non-JIT plugin that can't be served by a
        // regular file in $STATE.
        rules.insert(libc::SYS_memfd_create, vec![]);
    }

    let filter = SeccompFilter::new(
        rules,
        // No rule matched -> allow. Confinement lives in Landlock/netns.
        SeccompAction::Allow,
        // Rule matched -> EPERM, not KillProcess. A JIT that gets EPERM on
        // mprotect usually falls back to its interpreter and logs; a killed
        // process just looks like a mysterious crash at 3am.
        SeccompAction::Errno(libc::EPERM as u32),
        ARCH,
    )
    .context("assembling seccomp filter")?;

    filter.try_into().context("compiling seccomp BPF")
}

/// Install into the current thread. Must be called AFTER the last fork and
/// AFTER PR_SET_NO_NEW_PRIVS, and is irrevocable.
pub fn apply(prog: &BpfProgram) -> Result<()> {
    seccompiler::apply_filter(prog).context("seccomp_load")?;
    Ok(())
}

/// Self-test used by `plugind verify`. Attempts precisely the thing the
/// filter is supposed to stop, in a forked child, and reports whether the
/// kernel agreed with us. Run this in CI on every kernel bump — the failure
/// mode of a silently-ineffective seccomp filter is invisible.
#[cfg(target_os = "linux")]
pub fn selftest_wx_denied() -> Result<bool> {
    use nix::sys::wait::{waitpid, WaitStatus};
    use nix::unistd::{fork, ForkResult};

    match unsafe { fork() }.context("fork for seccomp selftest")? {
        ForkResult::Child => {
            let denied = unsafe {
                let len = 4096;
                let p = libc::mmap(
                    std::ptr::null_mut(),
                    len,
                    libc::PROT_READ | libc::PROT_WRITE,
                    libc::MAP_PRIVATE | libc::MAP_ANONYMOUS,
                    -1,
                    0,
                );
                if p == libc::MAP_FAILED {
                    false
                } else {
                    libc::mprotect(p, len, libc::PROT_READ | libc::PROT_EXEC) != 0
                        && *libc::__errno_location() == libc::EPERM
                }
            };
            // _exit, not process::exit: this is a forked child of a
            // multithreaded process, so running atexit handlers and Rust
            // destructors here is unsound.
            unsafe { libc::_exit(if denied { 0 } else { 1 }) };
        }
        ForkResult::Parent { child } => match waitpid(child, None)? {
            WaitStatus::Exited(_, 0) => Ok(true),
            _ => Ok(false),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::manifest::{Caps, Jit, Manifest, Tier, Trust};

    fn m(jit: Jit, tier: Tier) -> Manifest {
        Manifest {
            id: "t".into(),
            version: "1".into(),
            tier,
            jit,
            trust: Trust::FirstParty,
            entry: "x".into(),
            abi: crate::manifest::SUPPORTED_ABI.into(),
            caps: Caps::default(),
            meta: Default::default(),
        }
    }

    #[test]
    fn self_jit_program_is_smaller() {
        // The jit=self program carries only the personality rule; the
        // hardened one carries five more syscalls' worth of BPF.
        let permissive = build(&m(Jit::SelfJit, Tier::Native)).unwrap();
        let hardened = build(&m(Jit::None, Tier::Native)).unwrap();
        assert!(hardened.len() > permissive.len());
    }

    #[test]
    fn wasm_tier_is_never_wx_filtered() {
        // Regression test for the bug this nearly shipped with: filtering
        // mprotect(PROT_EXEC) on a Tier 0 unit does not harden the guest, it
        // just stops Cranelift compiling and breaks Tier 0 silently.
        let wasm = build(&m(Jit::Host, Tier::Wasm)).unwrap();
        let permissive = build(&m(Jit::SelfJit, Tier::Native)).unwrap();
        assert_eq!(wasm.len(), permissive.len());
    }

    #[test]
    fn microvm_host_side_is_hardened() {
        // Nothing JITs on the host side of a microvm plugin, so it keeps the
        // full filter even though the guest is a self-JIT.
        assert!(m(Jit::SelfJit, Tier::Microvm).wx_enforced());
    }
}
