/* oligarchy_plugin.h - stable C ABI for Tier 1 native plugins.
 *
 * This is a hand-maintained projection of wit/oligarchy-plugin.wit. It exists
 * because a native plugin must be drivable through the same host-side trait as
 * a wasm one without paying the component boundary to get there.
 *
 * ABI CONTRACT (borrowed wholesale from CLAP, which got this right):
 *   - `oligarchy_plugin_entry` is the ONLY exported symbol.
 *   - The core struct below never changes size or field order within 1.x.
 *   - Everything else is an extension, fetched by string id through
 *     get_extension(). Unknown ids return NULL; callers must handle NULL.
 *   - A binary built against 1.x loads in any host implementing 1.y.
 *
 * A PLUGIN IS A CONTROL SURFACE. Audio is an extension, and an unusual one.
 *
 * The processor vtable used to live in `oligarchy_plugin` itself, which made
 * every plugin an audio effect whether it had samples to touch or not. It is
 * now behind OLIGARCHY_EXT_DSP like everything else — which is what the third
 * bullet above said should happen all along, and what the pre-existing
 * OLIGARCHY_EXT_PARAMS id was already implying while param_count/param_info
 * sat in the core struct contradicting it.
 *
 * The reason is architectural, not tidiness: realtime audio on this system is
 * the RT VM engine's job. That guest has an isolated core, a realtime kernel
 * and NETJACK. A plugin dlopen'd into a sandboxed, Landlock-confined host
 * process is not where a sample-rate deadline should live, and the note on
 * `Processor` in host/src/plugin.rs had already reached that conclusion for the
 * microVM tier without the ABI following it.
 *
 * REALTIME CONTRACT (only if you export OLIGARCHY_EXT_DSP):
 *   - process() runs on whatever thread the caller drives it from, at block
 *     rate. No malloc, no syscalls, no locks, no logging. Everything it needs
 *     is allocated in create().
 *   - Violating this will not be caught by the sandbox. It will just make the
 *     guitar sound bad.
 *   - If you want a sample-rate path, you want the RT VM engine, not this.
 */

#ifndef OLIGARCHY_PLUGIN_H
#define OLIGARCHY_PLUGIN_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define OLIGARCHY_ABI_VERSION_MAJOR 1
#define OLIGARCHY_ABI_VERSION_MINOR 0

/* --- extension ids ------------------------------------------------------ */
#define OLIGARCHY_EXT_CONTROL "oligarchy.control/1"
#define OLIGARCHY_EXT_PARAMS  "oligarchy.params/1"
#define OLIGARCHY_EXT_STATE   "oligarchy.state/1"
/* Audio. Optional, and rare — see the header comment. get_extension() returns
 * an `oligarchy_dsp *` for this id, or NULL, which is the normal answer. */
#define OLIGARCHY_EXT_DSP     "oligarchy.dsp/1"

/* --- log levels (must match wit `host.log-level` ordinals) -------------- */
typedef enum {
    OLIGARCHY_LOG_TRACE = 0,
    OLIGARCHY_LOG_DEBUG = 1,
    OLIGARCHY_LOG_INFO  = 2,
    OLIGARCHY_LOG_WARN  = 3,
    OLIGARCHY_LOG_ERROR = 4
} oligarchy_log_level;

typedef struct {
    uint32_t sample_rate;
    uint32_t block_size;
    uint8_t  channels;
} oligarchy_audio_config;

typedef struct {
    uint32_t id;
    const char *name;   /* owned by the plugin, valid until destroy() */
    float min, max, def;
} oligarchy_param_info;

/* --- services the host offers to the plugin ----------------------------- */
/* Every one of these is capability-checked host-side against the manifest.
 * There is deliberately no open()/socket()/getenv() here: if a plugin wants
 * the filesystem it goes through Landlock-allowed paths directly and the
 * kernel is the enforcement point, not this vtable. */
typedef struct oligarchy_host {
    uint32_t abi_major;
    uint32_t abi_minor;
    void *host_data;

    void     (*log)(const struct oligarchy_host *h,
                    oligarchy_log_level lvl, const char *msg);
    uint64_t (*now_ns)(const struct oligarchy_host *h);
    /* Returns NULL if unset. Pointer valid until the next read_config call. */
    const char *(*read_config)(const struct oligarchy_host *h, const char *key);
    bool     (*has_capability)(const struct oligarchy_host *h, const char *name);
} oligarchy_host;

/* --- the plugin instance ------------------------------------------------ */
typedef struct oligarchy_processor {
    void *plugin_data;

    /* Realtime. `in` and `out` are interleaved, channels*block_size floats.
     * May alias. Returns false to signal a fault; the host then bypasses
     * this plugin for the rest of the session. */
    bool (*process)(const struct oligarchy_processor *p,
                    const float *in, float *out, uint32_t frames);

    void  (*set_param)(const struct oligarchy_processor *p, uint32_t id, float v);
    float (*get_param)(const struct oligarchy_processor *p, uint32_t id);
    void  (*reset)(const struct oligarchy_processor *p);
} oligarchy_processor;

/* --- the audio extension (OLIGARCHY_EXT_DSP) ---------------------------- */
/* Returned by get_extension(OLIGARCHY_EXT_DSP). A plugin that does not process
 * audio returns NULL for this id, which is the common case and not an error.
 *
 * Lifetime: the struct must outlive the plugin (statically allocated is the
 * expected shape), because the host holds the pointer for as long as the
 * plugin is loaded. */
typedef struct oligarchy_dsp {
    oligarchy_processor *(*create)(const oligarchy_audio_config *cfg);
    void (*destroy)(oligarchy_processor *p);

    uint32_t (*param_count)(void);
    bool     (*param_info)(uint32_t index, oligarchy_param_info *out);
} oligarchy_dsp;

typedef struct oligarchy_plugin {
    uint32_t abi_major;
    uint32_t abi_minor;
    const char *id;
    const char *version;

    /* Non-realtime. Called once after dlopen, inside the sandbox. If a
     * plugin needs to JIT, it does it here, and its manifest must declare
     * jit = "self" or the mprotect will return EPERM. */
    bool (*init)(const oligarchy_host *host);
    void (*shutdown)(void);

    /* NULL for unknown ids — including OLIGARCHY_EXT_DSP, which most plugins
     * do not implement. This is the whole optional surface: audio, params and
     * state all arrive through here rather than as core fields. */
    const void *(*get_extension)(const char *ext_id);
} oligarchy_plugin;

/* --- the one exported symbol -------------------------------------------- */
typedef struct oligarchy_plugin_entry {
    uint32_t abi_major;
    uint32_t abi_minor;
    const oligarchy_plugin *(*get)(void);
} oligarchy_plugin_entry;

extern const oligarchy_plugin_entry oligarchy_plugin_entry_v1;

#ifdef __cplusplus
}
#endif
#endif /* OLIGARCHY_PLUGIN_H */
