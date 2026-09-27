# Exsecutor-to-Kernel: Architecture and Feasibility of a Kernel-Enforced Agent Sandbox on Oligarchy NixOS

## Scope

This document assesses a design in which:

- host enforcement logic runs at ring 0 (the kernel),
- agents run at a privilege layer strictly below the host kernel and structurally separate from host userspace,
- Exsecutor serves as both the policy/enforcement language and the implementation language for kernel-side components,
- the target is x86-64 first, with portability to RISC-V and AArch64 considered,
- NixOS modules (Oligarchy) are bound to kernel-enforced privilege constraints.

No schedule or effort estimates are given. Sequencing is expressed as dependency order.

Claims about **this** repository are bound by Truthgate and fail the docs gate when
the tree stops matching them. Claims about Exsecutor are **not** — that tree is not
checked out here — and are pinned by commit instead. See *Verification status*.

---

## Summary of findings

1. Literal x86 CPL 1 does not provide the requested property. On x86-64, rings 0–2 are all "supervisor" for paging purposes, and long mode removed the segment limits that once separated them. The only published 64-bit construction forces the intermediate ring into 32-bit compatibility mode using LDT call gates — a mechanism the Linux Kernel Self-Protection Project recommends compiling out, and which conflicts with SMAP.

2. The privilege layering that does deliver the requested property is VMX/SVM root versus non-root. The host kernel and enforcer occupy VMX-root ring 0; each agent occupies a KVM microVM in non-root mode. The agent never issues a host syscall; only the confined VMM does.

3. SEV-SNP VMPLs are the only genuinely ring-like nested privilege hierarchy on current x86 hardware. They require EPYC-class silicon — **measured absent on this machine** — and their threat model assumes an untrusted hypervisor, which is the inverse of this design's trust assumptions.

4. **Exsecutor's C backend is the viable route into the kernel, and the obstacles are in the language, not the toolchain.** Emitting C compiled by Kbuild inherits the kernel's codegen and hardening requirements without writing a kernel-grade native backend, and the emitted unit's entire import surface is already `{exsrt_abortus}` plus `memcpy`/`memset`. What blocks Phase 1 is six language, spec and C-backend items — an unconditional float/SIMD prologue, unbounded stack frames, a `_Noreturn` trap ABI that cannot return a verdict, module-scope constant data that traps, an untested FFI, and a capability atom set with no kernel-side authority in it. None of those is a Kbuild flag. They are gathered into Phase 0.5.

5. **The licensing conflict does not arise on the C-backend path.** Exsecutor is GPL-3.0-or-later and GPLv3 code cannot be linked into the GPL-2.0-only kernel — but `--emitte c` is library mode: no entry point, no runtime, no ARC, and no prelude bytes in the output. Exception A covers emitted C explicitly. The remedy is to write the one imported symbol yourself in kernel C, not to relicense anything. The action that *is* needed before code is an inbound licensing policy, because there is none.

6. The Nix store cannot be sealed wholesale. Seal the booted system closure with dm-verity and a signed UKI; deny execute to the mutable store. **The build-and-verify half of this already exists in this repository** for the captive-portal guest and should be reused rather than rewritten.

7. **Order the work by value, not by depth.** The build-time policy compiler — one declaration lowering to IPE policy, Landlock rulesets and seccomp filters — is buildable today and its consumers already exist here. The ring-0 enforcer is the last tier, not the foundation.

---

## Measured starting point

Taken on the target machine (Framework 16, Ryzen 7 7840HS, kernel 7.0.10-zen1) rather than assumed:

| property | result | consequence |
|---|---|---|
| `sev`, `sev_es`, `sev_snp` in `/proc/cpuinfo` | all absent | Phase 3b is unreachable on this hardware |
| `ibt` in `/proc/cpuinfo`, with `CONFIG_X86_KERNEL_IBT=y` | flag absent, config on | kernel IBT is inert; kCFI is the forward-edge story |
| `user_shstk`, `CONFIG_X86_USER_SHADOW_STACK` | present | user shadow stacks are available |
| `CONFIG_CFI_CLANG` | symbol not present at all | the running kernel is GCC-built; Phase 0's Clang switch is a real change |
| `CONFIG_RANDSTRUCT_NONE` | `y` | KSPP's `RANDSTRUCT_FULL` is not in effect |
| `CONFIG_SECURITY_IPE` | not set | IPE is not merely unconfigured, it is not compiled in |
| `/sys/kernel/security/lsm` | `capability,landlock,yama,bpf` | no lockdown, no IPE, no AppArmor active |

---

## A. Ring semantics on x86-64

### What rings 1 and 2 actually provide

- **Paging distinguishes only user from supervisor.** The page table U/S bit has two states. Rings 0, 1 and 2 are all supervisor. A ring-1 process can therefore read and write kernel pages unless some other mechanism intervenes.
- **Long mode removed segmentation enforcement.** In 64-bit mode, base and limit are ignored for CS, DS, ES and SS. Only FS and GS retain bases, and those exist for thread-local storage. A 2002 LKML RFC for multi-ring userspace on Linux had to reintroduce segment limits to restore protection, which only works in 32-bit mode.
- **Privileged instructions remain ring-0-only.** Ring 1 gains no useful capability over ring 3 in this respect.

### The published 64-bit construction

The LOTRx86 work (KAIST, arXiv:1805.11912) builds an intermediate "PrivUser" layer by placing ring 1 as a 64-bit gate and forcing ring 2 into 32-bit compatibility mode, where segmentation is enforced again, connected by custom LDT call gates.

Disqualifying properties for this design:

- the intermediate layer is confined to a 32-bit address space;
- SMAP breaks the shared argument page;
- the design protects secrets *from* userspace, and explicitly does not hold up against a compromised kernel.

### Architectural direction

- Intel's X86S proposal listed removal of rings 1 and 2 and of gate-based segmentation. Intel has since stated it is not pursuing X86S, but no vendor is investing in these rings.
- FRED, the replacement event-delivery architecture, is defined around ring 3 and ring 0 transitions only.
- Mainstream operating systems use rings 0 and 3. OS/2 and NetWare were the historical exceptions.
- KSPP recommends `# CONFIG_MODIFY_LDT_SYSCALL is not set`, which forecloses the LDT call-gate approach on a hardened kernel. Note the running kernel here has it **set**, so this is a change Phase 0 makes, not a property it inherits.

### Isolation mechanisms that satisfy the intent

