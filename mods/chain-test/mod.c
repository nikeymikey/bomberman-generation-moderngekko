/*
 * chain-test -- prove the ModernGekko mod chain end to end, changing nothing.
 *
 * This mod deliberately has no gameplay effect. It registers entry hooks only.
 * A hook is purely observational by design: ModManager::Dispatch saves the
 * CPUState, calls the hook, then restores it, and with no patch registered for
 * the address it returns false so the original function still runs.
 *
 * Addresses come from tools/find_functions.py, which recovers call targets by
 * decoding every `bl` in main.dol. DolRecomp compiles a `bl` as
 * `ctx->pc = <target>; return;`, handing control to the block dispatcher, which
 * consults the mod manager -- so a `bl` target is always reachable by dispatch,
 * whereas a mid-function address is reached by a plain `goto` inside a chunk
 * and would never fire.
 *
 *   0x80003140  the DOL entry point, executed once at boot
 *   0x80084110  90 static call sites
 *   0x80036AF8  86 static call sites
 *
 * SECOND QUESTION: does a hook fire once per guest call?
 *
 * The first run reported the entry hook firing TWICE, which should be
 * impossible for a once-executed entry point. Two dispatch paths retry with an
 * aliased address when the first attempt is not "handled":
 *
 *   StaticRecompCore_Run.cpp:221   handled = host_call(pc);
 *                                  if (!handled && pc < ram_size)
 *                                      handled = host_call(pc | 0x80000000);
 *   generated.h dolrecomp_call     same shape, via dolrecomp_physical_pc_alias
 *
 * and Dispatch returns false for a hook-only mod, because false is what tells
 * the caller "no patch replaced this, run the original". So a hook can be
 * re-entered on the alias retry.
 *
 * To distinguish a double dispatch of ONE call from TWO real calls, each hook
 * records the guest link register and stack pointer.
 *
 * The entry point is the decisive case, and the reason it is hooked at all: it
 * executes exactly once at boot, so two fires carrying an identical (lr, sp)
 * pair can only be one call dispatched twice, and two fires with different lr
 * mean the entry was genuinely re-entered.
 *
 * For the two ordinary functions the same test is only suggestive: a loop
 * calling one of them repeatedly from a single call site also produces
 * identical (lr, sp) pairs. Read their repeat counts as a ratio -- repeats at
 * almost exactly half the fires would indicate every call is dispatched twice,
 * whereas a small fraction is ordinary looping.
 */
#define __USE_MINGW_ANSI_STDIO 1
#include "moderngekko/mod_abi.h"

#include <stdio.h>

/*
 * Symbol names, when a map has been generated.
 *
 * Build-Symbols.ps1 produces DolRecomp's <stem>_symbols.h from
 * symbols/GBGE5G.map, and Build-Mod.ps1 -SymbolHeader force-includes it. The
 * dependency is deliberately optional: with no header the mod still compiles
 * against the raw addresses, so a map is an ergonomic improvement rather than
 * a prerequisite for building mods.
 *
 * Placeholder names look like fn_80084110 today. As functions are identified
 * the map is edited, the header regenerates, and only the #define below
 * changes -- the address stays the identity throughout.
 */
#if defined(DOLRECOMP_SYMBOL_fn_80084110)
#  define ADDRESS_A       DOLRECOMP_SYMBOL_fn_80084110
#  define ADDRESS_SOURCE  "symbol header"
#else
#  define ADDRESS_A       0x80084110u
#  define ADDRESS_SOURCE  "raw addresses (no symbol map)"
#endif

typedef struct HookStats {
    const char *label;
    unsigned long long fires;
    unsigned long long repeats;   /* fired again with an identical (lr, sp) */
    unsigned long long first_lr;
    unsigned long long second_lr;
    uint32_t last_lr;
    uint32_t last_sp;
    int have_last;
} HookStats;

static HookStats g_entry = { "0x80003140" };
static HookStats g_fn_a  = { "0x80084110" };
static HookStats g_fn_b  = { "0x80036AF8" };

static void record(HookStats *s, const CPUState *state)
{
    const uint32_t lr = state->lr;
    const uint32_t sp = state->gpr[1];

    if (s->fires == 0) s->first_lr = lr;
    else if (s->fires == 1) s->second_lr = lr;

    if (s->have_last && lr == s->last_lr && sp == s->last_sp)
        ++s->repeats;

    s->last_lr = lr;
    s->last_sp = sp;
    s->have_last = 1;
    ++s->fires;
}

static void hook_entry(CPUState *state) { record(&g_entry, state); }
static void hook_a(CPUState *state)     { record(&g_fn_a,  state); }
static void hook_b(CPUState *state)     { record(&g_fn_b,  state); }

static const ModernGekkoModHook hooks[] = {
    RECOMP_HOOK(0x80003140u, hook_entry),
    RECOMP_HOOK(ADDRESS_A, hook_a),
    RECOMP_HOOK(0x80036AF8u, hook_b),
};

static void mod_loaded(const ModernGekkoModHostApi *api)
{
    fprintf(stderr,
            "[chain-test] loaded: host ABI %u, CPUState %u bytes, %u hooks, "
            "addresses from %s\n",
            api ? api->abi_version : 0u,
            (unsigned)sizeof(CPUState),
            (unsigned)(sizeof(hooks) / sizeof(hooks[0])),
            ADDRESS_SOURCE);
    fflush(stderr);
}

static void report(const HookStats *s)
{
    fprintf(stderr, "[chain-test]   %s  fires=%llu  same-(lr,sp) repeats=%llu",
            s->label, s->fires, s->repeats);
    if (s->fires >= 1) fprintf(stderr, "  first_lr=0x%08llX", s->first_lr);
    if (s->fires >= 2) fprintf(stderr, "  second_lr=0x%08llX", s->second_lr);
    fputc('\n', stderr);
}

static void mod_unloaded(void)
{
    const unsigned long long total =
        g_entry.fires + g_fn_a.fires + g_fn_b.fires;
    const unsigned long long repeats =
        g_entry.repeats + g_fn_a.repeats + g_fn_b.repeats;

    fprintf(stderr, "[chain-test] results:\n");
    report(&g_entry);
    report(&g_fn_a);
    report(&g_fn_b);

    if (total == 0) {
        fprintf(stderr, "[chain-test] NO HOOK FIRED -- dispatch never reached these addresses\n");
    } else if (repeats == 0) {
        fprintf(stderr, "[chain-test] VERDICT: no duplicate dispatch -- each fire is a distinct call\n");
    } else {
        fprintf(stderr,
                "[chain-test] VERDICT: %llu of %llu fires are duplicate dispatches of the same call\n",
                repeats, total);
    }
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
