/* wx-probe: a real Tier 1 plugin whose only job is to report what the sandbox
 * around it actually permits.
 *
 * This exists because every other check on the W^X split is indirect. The unit
 * tests prove we assembled the right BPF. `checks.wx-enforcement` proves the
 * right MemoryDenyWriteExecute reached the systemd unit. `plugind selftest`
 * proves the kernel honours the filter in a forked child of plugind itself.
 * None of them prove the thing that actually matters: that a plugin's own
 * machine code, dlopen'd inside bwrap after Landlock and seccomp have been
 * applied, gets the answer its manifest declared.
 *
 * So this asks the kernel directly, from the one vantage point that counts, and
 * reports through the host log callback — which also exercises the C vtable,
 * the host-services struct, and the journal path in one go.
 *
 * It probes SEVEN things, not one, and that is the lesson rather than a detail.
 * The first version asked only whether mprotect(PROT_EXEC) and memfd_create
 * were refused — the two routes the filter happened to cover — so it reported
 * "denied" while three other routes to executable memory were wide open, and
 * the gate passed. A probe that only tests what you already blocked tells you
 * nothing.
 *
 * Built with -DPLUGIN_ID="..." so one source file serves every fixture; the
 * host cross-checks the manifest id against the binary's, so they must agree.
 */

#include "oligarchy_plugin.h"

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <sys/mman.h>
#include <sys/ptrace.h>
#include <sys/syscall.h>
#include <unistd.h>

#ifndef PLUGIN_ID
#define PLUGIN_ID "wx-probe"
#endif

static bool probe_exec_allowed(void)
{
    /* An anonymous RW mapping upgraded to executable: exactly what a JIT does
     * to publish generated code, and exactly what the filter is meant to stop
     * when the manifest says jit = "none". */
    void *p = mmap(NULL, 4096, PROT_READ | PROT_WRITE,
                   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED)
        return false;
    return mprotect(p, 4096, PROT_READ | PROT_EXEC) == 0;
}

static bool probe_memfd_allowed(void)
{
    /* The half systemd's MemoryDenyWriteExecute leaves open. memfd plus two
     * mappings of the same fd never produces a single W+X mapping, so a filter
     * that only watches mmap/mprotect never fires — which is why jit = "none"
     * denies the syscall outright. Called through syscall() because there is no
     * portable libc wrapper. */
    long fd = syscall(SYS_memfd_create, "wx-probe", 0);
    if (fd < 0)
        return false;
    close((int)fd);
    return true;
}

/* Anonymous PROT_EXEC with no write bit. Rule 1 of the filter (deny W&X
 * together, which is all systemd's MDWE does) never fires on this — and it is
 * the target both writers below need. */
static bool probe_anon_exec_allowed(void)
{
    void *p = mmap(NULL, 4096, PROT_READ | PROT_EXEC,
                   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED)
        return false;
    munmap(p, 4096);
    return true;
}

/* The oldest dual-mapping trick, with a plain file instead of a memfd: two
 * mappings of one fd, one writable and one executable, neither ever W+X. This
 * is what a writable mount that is not noexec buys an attacker, and it worked
 * for the whole life of this design because the noexec half was documented and
 * never implemented. */
static bool probe_file_dualmap_allowed(void)
{
    char path[256];
    snprintf(path, sizeof path, "/var/lib/oligarchy/plugins/state/%s/.wxprobe",
             PLUGIN_ID);
    int fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0600);
    if (fd < 0)
        return false;
    bool ok = false;
    if (ftruncate(fd, 4096) == 0) {
        void *w = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        void *x = mmap(NULL, 4096, PROT_READ | PROT_EXEC, MAP_SHARED, fd, 0);
        ok = (w != MAP_FAILED && x != MAP_FAILED);
        if (w != MAP_FAILED) munmap(w, 4096);
        if (x != MAP_FAILED) munmap(x, 4096);
    }
    close(fd);
    unlink(path);
    return ok;
}

/* ptrace writes with FOLL_FORCE, so a page's protection is not consulted.
 * Probed by asking for the capability rather than by actually poking a child:
 * if ptrace is refused outright there is nothing to chase. */
static bool probe_ptrace_allowed(void)
{
    /* PTRACE_TRACEME on ourselves is the cheapest capability question; a
     * denied seccomp rule returns EPERM before the kernel considers it. */
    long rc = syscall(SYS_ptrace, PTRACE_TRACEME, 0, 0, 0);
    if (rc == 0) {
        /* We are now traced by our own parent, which we do not want. */
        syscall(SYS_ptrace, PTRACE_DETACH, 0, 0, 0);
        return true;
    }
    return errno != EPERM ? true : false;
}

/* UFFD_USER_MODE_ONLY, and the flag matters for the probe's honesty. Without it
 * an unprivileged caller is refused by vm.unprivileged_userfaultfd=0 — so the
 * probe reported "denied" for BOTH jit settings and could not distinguish the
 * seccomp rule from the sysctl. A probe that cannot tell you which control
 * fired is the failure this whole file exists to avoid. */
#define UFFD_USER_MODE_ONLY_ 1
static bool probe_userfaultfd_allowed(void)
{
    long fd = syscall(SYS_userfaultfd, O_CLOEXEC | UFFD_USER_MODE_ONLY_);
    if (fd < 0)
        return false;
    close((int)fd);
    return true;
}