| Option | Mechanism | Enforcer isolated from agent | Fidelity to "ring below kernel" | Principal cost |
|---|---|---|---|---|
| KVM microVM (Firecracker, Cloud Hypervisor, crosvm) | VMX/SVM root vs non-root, EPT/NPT, IOMMU | Strong: guest, VMM, jailer and host LSM must all fail | High | Host kernel and KVM remain in the TCB |
| pKVM-style deprivileged host | Minimal hypervisor; host kernel itself deprivileged | Strongest: a compromised host kernel cannot reach the enforcer | Very high | An arm64 feature; protected guests remain experimental upstream; no x86 equivalent |
| Separate hypervisor / microkernel VMM (Bareflank, NOVA/Hedron, seL4, Xen) | Distinct hypervisor TCB | Strong; formally verified in seL4's case | High | Abandons "Linux fork as enforcer"; two platforms to maintain |
| SEV-SNP VMPLs | VMPL0–3 inside one guest, RMP-enforced per-level page permissions | Strong between levels, hardware-enforced | Highest | EPYC-only — **absent on this machine**; enforcer lives inside the guest; threat model assumes untrusted hypervisor |
| TDX partitioning / SGX | TD partitions / enclaves | TDX strong; SGX inverted (protects enclave from OS) | Medium / low | Server silicon; SGX deprecated on client parts |
| Software layering only (seccomp, Landlock, LSM, namespaces, gVisor, Wasm) | Filtered syscall surface on a shared kernel | Only as strong as the shared kernel | Low | One kernel bug yields full compromise |

In the SVSM model, VMPL0 is the highest privilege level within the guest; the SVSM runs there while other guest software runs at VMPL1 or lower, and certain RMP operations become architecturally unavailable to the lower levels.

**Recommended mapping.** Host enforcer in VMX-root ring 0; agent guest kernel in non-root ring 0; agent processes in non-root ring 3. Retain software layering (seccomp, Landlock, cgroups, namespaces) around the VMM and inside the guest as defence in depth — this is also what Firecracker's own security model requires. Treat SEV-SNP VMPLs and pKVM as optional stronger tiers on hardware that supports them, which this machine does not.

---

## B. Adding a second implementation language to the kernel

### Rust-for-Linux mechanics

- C headers pass through `bindgen` to an unsafe `bindings` crate; `rust/helpers/` covers inline functions and macros; the `kernel` crate wraps these in reviewed safe abstractions, and drivers use only the abstractions. Direct use of raw bindings from drivers is explicitly disallowed by the documentation.
- The `kernel` crate already contains an LSM abstraction module, which is direct precedent for a security-side integration.
- `bindgen` depends on libclang, which couples the second language tightly to `LLVM=1` builds.
- `init/Kconfig` records the accumulated constraints: kCFI integer normalisation (`CFI_ICALL_NORMALIZE_INTEGERS`), BTF/pahole and LTO interactions, KASAN requiring Clang, and historically RANDSTRUCT incompatibility (since addressed for Clang-native randstruct, because bindgen inherits the layout information through libclang).
- Scope in practice: Rust is concentrated in drivers and abstraction layers. Core mm, scheduler, VFS core, most networking and all arch code remain C.
- Governance mattered as much as engineering. Adoption was contested, a lead maintainer resigned over non-technical friction, and the "experimental" designation was only dropped after years of in-tree presence. As of the kernel's own accounting, Rust remains a small fraction of total kernel source.

### Transferable lessons

1. **Never hand-maintain kernel struct layouts.** RANDSTRUCT, config-dependent fields and packed attributes make any duplicated layout wrong. Exsecutor's packed-by-default structs are acceptable for its own types; all kernel struct access must go through generated C accessors.
2. **The long pole is toolchain compatibility**, not code generation: CFI type hashes, BTF, KASAN, LTO.
3. **An abstraction policy is a social and safety contract.** The Exsecutor analogue is its capability system — but see B.4 below: the atom set contains no kernel-side authority today, and adding it is a specification amendment under that project's own governance, not a module someone writes.

### What the emitted C already gives you

This is stronger than a feasibility argument, because it has been measured on a real freestanding cross-toolchain rather than reasoned about:

- **The import surface is one symbol.** A library-mode unit imports `_Noreturn void exsrt_abortus(unsigned kind);` and nothing else, plus `memcpy` or `memset` depending on flags. Both of the latter exist in the kernel.
- **It compiles clean freestanding.** The StreamDB reader emitted for the N64 row builds under `mips64-elf-gcc -Os -Wall -Wextra -Werror -ffreestanding` with zero diagnostics, 14,616 bytes, `nm -u` exactly `{exsrt_abortus, memset}`, and **zero FP-register references**.
- **It runs.** That unit was linked into a Nintendo 64 ROM, executed on a 32 KB libdragon thread, and agreed key-for-key with an independent C reader on the same container.
- **It is UB-free by construction** — no signed arithmetic that can overflow, no signed shift, no promotion of a byte into `int`, no shift by the type's width, no C bitfield, no dependence on the host's byte order — and that was *measured* big-endian, not argued.
- **The correctness oracle is real.** The differential phase holds floors of 184 IR fixtures and 56 program directories / 224 builds, each built under both gcc and clang at `-O0` and `-O2` with `-fsanitize=undefined -fno-sanitize-recover=all`, compared on stdout bytes, exit status and trap-or-not.
- **The build is reproducible.** `make reproduce` diffs builds across divergent cwd, `TZ`, locale, `SOURCE_DATE_EPOCH`, umask and hostname — the property a sealed, signed policy artifact needs.

The shape that produced all of the above — emitted library-mode C plus a small hand-written host shim supplying `exsrt_abortus` — is already the kernel-module shape, and has been done three times (N64 ROM, bare Thumb firmware, amdgcn dispatch).

### Requirements for kernel-targeted Exsecutor output

| Requirement | Reason | Status via C backend in Kbuild |
|---|---|---|
| Freestanding relocatable ELF, no libc or runtime | Kernel links `.o` into `.ko`/vmlinux | **Met.** Library mode emits a definition per function, no entry point, no runtime |
| No floating point or SIMD | FPU state is not saved outside `kernel_fpu_begin` | **Not met — see B.1.** The emitted prologue carries float and vector declarations unconditionally |
| No red zone | Interrupts clobber below `rsp` | Integrator passes `-mno-red-zone`; nothing in the Exsecutor tree considers it |
| `-mcmodel=kernel` addressing | Kernel maps into the top 2 GB | Provided by Kbuild |
| Bounded stack frames | Kernel stacks are 16 KB with a guard page | **Not met — see B.2.** There is no frame-size cap and no stack probe |
| Traps mapped to errors | A kernel `ud2` becomes an oops | **Not expressible — see B.3.** The trap hook is `_Noreturn` |
| Calls into kernel APIs | An LSM must call the kernel | **Untested — see B.5.** No running program uses `externus` |
| Retpolines, return thunks, SLS mitigation | Spectre-v2 class mitigations | Provided by kernel flags |
| IBT `endbr64` and kCFI preambles | `CONFIG_X86_KERNEL_IBT`, `CONFIG_CFI_CLANG` | Provided by Clang |
| ORC unwind data | Stack traces, livepatch | Generated by objtool |
| objtool validation (noinstr, uaccess, stack) | Build fails otherwise | Provided |
| Kernel sections (`.init.text`, `__ksymtab`, `.modinfo`, `__ex_table`) | Module loader, exception fixups | Via C macros |

