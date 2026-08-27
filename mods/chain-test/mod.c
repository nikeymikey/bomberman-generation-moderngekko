/*
 * chain-test -- prove the ModernGekko mod chain end to end, changing nothing.
 *
 * This mod deliberately has no gameplay effect. It exists to answer one
 * question that had never been tested on this game: does a mod get discovered,
 * accepted by the ABI check, and actually dispatched to?
 *
 * It registers entry hooks only. A hook is purely observational by design --
 * ModManager::Dispatch saves the CPUState, calls the hook, then restores it
 * (mod_loader.cpp), and with no patch registered for the address it returns
 * false so the original function still runs. So these hooks cannot alter
 * behaviour even by accident.
 *
 * Addresses come from tools/find_functions.py, which recovers call targets by
 * decoding every `bl` in main.dol. That matters: DolRecomp turns a `bl` into
 * `ctx->pc = <target>; return;`, handing control back to the block dispatcher,
 * which consults the mod manager. A `bl` target is therefore always reachable
 * by dispatch, whereas an arbitrary mid-function address is reached by a plain
 * `goto` inside a chunk and would never fire.
 *
 *   0x80003140  the DOL entry point, executed exactly once at boot
 *   0x80084110  90 static call sites
 *   0x80036AF8  86 static call sites
 *
 * Three targets rather than one so the result stays informative: if the two
 * ordinary functions fire but the entry point does not, that tells us the boot
 * path bypasses dispatch, which is worth knowing on its own.
 */
#define __USE_MINGW_ANSI_STDIO 1
#include "moderngekko/mod_abi.h"

#include <stdio.h>

static unsigned long long g_entry_hits;
static unsigned long long g_hits_a;
static unsigned long long g_hits_b;

static void hook_entry(CPUState *state) { (void)state; ++g_entry_hits; }
static void hook_a(CPUState *state)     { (void)state; ++g_hits_a; }
static void hook_b(CPUState *state)     { (void)state; ++g_hits_b; }

static const ModernGekkoModHook hooks[] = {
    RECOMP_HOOK(0x80003140u, hook_entry),
    RECOMP_HOOK(0x80084110u, hook_a),
    RECOMP_HOOK(0x80036AF8u, hook_b),
};

static void mod_loaded(const ModernGekkoModHostApi *api)
{
    fprintf(stderr,
            "[chain-test] loaded: host ABI %u, CPUState %u bytes, %u hooks\n",
            api ? api->abi_version : 0u,
            (unsigned)sizeof(CPUState),
            (unsigned)(sizeof(hooks) / sizeof(hooks[0])));
    fflush(stderr);
}

static void mod_unloaded(void)
{
    fprintf(stderr,
            "[chain-test] hooks fired: 0x80003140=%llu  0x80084110=%llu  0x80036AF8=%llu\n",
            g_entry_hits, g_hits_a, g_hits_b);
    fprintf(stderr,
            "[chain-test] %s\n",
            (g_entry_hits || g_hits_a || g_hits_b)
                ? "DISPATCH WORKS -- mods can intercept this game"
                : "NO HOOK FIRED -- discovery and ABI are fine but dispatch never reached these addresses");
    fflush(stderr);
}

static const ModernGekkoModDesc descriptor = {
    .abi_version     = MODERNGEKKO_MOD_ABI_VERSION,
    .cpu_abi_version = MODERNGEKKO_CPU_ABI_VERSION,
    .cpu_state_size  = sizeof(CPUState),
    .game_id         = MOD_GAME_ID,
    .id              = MOD_ID,
    .version         = MOD_VERSION,
    .display_name    = MOD_DISPLAY_NAME,
    .hooks           = hooks,
    .num_hooks       = (uint32_t)(sizeof(hooks) / sizeof(hooks[0])),
    .on_load         = mod_loaded,
    .on_unload       = mod_unloaded,
};

MODERNGEKKO_MOD_EXPORT const ModernGekkoModDesc *moderngekko_get_mod(void)
{
    return &descriptor;
}
