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
 * Built with -DPLUGIN_ID="..." so one source file serves every fixture; the
 * host cross-checks the manifest id against the binary's, so they must agree.
 */

#include "oligarchy_plugin.h"

#include <stdio.h>
#include <sys/mman.h>
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

static bool pl_init(const oligarchy_host *host)
{
    char msg[128];
    bool exec_ok = probe_exec_allowed();
    bool memfd_ok = probe_memfd_allowed();

    snprintf(msg, sizeof msg, "WXPROBE exec=%s memfd=%s",
             exec_ok ? "allowed" : "denied",
             memfd_ok ? "allowed" : "denied");
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