#### B.1 The prologue brings floats and SIMD into every unit

`prologue.c.in` is emitted verbatim into **every** translation unit, ungated on whether the module uses floats: `<stdint.h>`, `<limits.h>`, `<float.h>`, hard `#error`s on `__FAST_MATH__` and `__FINITE_MATH_ONLY__`, a battery of `_Static_assert`s on `FLT_RADIX` / `FLT_MANT_DIG` / `FLT_EVAL_METHOD`, and six `__attribute__((vector_size(...)))` typedefs up to 64 bytes plus static-inline float and vector helpers.

A kernel object built `-mno-sse` or `-mgeneral-regs-only` therefore collides with the prologue before it reaches any of your code. There is exact precedent for the collision: ADR 0015 records libdragon's `n64.mk` setting `-ffast-math` globally and the prologue answering with two `#error`s. The fix used there — compile the Exsecutor TU with its own flags — **does not transfer**, because you cannot hand a single Kbuild object a private `-msse`. Gating the prologue on float use is a C-backend change.

#### B.2 Stack frames do not fit a kernel stack

A kernel task gets 16 KB with a guard page. The only Exsecutor program whose frame has been measured is the StreamDB reader's `arbor_percurre`: **127,184 bytes**, brought to **20,680** by ADR 0016's `&mutabilis` borrow plus in-place struct-literal arrays. The optimised figure is still above a kernel stack.

There is also no bound to lean on. A large local array is bounded only by the process stack; `[0; 2000000]` of `i64` is a SIGSEGV with no diagnostic, because the emitter has no stack probe. In a kernel the same defect is a guard-page double fault. Value semantics plus reference counting, with no borrow checker, is what drives frames this large — it is structural, not an oversight.

#### B.3 The trap ABI cannot fail closed

Every overflow and bounds check calls `exsrt_abortus`, and its prototype is `_Noreturn`. The kernel has no `longjmp`. "Fail closed" in an LSM means **returning** `-EPERM`, which a `_Noreturn` callee cannot do. The options are a provably trap-free evaluator, a trap that panics the machine, or a specification change to a returning error path. This is a spec item, not an integration detail.

#### B.4 No memory model, and no kernel authority in the capability atoms

Two separate gaps, both in the language:

- **Concurrency.** `Filum` (threads) is a capability atom with no implementation; `refero<T>` is non-atomic by design and cannot cross `externus`. There are no atomics and no memory model. An LSM hook runs concurrently on every CPU, in atomic context, under RCU. This is the strongest argument for the pure-function, allocation-free, table-walk shape this document already recommends — it should be stated as the reason for that shape rather than as a risk to be managed later.
- **Authority.** The atom set is `Mundus alloc sermo horologium archivum rete fortuna ambitus Filum machina Crudum` — all process-level. None models a `struct file *`, an LSM hook's credentials, or an RCU read-side section. A "kernel `Mundus`" is therefore an amendment to the capability section of the specification plus new diagnostic codes, under that project's ADR and root-coinage process, which forbids inventing a code without amending the spec first.

#### B.5 The FFI has never been exercised

The only Exsecutor source file in the tree containing `externus` is a *rejection* fixture. The foreign-function path exists in the checker and the emitter; no running program uses it. Since an LSM must call kernel functions, Phase 1's real first milestone is making `externus` work against a live C ABI — something the project has not yet done once.

#### B.6 One translation unit per invocation

Library mode emits one TU per invocation and there is no module system; whole-program mode is open and unscheduled. Up to 256 source files form a single compilation unit, which is adequate for one self-contained LSM and fatal for anything wanting separate compilation.

**Assessment of backend options.**

- *C backend inside Kbuild.* Add a kernel host target emitting `.c` compiled with the kernel's own flags. Exsecutor's semantics (bounds checks, trapping arithmetic, capability rows) are enforced before emission; the C compiler handles ABI and hardening details. The differential and UBSan phases described above serve as the correctness oracle. **This is the route.**
- *LLVM IR backend.* Would yield `LLVM=1` participation, ThinLTO, cross-language inlining and exact kCFI parity. Worth wanting — but note this is adding a Stage-5 item to a project whose own specification places the implementation between Stages 2 and 3 of five, lists "LLVM for release" exactly once as a Stage-5 line, and says plainly "Do not write an optimizing backend." Treat it as a later credibility path, not as a choice available now.
- *Native kernel-grade backend.* Reimplements a decade of hardening codegen; not recommended. Note the existing reference backend does not emit object code either — it emits fasmg assembly source text, which fasmg then assembles.

**Realistic surface.** Out-of-tree modules first, then one LSM. Exsecutor's current proven surface — pure functions, caller-owned buffers, no allocation in any running program — matches a policy decision function of the form `(subject, object, operation, context) → verdict`. Core subsystems (mm, sched, VFS) are not candidates.

---

## C. The ring-0 enforcer

### Components to compose

- **LSM framework.** Hooks including `bprm_check_security`, `file_open`, `mmap_file`, `socket_connect`, `bpf` and `kernel_read_file` dispatch to every stacked module; the most restrictive verdict wins. Modern kernels support stacking multiple major LSMs, ordered by the `lsm=` parameter.
- **IPE (Integrity Policy Enforcement), merged in 6.12.** Evaluates immutable properties rather than labels or paths: initramfs provenance (`boot_verified`), dm-verity root hash and signature, fs-verity digest and signature. IPE's design rationale favours dm-verity because one signature covers an entire block device and verification happens as blocks are read. Policy update rules: version must be non-decreasing, the active policy cannot be deleted, writes require `CAP_MAC_ADMIN`, and a boot policy can be compiled in. IPE targets fixed-function systems, which a sealed NixOS generation approximates.

  **IPE is further away than a name in an option list suggests.** On the pinned nixpkgs there is no NixOS IPE module, and nixpkgs' kernel `common-config.nix` sets no `SECURITY_IPE`; the running kernel here does not have it compiled in. `security.lsm = [ … "ipe" … ]` is a legal string with nothing behind it. IPE requires a kernel configuration change *and* policy plumbing written from scratch in this repository. Track stable backports when it does land: 2026 fixes addressed use-after-free issues in its policy-audit and dm-verity metadata paths.