/* /proc/self/mem, the sibling of the ptrace route above.
 *
 * Writes through this fd use FOLL_FORCE, so the target page's protection is not
 * consulted — the identical primitive to ptrace(POKEDATA), reached through a
 * file descriptor instead of a syscall a seccomp filter can name. It is probed
 * SEVENTH because closing ptrace and leaving this open would be closing a door
 * and not the one beside it.
 *
 * The target is this plugin's own machine code, which is the honest choice: a
 * PROT_READ|PROT_EXEC mapping the plugin did not have to create, and therefore
 * one no mmap/mprotect rule can deny it. If the write lands, the plugin can
 * rewrite its own .text, and jit = "none" means nothing.
 *
 * Non-destructive by construction: the byte written is the byte just read. The
 * page still COW-breaks and the write still goes through FOLL_FORCE, so a
 * success is a real success — we simply decline to corrupt ourselves to prove
 * it.
 */
static const char *probe_proc_self_mem(void)
{
    /* Our own address: in .text, mapped r-xp, and valid right here. */
    uintptr_t target = (uintptr_t)(void *)&probe_proc_self_mem;
    errno = 0;
    int fd = open("/proc/self/mem", O_RDWR);
    if (fd < 0) {
        /* WHICH control refused matters more than the refusal. The W^X seccomp
         * filter answers EPERM (SeccompAction::Errno(EPERM) in seccomp.rs);
         * Landlock answers EACCES. The first denial here turned out to be
         * EACCES in BOTH the jit=none and jit=self rows — meaning the filter
         * was not involved at all and the filesystem allowlist was carrying
         * this route by itself. That is a real defence, but it is a DIFFERENT
         * defence, and it degrades on its own terms: CompatLevel::BestEffort
         * silently drops rights on an older Landlock ABI, and any manifest that
         * ever grants a cap under /proc reopens the route without the W^X layer
         * noticing. Reporting the errno is what makes that visible instead of
         * inferred. Same lesson as UFFD_USER_MODE_ONLY above. */
        switch (errno) {
        case EPERM:  return "denied(seccomp)";
        case EACCES: return "denied(landlock)";
        default:     return "denied(other)";
        }
    }
    unsigned char byte;
    bool ok = false;
    if (pread(fd, &byte, 1, (off_t)target) == 1)
        ok = (pwrite(fd, &byte, 1, (off_t)target) == 1);
    close(fd);
    /* The fd opened, so the FS layer let us in; anything refusing the write is
     * the memory layer. Distinguished because "can open it" and "can write
     * through it" are separate claims. */
    return ok ? "allowed" : "denied(write)";
}

static bool pl_init(const oligarchy_host *host)
{
    char msg[256];
    bool exec_ok = probe_exec_allowed();
    bool memfd_ok = probe_memfd_allowed();
    /* The four routes that made "jit=none means no executable memory" false.
     * Reported separately so a regression names itself instead of flipping one
     * aggregate bit. */
    bool anon_ok = probe_anon_exec_allowed();
    bool dual_ok = probe_file_dualmap_allowed();
    bool ptrace_ok = probe_ptrace_allowed();
    bool uffd_ok = probe_userfaultfd_allowed();
    const char *procmem = probe_proc_self_mem();

    snprintf(msg, sizeof msg,
             "WXPROBE exec=%s memfd=%s anon=%s dualmap=%s ptrace=%s uffd=%s "
             "procmem=%s",
             exec_ok ? "allowed" : "denied",
             memfd_ok ? "allowed" : "denied",
             anon_ok ? "allowed" : "denied",
             dual_ok ? "allowed" : "denied",
             ptrace_ok ? "allowed" : "denied",
             uffd_ok ? "allowed" : "denied",
             procmem);
    host->log(host, OLIGARCHY_LOG_INFO, msg);

    /* Return true either way. The point is to report, not to refuse: a plugin
     * that failed to start would tell the test nothing about which answer the
     * kernel gave. */
    return true;
}

static void pl_shutdown(void) {}

/* The DSP side is deliberately trivial — this fixture is about the sandbox. */
static bool proc_process(const oligarchy_processor *p, const float *in,
                         float *out, uint32_t frames)
{
    (void)p;
    for (uint32_t i = 0; i < frames; i++)
        out[i] = in[i];
    return true;
}
static void proc_set_param(const oligarchy_processor *p, uint32_t id, float v)
{
    (void)p; (void)id; (void)v;
}
static float proc_get_param(const oligarchy_processor *p, uint32_t id)
{
    (void)p; (void)id; return 0.0f;
}
static void proc_reset(const oligarchy_processor *p) { (void)p; }

static oligarchy_processor the_processor = {
    .plugin_data = NULL,
    .process = proc_process,
    .set_param = proc_set_param,
    .get_param = proc_get_param,
    .reset = proc_reset,
};

static oligarchy_processor *pl_create(const oligarchy_audio_config *cfg)
{
    (void)cfg;
    return &the_processor;
}
static void pl_destroy(oligarchy_processor *p) { (void)p; }
static uint32_t pl_param_count(void) { return 0; }
static bool pl_param_info(uint32_t index, oligarchy_param_info *out)
{
    (void)index; (void)out; return false;
}
static const void *pl_get_extension(const char *ext_id) { (void)ext_id; return NULL; }

static const oligarchy_plugin the_plugin = {
    .abi_major = OLIGARCHY_ABI_VERSION_MAJOR,
    .abi_minor = OLIGARCHY_ABI_VERSION_MINOR,
    .id = PLUGIN_ID,
    .version = "0.0.1",
    .init = pl_init,
    .shutdown = pl_shutdown,
    .create = pl_create,
    .destroy = pl_destroy,
    .param_count = pl_param_count,
    .param_info = pl_param_info,
    .get_extension = pl_get_extension,
};

static const oligarchy_plugin *entry_get(void) { return &the_plugin; }

const oligarchy_plugin_entry oligarchy_plugin_entry_v1 = {
    .abi_major = OLIGARCHY_ABI_VERSION_MAJOR,
    .abi_minor = OLIGARCHY_ABI_VERSION_MINOR,
    .get = entry_get,
};