- **Landlock.** Unprivileged, stackable filesystem and TCP rulesets a process applies to itself. Already used here, from userspace — see D.
- **BPF LSM.** Verified eBPF programs attached to LSM hooks; the verifier guarantees termination and memory safety, not policy correctness.
- **Lockdown, module signing, LoadPin, IMA/EVM.** `CONFIG_SECURITY_LOCKDOWN_LSM_EARLY` with `MODULE_SIG_FORCE` and LoadPin restricts kernel-read-file to the verified root; IMA provides TPM measurement for attestation.
- **KSPP baseline.** `INIT_ON_ALLOC_DEFAULT_ON`, `INIT_ON_FREE_DEFAULT_ON`, `X86_KERNEL_IBT`, `X86_USER_SHADOW_STACK`, `CFI_CLANG` without `CFI_PERMISSIVE`, `MITIGATION_SLS`, `HARDENED_USERCOPY`, `RANDSTRUCT_FULL`, strict IOMMU by default, `MODIFY_LDT_SYSCALL` disabled. The *Measured starting point* table above says which of these hold today; several do not.

Hardware note: kernel IBT is inert here because the CPU lacks the feature even though the config enables it, so kCFI carries forward-edge CFI and user shadow stacks are available. LKRG is an out-of-tree integrity tripwire, not a boundary. STACKLEAK's compiler-plugin status should be checked against the chosen toolchain, since kCFI implies Clang.

### Exsecutor policy as a sealed kernel artifact

The pipeline mirrors eBPF (compile → verify → attach), with verification moved to build time.

1. **Authoring.** A NixOS module declares an agent's authority. On naming, see C.3: this belongs under `custom.*`, and most likely as an extension of the plugin capability submodule rather than a new option root.
2. **Checking.** The checker rejects any rule granting authority not derived from the declared root. **What performs that check does not exist yet** — see C.1.
3. **Emission to three consumers.**
   - IPE policy text for execution and integrity rules (default deny; allow execute on `boot_verified` or a named dm-verity root hash), signed per IPE's update path.
   - Landlock rulesets and seccomp filters for the VMM and in-guest processes.
   - A flat, bounded, integer-indexed decision table consumed by the Exsecutor LSM. Because the evaluator is a pure function without allocation or unbounded loops, it is also a candidate for `clang -target bpf`, making the in-kernel BPF verifier a second independent check.

   The arithmetic this needs is available: bitwise and/or/xor and both shift forms lower in the C backend today. What remains refused — integer division and remainder, signed multiply, the overflow predicates, `fma`, `bitcast`, unordered float compares, the reductions and indirect calls — a bounded table walk does not use. **The obstacle is not arithmetic; it is B.1 through B.5.** Note also that a module-scope array literal type-checks and then traps in the lowering, which is precisely the shape of a static table; the documented workaround returns the literal from a function, which builds it on the stack and lands back in B.2.
4. **Sealing.** The table is compiled into the kernel image or initramfs, covered by the UKI signature and IPE `boot_verified`, and resident in `__ro_after_init` memory. The securityfs interface accepts only updates that are signed, carry a higher version, and are strictly narrower — monotonic attenuation verified in-kernel by table comparison. Combine with lockdown in integrity mode, BPF-LSM loading restricted to the enforcer's own pinned programs, and a module-signing key held only in the build sandbox.

**Static LSM versus BPF LSM.** BPF LSM is the faster prototype, but BPF programs can be detached by a sufficiently privileged process unless lockdown and the enforcer's own `bpf` hook prevent it. A static LSM registered at boot cannot be unloaded, which is the property this design requires.

#### C.1 There is no rule checker today, and three different things get mistaken for one

An earlier draft of this document said the compiler would reject over-broad rules "using the same capability-row checker that audits compiler syscalls". Those are three unrelated artifacts:

- the **capability-row checker** is assembly inside the compiler and checks Exsecutor source against declared capability clauses. It is partly built, and the project's own design notes record it wrongly refusing a correct program;
- the **syscall audit** is a shell script with embedded Python that disassembles the built compiler binary against a closed nine-syscall allowlist. It shares no code with the checker, and its capability-to-syscall mapping is a table inside the script;
- the **capability prototype** under `prototypes/` is the policy-shaped one. It is a Python prototype that the project states is never shipped and never on the build closure.

None is a rule checker over a policy language. The transitive-closure capability audit the specification describes is designed and not built. Separately, the emitted capability mask is a documented over-approximation — every binding binary carries `read` whether it reads or not — so it cannot be cited as a tight bound.

#### C.2 Securing the Nix store — the verity half already exists here

`/nix/store` is content-addressed in principle but mutable in practice — `nix-daemon` adds paths and garbage collection removes them — while dm-verity requires a read-only block device. Split the trust domains:

- **Sealed system closure.** Build the generation's closure as an EROFS or squashfs image with a dm-verity hash tree; embed the root hash on the kernel command line inside a lanzaboote-signed UKI; mount it at `/nix/store` or overlay it with a writable store. IPE permits execute only from `boot_verified` or that root hash. TPM PCR policy ties disk unlock to the measured UKI.
- **Mutable store** (dev shells, agent builds). No IPE rule grants it execute. Optionally enable fs-verity per path at registration with a Nix signing key so selected tools gain `fsverity_signature` execute rights — this is not stock Nix behaviour and implies carrying a nix-daemon patch.

<!-- truth:claim
id: verity-manifest
kind: file_contains
path: modules/captive-portal/vm/manifest.nix
pattern: veritysetup
-->
**Do not write the build side from scratch.** `modules/captive-portal/vm/manifest.nix`
already builds an EROFS store disk into a dm-verity image and solves the part that is
easy to get wrong: it derives the salt and UUID deterministically from the disk's own
sha256, because `veritysetup` randomises both and a reproducible root hash is the whole
point; it asserts the image is a whole number of 4096-byte blocks; it re-verifies at
build time; and it emits a manifest whose own sha256 is baked into the launcher.
<!-- truth:end -->

<!-- truth:claim
id: verity-guest
kind: file_exists
path: modules/captive-portal/vm/guest.nix
-->
The verify side is `modules/captive-portal/vm/guest.nix`, which attaches the tree from a
systemd initrd unit that refuses to boot unless the command line carries 64 hex
characters — and whose header records the constraint Phase 0 must design around: **the
root hash cannot live in the initrd, because the initrd is inside the store disk.** A
signed UKI is what replaces the guest's command line for the host case.
<!-- truth:end -->

The gate `nix build .#captive-vm-reference` re-derives the tree from the disk and
requires a byte-identical hash image, plus a real single-byte tamper test. Phase 0's
"system closure as an EROFS+dm-verity image with its root hash in the UKI" is that
pipeline pointed at the host closure.

#### C.3 Existing owners this collides with

Phase 0 touches settings that already have owners here. Each needs resolving rather than duplicating.

<!-- truth:claim
id: kernel-variant
kind: file_contains
path: modules/kernel.nix
pattern: custom.kernel.variant
-->
`modules/kernel.nix` owns kernel selection through `custom.kernel.variant` and assigns
`boot.kernelPackages` with `lib.mkForce`. A Clang/KSPP kernel must become a member of
that enum — today `zen`, `cachyos`, `cachyos-lto`, `cachyos-bore`, `xanmod`, `latest`,
`lts`, defaulting to `zen` and also driven by the persona module — not a parallel
assignment that fights the force.
<!-- truth:end -->

<!-- truth:claim
id: lsm-owner
kind: file_contains
path: modules/cpu-security.nix
pattern: security.lsm
-->
`security.lsm` has exactly one owner, `modules/cpu-security.nix`, which sets it with
`mkDefault` to `[ "landlock" "yama" "bpf" "lockdown" ]` — and it is **inert on every
shipped configuration**, because the assignment is guarded on a lockdown mode that the
`hardened` preset sets to `none`. Adding `ipe` means extending that list, not adding a
second definition. The same file already owns a `boot.kernelPatches` entry for lockdown
written in the line-oriented `extraConfig` form; this document's structured-config
approach has no users in the tree, and two owners of one Kconfig symbol in two formats
is a merge hazard.
<!-- truth:end -->

`security.lockKernelModules` is deliberately **false** on the `hardened` preset, with a written reason: it breaks module autoload. Phase 0 turning it on contradicts a recorded decision and should say why it now wins.

<!-- truth:claim
id: root-filesystem
kind: file_contains
path: modules/hardware-configuration.nix
pattern: ext4
-->
**TPM2-sealed LUKS presupposes LUKS, and this host has none.**
`modules/hardware-configuration.nix` mounts the root filesystem as plain ext4 by UUID.
Phase 0 as written silently contains "introduce full-disk encryption", which is a
reinstall, not a configuration change.
<!-- truth:end -->

<!-- truth:claim
id: secure-boot
kind: file_exists
path: modules/secure-boot.nix
-->
Secure Boot is wired but off: `modules/secure-boot.nix` declares `custom.secureBoot` over
lanzaboote and nothing enables it, while `modules/cpu-security.nix` already asserts
lanzaboote for any non-`none` lockdown mode and for the `vault` preset — so that preset
is currently unreachable. The enrollment runbook already exists at
`docs/secure-boot-enrollment.md`.
<!-- truth:end -->

#### C.4 Channel facts

<!-- truth:claim
id: nixpkgs-pin
kind: file_contains
path: flake.nix
pattern: nixos-25.11
-->
`flake.nix` pins this tree to `nixos-25.11`, and `system.stateVersion` matches. On that pin the
`hardened` profile still exists, `linux_hardened` still exists, and `security.lsm`
exists — so the 26.05 removals discussed in earlier drafts describe a channel this
repository is not on, and cost it nothing in any case: neither `linux_hardened` nor the
`hardened` profile was ever used here, and the `linuxPackages-rt` removal was absorbed
some time ago (the DSP guest moved to xanmod; ArchibaldOS runs CachyOS-RT with a musnix
fallback).
<!-- truth:end -->

The channel finding that does matter is the one earlier drafts missed: **25.11 is at end of life, and the unstable pin is roughly four months older than the stable pin.** A channel bump is itself a Phase 0 prerequisite, and it is the event that brings a NixOS IPE module within reach.

---

## D. Agent sandboxing practice

**Deployed approaches.**

- Anthropic's `sandbox-runtime` uses `sandbox-exec` on macOS and bubblewrap on Linux, with proxy-based network filtering; on Linux the network namespace is removed so all traffic traverses the proxies. Claude Code on the web isolates each session and routes git traffic through a proxy so credentials and signing keys stay outside the sandbox.
- OpenAI's Codex CLI uses bubblewrap plus seccomp by default on Linux, applying `PR_SET_NO_NEW_PRIVS` and a network syscall filter, with Landlock as a legacy fallback. A reported `sendto` denial broke Python asyncio cross-thread wakeups — a concrete illustration of the compatibility cost of coarse syscall denial.
- Firecracker underpins AWS Lambda and Fargate isolation: KVM plus a minimal Rust VMM, a jailer process and seccomp filtering. Its specification commits to bounded boot latency and per-VMM memory overhead. Some hosted sandbox vendors use gVisor instead; individual vendor stacks were not independently verified here.
- Capability systems (CHERI/Morello, seL4, Genode, Zircon handles, Capsicum) demonstrate that authority carried by unforgeable references outperforms ambient-authority filtering. Exsecutor's capability model expresses the same principle at the language level.
- CaMeL (Debenedetti et al., 2025) extracts control and data flow from the trusted query so retrieved untrusted data cannot affect program flow, and gates tool calls with capabilities; it reports solving 77% of AgentDojo tasks with provable security against 84% undefended.

**What a host kernel enforcer adds over userspace sandboxes.**

- *Syscall attack surface.* Under bubblewrap, seccomp and Landlock the agent still addresses the host kernel directly. In a microVM it addresses a guest kernel, and the host sees only the VMM's filtered syscalls.
- *Sandbox integrity.* A host LSM with a sealed policy cannot be reconfigured by a compromised agent or orchestrator.
- *Persistence.* With IPE and dm-verity, nothing the agent writes can execute on the host.

**Where microVMs remain necessary.**

- *Side channels.* Retain forced CPU mitigations; consider disabling SMT or using core scheduling for agent vCPUs.
- *DMA.* Do not pass physical devices to agent VMs; keep the IOMMU strict.
- *Compatibility.* Arbitrary toolchains require a full kernel ABI, which gVisor and Wasm provide only partially.

### D.1 Most of the isolation layer already exists in this repository

<!-- truth:claim
id: microvm-tier
kind: file_contains
path: modules/oligarchy-plugins/host/src/tiers/microvm.rs
pattern: GUEST_PORT
-->
`modules/oligarchy-plugins/host/src/tiers/microvm.rs` already implements the vsock-only
tool channel this document's agent-isolation phase proposes building: length-prefixed
postcard framing on a fixed `GUEST_PORT`, typed request and response enums, and a
connect path that handles **both** transports — the firecracker and cloud-hypervisor
userspace unix-socket handshake, and the qemu and crosvm kernel `AF_VSOCK` dial by
context id. Launch is by systemd drop-in with stop propagation to the microvm unit, on
the recorded reasoning that asking systemd to start something is privileged while
depending on it is not — which is already most of "a jailed VMM".
<!-- truth:end -->

<!-- truth:claim
id: plugin-hypervisor
kind: file_contains
path: modules/oligarchy-plugins/modules/plugins.nix
pattern: cloud-hypervisor
-->
The hypervisor is an option, not a rewrite: `modules/oligarchy-plugins/modules/plugins.nix`
offers firecracker, cloud-hypervisor, qemu and crosvm, with cloud-hypervisor the shipped
default on the primary host. Per-instance W^X is decided from a manifest field and
mirrored between the Rust host and the Nix module, with a seccomp layer that closes the
memfd dual-mapping bypass systemd's own `MemoryDenyWriteExecute` leaves, and Landlock is
ABI-probed with an escalation to an empty network namespace on kernels below ABI 4.
Five VM gates cover it.
<!-- truth:end -->

<!-- truth:claim
id: forge-sandbox
kind: file_contains
path: modules/oligarchy-forge/crates/forge-core/src/process.rs
pattern: cap-drop
-->
What is thin is the forge, which is the sandbox this document proposes replacing.
`modules/oligarchy-forge/crates/forge-core/src/process.rs` runs a container with
`--cap-drop=ALL`, no-new-privileges and a kept-id user namespace — and no network
isolation, no read-only rootfs, no seccomp profile and no resource limits. The escalation
ladder from rootless podman through gVisor to a microVM is already sketched in
`docs/oligarchy-forge-research.md`, so this direction continues an existing roadmap
rather than opening a new one.
<!-- truth:end -->

So the remaining work in that phase is **not** microVMs. It is: a policy mediator on the vsock channel, since today's host side is a plugin host rather than a decision point; an egress allowlist proxy holding credentials; and in-guest bubblewrap and Landlock, since the tier currently downgrades to native inside the guest. One structural obstacle has to be designed around rather than inherited: plugin microVMs are **declarative-only**, because a guest needs a closure. An agent sandbox created per task from a mutable workspace cannot accept that constraint unchanged.

**Design principles.**

1. Place the policy decision point outside anything model output can reach — the host LSM and a VMM-side proxy.
2. Mediate tools semantically (capabilities on values), not only at the syscall boundary.
3. Keep credentials outside the sandbox; inject scoped tokens at a proxy.
4. Default to read-only filesystem and default-deny egress via an allowlist proxy.
5. Design so that ordinary actions need no interactive approval.

---

## E. Roadmap by dependency order

Phases are ordered by prerequisite, not by schedule. Two properties are deliberate: the
language prerequisites are a phase of their own rather than risks inside Phase 1, and the
**build-time policy compiler lands before any ring-0 work**, so the thesis — one
declaration, three enforcement artifacts, checked — is delivered by a phase that needs no
kernel object, no licence question, no frame-size bound and no trap ABI.

Numbering note: `docs/security-hardening.md` already has its own Phase 0 for the security
rollout. These phases are unrelated to those.

### Phase K0 — Hardened baseline (no prerequisites)

Deliverables: a channel bump off end-of-life 25.11; Secure Boot via lanzaboote with TPM2-sealed LUKS, which implies introducing LUKS first (C.3); a Clang-built kernel added as a `custom.kernel.variant` member with a KSPP structured config; `security.lockKernelModules` and `security.protectKernelImage`, with the autoload regression answered; `ipe` added to the single existing `security.lsm` definition once a kernel carrying it exists; the system closure as an EROFS+dm-verity image built by the existing captive-portal pipeline with its root hash in the UKI; an IPE policy moved from audit to enforce; a Kconfig hardening check in CI; ArchibaldOS migrated to mainline `PREEMPT_RT`.

Risks: unbootable generations (retain a signed recovery UKI); CachyOS/BORE patchset conflicts with Clang and kCFI; out-of-tree graphics modules versus lockdown and module signing; the LUKS introduction is a reinstall.

### Phase K1 — The policy compiler (depends on K0 only for its consumers)

**This is the first phase that delivers the thesis, and it needs nothing from the kernel.** A declaration lowers, at build time, to IPE policy text, Landlock rulesets and seccomp filters. The emitter is an ordinary host tool built through the C backend; the Landlock and seccomp consumers already exist in the plugin runtime (D.1).

Deliverables: the option interface under `custom.*` — extending the plugin capability submodule rather than opening a new root (C.3); the lowering; emitted artifacts wired into the existing plugin and forge sandboxes; a gate asserting that a declaration which grants less produces artifacts that deny more.

Risks: the checker that rejects over-broad rules does not exist yet (C.1), so early versions enforce by construction of the emitter rather than by a checked property — say so in the gate rather than implying otherwise.

### Phase K2 — Exsecutor becomes kernel-eligible (depends on K1 for motivation, not code)

Six items, every one language, specification or C-backend work. Exit criteria are stated as measurements:

1. the float and vector prologue is gated on float use — an integer-only module emits a unit that compiles under `-mno-sse -mgeneral-regs-only` (B.1);
2. a frame-size bound that is a compile error rather than a fault — demonstrated by an emitted unit whose largest frame is under 4 KB by `-fstack-usage` (B.2);
3. a trap ABI that can return a verdict, or a checkable no-trap discipline — the natural home is the safety-critical profile, which is today design-only with no compiler and no profile checker (B.3);
4. module-scope constant aggregate data that lowers rather than traps (C, step 3);
5. `externus` exercised end to end against a real C ABI by a running program (B.5);
6. the capability atom set amended with kernel-side authority, plus its diagnostic codes, through that project's ADR process (B.4).

### Phase K3 — Exsecutor emits kernel objects (depends on K2)

Deliverables: a kernel host target (no float, frame-size cap, trap-to-error mapping, kernel prelude, no prelude syscalls); a Kbuild `obj-m` wrapper; a trivial out-of-tree module; then a log-only LSM exercising `bprm_check_security`.

Exit criterion, falsifiable: an emitted unit that objtool accepts and whose `nm -u` is a subset of `{exsrt_abortus, memcpy, memset}`.

Risks: reference-counting semantics in atomic context — note B.4, that there is no memory model to reason with, so the evaluator must not refcount at all; objtool warnings on emitted C; prelude licensing (see G, which concludes this does not bite on this path).

### Phase K4 — Sealed in-kernel ruleset (depends on K1 and K3)

Deliverables: a BPF LSM prototype via the C backend and `clang -target bpf`; then a static Exsecutor LSM with a sealed `__ro_after_init` table and signed monotonic updates through securityfs, consuming the same decision table K1 already emits.

Risks: policy expressiveness against BPF verifier limits; TOCTOU in path-based rules (prefer inode and verity properties); fail-closed defects causing lockout.

### Phase K5 — Agent isolation (depends on K1 for mediation policy)

**Mostly an extension of what exists** (D.1), not new microVM work. Deliverables: point the forge at the plugin tier-2 substrate instead of podman; a host-side mediator on the vsock channel applying capability checks; egress through an allowlist proxy holding credentials; in-guest bubblewrap and Landlock; and a design answer for per-task sandboxes, since the existing tier is declarative-only.

Risks: developer ergonomics and performance (GPU or ROCm access cannot safely enter agent VMs); VMM defects; the mediator accreting TCB surface.

### Phase K6 — Stronger hardware tiers (blocked on hardware)

**Not reachable on this machine** — SEV-SNP is absent from this CPU (see *Measured starting point*). On EPYC: an Exsecutor micro-enforcer at VMPL0, adapting COCONUT-SVSM concepts. On arm64: evaluate pKVM, noting that Exsecutor has no aarch64 target row and no aarch64 host (F).

### Phase K7 — Fork maintenance (continuous, begins with K3)

Deliverables: a patch queue rather than a long-lived branch, applied via `boot.kernelPatches` against the current LTS; the LSM as a self-contained directory plus a minimal hook-registration diff; kselftests and KUnit tests; nightly builds against `linux-next` to detect drift; `nixosTest` VM tests booting the sealed image.

Risks: rebase cost if core files are modified; LSM API churn; sole-reviewer risk on security-critical code — which applies not only to the LSM but to the hand-written assembly compiler that emits it.

---

## F. Portability

| Function | x86-64 | RISC-V | AArch64 |
|---|---|---|---|
| Privilege levels | CPL 0/3 (1/2 vestigial) | M / S / U modes | EL0–EL3 |
| Hypervisor layer | VMX root / SVM | H-extension (HS/VS/VU) | EL2 (VHE or nVHE) |
| Enforcer below host kernel | No mainstream x86 equivalent | M-mode firmware with PMP | pKVM at EL2 |
| Firmware-level memory isolation | — | PMP / ePMP (Smepmp) | TrustZone, RME GPT |
| Confidential VMs / nested levels | SEV-SNP VMPLs, TDX | CoVE / AP-TEE | Arm CCA Realms |
| Forward-edge CFI | IBT (Intel), kCFI | Zicfilp (`lpad`) | BTI, kCFI |
| Backward-edge CFI | CET shadow stack | Zicfiss | GCS, PAC-RET |
| Pointer integrity / tagging | — | CHERI-RISC-V (research) | PAC, MTE |
| User/supervisor access control | SMEP, SMAP | `SUM` bit, S-mode NX over U pages | PXN, PAN/EPAN |
| Context-state isolation | XSAVE controls | Smstateen | HCR/CPTR trap controls |
| Cache/QoS partitioning | RDT/CAT | Ssqosid | MPAM |
| Capability hardware | — | CHERI-RISC-V | Morello (prototype) |

RISC-V user-space CFI (`Zicfilp`/`Zicfiss`) landed in Linux 7.0; x86 and arm64 user shadow stacks were already mainline. For RISC-V the natural layout is host kernel in HS-mode, agents in VS/VU via KVM on the H-extension, with a CoVE TSM as the later VMPL0/pKVM analogue.

### F.1 What Exsecutor can actually target

The target triple set is a **closed table** of three rows, and this bounds the portability story far more tightly than the hardware table above suggests:

| `--hospes` row | address width | backends |
|---|---|---|
| `x86_64-linux` | 64 | reference and C |
| `riscv64-linux` | 64 | C only, marked untested |
| `mips64-none-o64` | 32 | C only |

`aarch64-linux`, `wasm32-wasi` and `none-eabi` are named in the specification and explicitly **not accepted**. So:

- **There is no AArch64 target.** An earlier draft's claim that aarch64 and riscv64 kernel targets are "primarily a Kbuild concern rather than a compiler one" is wrong in both directions: there is no target row, and an aarch64 *host* is a full rewrite, because the compiler is freestanding x86-64 assembly with its build platform pinned to `x86_64-linux`.
- **Adding a row is not a table entry.** The project's own record of the 32-bit row shows that changing the address width altered the emitted text pervasively.
- **Big-endian MIPS is real and load-bearing** — see B, "What the emitted C already gives you". It is the strongest existing evidence for kernel viability.
- **Cortex-M is real but narrower than it sounds.** A metronome example builds for `thumbv7em-none-eabi` (Cortex-M4) and `thumbv6m-none-eabi` (Cortex-M0+) at `-Os -ffreestanding -Werror`, links with `ld.lld` and runs under `qemu-arm`, producing roughly 8 KB firmware. But it **reuses the MIPS 32-bit-address row** rather than an ARM one; its bare path uses ARM EABI *Linux* syscalls so user-mode qemu can run it; the project marks real hardware untested; and the script is not wired into CI — it prints a skip rather than failing.

---

## G. Licensing and trademark

**Kernel fork.** Linux is GPL-2.0-only with the syscall exception note. Distributing binaries — ISOs, appliances, images — obliges you to offer corresponding source including patches and build scripts. A fully pinned Nix flake satisfies this cleanly.

**Modules.** `MODULE_LICENSE()` must declare a GPL-compatible licence or the module taints the kernel and cannot resolve `EXPORT_SYMBOL_GPL` symbols. LSM registration and most security internals are GPL-only or built-in-only. The derivative-work status of out-of-tree modules is legally unsettled, but the symbol-export mechanism and kernel developer consensus treat GPL-only symbol users as derivative. Assume the enforcer is GPL-2.0.

**Exsecutor's licence, and why the conflict does not arise on this path.** Exsecutor is GPL-3.0-or-later, which is incompatible with GPL-2.0-only. It carries **two** exceptions, not one:

- **Exception A** is automatic and covers compiler *output*. It enumerates emitted C source explicitly and permits propagating output under terms of your choosing.
- **Exception B** is a per-file, Classpath-style linking exception that applies only where a file's own header carries a designation line.

The open question in earlier drafts was whether a copied runtime prelude counts as output. **On the C-backend path the question does not arise: library mode emits no prelude.** There is no entry point, no runtime and no reference counting in the output, and the unit imports a single symbol. (The *reference* backend does copy a prelude blob verbatim into its output, and that file is plain GPL-3.0-or-later carrying no Exception B designation — the project flags this itself as open and defers it to the copyright holder. It is simply not on the kernel path.)

So the remedy is small: **write `exsrt_abortus` yourself, in kernel C, under GPL-2.0**, and mark emitted kernel units `SPDX-License-Identifier: GPL-2.0-only`. One function.

Do **not** relicense the prelude to GPL-2.0-only as an earlier draft suggested. That project chose v3 precisely because section-7 additional permissions are a v3 construct with no v2 equivalent; v2-only would strand Exception B's entire mechanism, for no benefit on a path that carries no prelude.

**The action to take before any code is written is an inbound licensing policy.** There is no DCO and no CLA, and the contributing guide states no inbound terms at all. Copyright is currently held by a single party, and that project's own licensing ADR banks on it explicitly. Relicensing ability therefore exists today and is foreclosed by the first outside contribution to the affected files. Adopt a DCO now; it costs nothing and preserves every later option.

One operational note: Exception A has no registered SPDX identifier, so licence scanners report compiler sources as plain GPL-3.0-or-later and miss the output grant. Worth knowing if emitted C ships inside a distributed image.

**Precedent.** In-tree Rust code is GPL-2.0 like the rest of the tree; rustc's own MIT/Apache-2.0 licence does not propagate to kernel code, and compiler licences do not generally attach to output. Exception A exists to make that explicit.

**Commercial use.** Selling hardened images, support, or a hosted agent sandbox is permitted. A userspace orchestrator can remain proprietary provided it interacts with the kernel only through syscalls and securityfs. Oligarchy's BSD-3 licence introduces no conflict.

**Trademark.** "Linux" is Linus Torvalds' mark, sublicensed through the Linux Foundation's mark institute. Descriptive use is normally acceptable; a product name containing "Linux" may require a sublicense, so avoid it and keep "Exsecutor-for-Linux" as a descriptive project label. "NixOS" carries its own community trademark policy.

Nothing here is legal advice; the derivative-work question and the licence exception warrant review by counsel before commercial distribution.

---

## Verification status

**What is measured, and by what.**

- **Claims about this repository are bound by Truthgate** and fail `nix build .#truthgate-docs` when the tree stops matching them. That covers the verity pipeline, the plugin microVM tier and its hypervisor set, the forge's container flags, the `security.lsm` and kernel-variant owners, the root filesystem, Secure Boot and the nixpkgs pin.
- **Hardware claims were measured on the target machine**, not inferred — see *Measured starting point*. The SEV-SNP and IBT statements in particular were asserted from general knowledge in earlier drafts and are now read from `/proc/cpuinfo` and the running kernel config.
- **Claims about Exsecutor were read from a checkout and by driving the compiler directly**, including the target-triple table, the trap ABI, the import surface and the backend opcode coverage.

**What is not, and cannot be here.**

- **The Exsecutor tree is not in this repository**, so no claim about it can be gated. Those statements are pinned to `github.com/ALH477/exsecutor`, branch `feat/stage7`, commit `d7bf62f`. That tree moves weekly and two findings in this document already turned on staleness: a status block naming bitwise arithmetic as unspecified was two weeks out of date, and the specification text for integer division existed only as an uncommitted edit in a sibling checkout. **Re-read before planning against any statement here.**
- **Vendor sandbox details** for hosted providers were not independently verified.
- **Policy syntax is illustrative.** IPE rule syntax and NixOS option snippets should be validated against the current IPE admin guide and nixpkgs option documentation — particularly given that IPE has no NixOS module on the pinned channel at all (C).

---

## Sources

- LOTRx86 / intermediate privilege layers on x86-64 — https://arxiv.org/pdf/1805.11912
- LKML multi-ring userspace RFC (2002) — https://lkml.iu.edu/hypermail/linux/kernel/0210.3/0753.html
- Intel, "Envisioning a Simplified Intel Architecture" (X86S) — https://www.intel.com/content/www/us/en/developer/articles/technical/envisioning-future-simplified-architecture.html
- FRED enablement series — https://lkml.iu.edu/hypermail/linux/kernel/2308.0/00287.html
- KSPP recommended settings — https://kspp.github.io/Recommended_Settings.html
- kconfig-hardened-check — https://github.com/a13xp0p0v/kernel-hardening-checker
- Linux IPE documentation — https://docs.kernel.org/security/ipe.html
- IPE admin guide — https://docs.kernel.org/admin-guide/LSM/ipe.html
- LWN, Integrity Policy Enforcement LSM — https://lwn.net/Articles/969749/
- Rust for Linux, general information — https://docs.kernel.org/rust/general-information.html
- `kernel` crate documentation — https://rust.docs.kernel.org/kernel/
- Linux `init/Kconfig` — https://github.com/torvalds/linux/blob/master/init/Kconfig
- LWN, the end of the kernel Rust experiment — https://lwn.net/Articles/1049831/
- AMD linux-svsm / VMPL model — https://github.com/AMDESE/linux-svsm
- Firecracker design documentation — https://github.com/firecracker-microvm/firecracker/blob/main/docs/design.md
- Anthropic sandbox-runtime — https://github.com/anthropic-experimental/sandbox-runtime
- Anthropic, Claude Code sandboxing — https://anthropic.com/engineering/claude-code-sandboxing
- OpenAI Codex Linux sandbox — https://github.com/openai/codex/blob/main/codex-rs/linux-sandbox/README.md
- CaMeL, "Defeating Prompt Injections by Design" — https://arxiv.org/abs/2503.18813
- NixOS hardening wiki — https://wiki.nixos.org/wiki/NixOS_Hardening
- Phoronix, pKVM protected guests in Linux 7.1 — https://www.phoronix.com/news/Linux-7.1-KVM
- Phoronix, RISC-V user-space CFI in Linux 7.0 — https://www.phoronix.com/news/Linux-7.0-RISC-V
- ALH477/exsecutor — https://github.com/ALH477/exsecutor
- ALH477/Oligarchy — https://github.com/ALH477/Oligarchy
