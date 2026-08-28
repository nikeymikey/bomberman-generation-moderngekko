/*
 * starting-bombs -- begin a Battle match with more than one bomb.
 *
 * WHAT WAS FOUND
 *
 * Dolphin cheat search located the live bomb capacity, and a write breakpoint
 * on it broke here (verified byte-for-byte against main.dol, not just read off
 * the disassembly view):
 *
 *   800B5D00  9421FFF0  stwu r1, -16(r1)      <- fn_800B5D00 entry
 *   800B5D04  80030064  lwz  r0, 0x64(r3)
 *   800B5D08  2C000001  cmpwi r0, 1
 *   800B5D0C  408202F4  bne  +0x2F4           <- skips the whole stat block
 *   ...
 *   800B5D1C  38E00001  li   r7, 1            <- the starting bomb count
 *   800B5D20  90830180  stw  r4, 0x180(r3)
 *   800B5D30  90E30184  stw  r7, 0x184(r3)    <- stores it
 *
 * So capacity is a 32-bit field at +0x184 of the struct in r3, initialised
 * from a hardcoded 1. Nothing writes r3 between the function entry and that
 * store, so r3 on entry is the same pointer -- which is what makes this
 * approach work.
 *
 * WHAT THE FUNCTION ACTUALLY DOES
 *
 * fn_800B5D00 is not an init routine. Instrumenting it showed the gate at
 * +0x64 true on EVERY call (gate-skipped 0 across a whole match), and the
 * function contains eight stores to +0x184:
 *
 *   800B5D30  stw r7, 0x184(r3)   base value, from li r7,1
 *   800B5DEC  lwz r6, 0x184(r3)   bomb-up powerup:
 *   800B5DF0  addi r0, r6, 1        capacity += 1
 *   800B5DF4  stw r0, 0x184(r3)
 *   800B5F08  cmpwi r0, 8         clamp to a maximum of 8
 *   800B5F14  stw r0, 0x184(r3)
 *   800B5F94  stw r0, 0x184(r3)   reset to 1
 *   800B5FA0  stw r0, 0x184(r3)   reset to 0
 *
 * So it RECOMPUTES capacity = 1 + collected_powerups, clamped to 8, from
 * scratch on every call.
 *
 * WHY THIS ADDS RATHER THAN SETS
 *
 * The first version of this mod wrote 2 whenever the field read 1. That is a
 * floor, not a starting value: after one bomb-up the game computes 1+1 = 2,
 * the mod sees 2 rather than 1 and does nothing, so the first powerup appeared
 * to have no effect. Adding instead turns 1+N into 2+N, which is what changing
 * the base constant would have done -- without patching the DOL, whose hash is
 * the module cache key and so cannot vary per enabled mod.
 *
 * WHY TWO HOOKS
 *
 * A hook cannot change registers: ModManager::Dispatch saves the CPUState,
 * calls the hook and restores it. It CAN change memory, because
 * moderngekko_mod_write goes through external_write to Dolphin's MMU, which is
 * not part of the restored state. An entry hook runs before the function
 * computes the value, so it only records r3; the return hook does the write.
 *
 * The entry/return pairing also makes this safe against duplicate dispatch
 * (measured at roughly 17% of fires): the entry hook arms a flag, the first
 * return consumes it, and a repeated return does nothing. Without that, an
 * add-based mod would add twice.
 *
 * 0 is left alone so a curse that strips bombs still strips them, and the
 * result is clamped to the same maximum of 8 the game uses.
 */
#define __USE_MINGW_ANSI_STDIO 1
#include "moderngekko/mod_abi.h"

#include <stdio.h>
#include <stdlib.h>

#ifndef STARTING_BOMBS
#define STARTING_BOMBS 2u
#endif

/* The game's own base is 1, so the bonus is however many more we want. */
#define MAX_BOMBS  8u   /* cmpwi r0,8 at 800B5F08 */

/* Chosen in the launcher, delivered by the runner as an environment variable.
 * The name is derived the same way on both sides -- MGMOD_<MOD-ID>_<KEY>,
 * upper-cased -- so neither needs a shared table. STARTING_BOMBS remains the
 * compile-time fallback for a direct moderngekko-run invocation, where no
 * launcher has written a config. */
#define SETTING_VARIABLE "MGMOD_STARTING_BOMBS_COUNT"

static uint32_t g_bonus = STARTING_BOMBS - 1u;

static void read_setting(void)
{
    const char *text = getenv(SETTING_VARIABLE);
    unsigned long parsed;
    char *end = NULL;

    if (!text || !*text)
        return;
    parsed = strtoul(text, &end, 10);
    /* Reject anything that is not a clean number in range rather than
     * silently treating garbage as a bomb count. */
    if (!end || *end != '\0' || parsed < 1u || parsed > MAX_BOMBS)
        return;
    g_bonus = (uint32_t)parsed - 1u;
}

#define PLAYER_INIT_FUNC     0x800B5D00u
#define BOMB_CAPACITY_OFFSET 0x184u
#define INIT_GATE_OFFSET     0x64u   /* lwz r0,0x64(r3); cmpwi r0,1; bne skip */
#define INIT_GATE_VALUE      1u
#define STOCK_STARTING_BOMBS 1u

static uint32_t g_struct_pointer;
static int      g_pending;
static unsigned long long g_applied;
static unsigned long long g_skipped_gate;
static unsigned long long g_skipped_value;

static void player_init_entry(CPUState *state)
{
    /* r3 is the first argument and is not modified before the store. */
    g_struct_pointer = state->gpr[3];

    /* Reproduce the function's own condition rather than inferring it from the
     * result. fn_800B5D00 runs constantly, and the first version of this mod
     * applied 8251 times in one match because "the field reads 1" is true both
     * when the init block just wrote 1 AND when the block was skipped and the
     * player simply happens to hold one bomb. That made it a "minimum 2 bombs"
     * cheat wearing a "starting bombs" label. Reading the gate at +0x64 is the
     * difference between the two. */
    g_pending = (uint32_t)moderngekko_mod_read(state, state->gpr[3] + INIT_GATE_OFFSET, 4)
                == INIT_GATE_VALUE;
    if (!g_pending)
        ++g_skipped_gate;
}

static void player_init_return(CPUState *state)
{
    uint32_t field;
    uint32_t current;
    uint32_t updated;

    if (!g_pending)
        return;
    g_pending = 0;

    if (g_struct_pointer == 0u)
        return;

    field = g_struct_pointer + BOMB_CAPACITY_OFFSET;
    current = (uint32_t)moderngekko_mod_read(state, field, 4);

    /* Leave a stripped player stripped: 0 is a curse result, not a base. */
    if (current == 0u)
        return;
    /* Already at the game's own ceiling; adding would exceed what it allows. */
    if (current >= MAX_BOMBS) {
        ++g_skipped_value;
        return;
    }

    updated = current + g_bonus;
    if (updated > MAX_BOMBS)
        updated = MAX_BOMBS;

    moderngekko_mod_write(state, field, updated, 4);
    if (g_applied == 0u) {
        fprintf(stderr, "[starting-bombs] 0x%08X+0x%X: %u -> %u\n",
                g_struct_pointer, BOMB_CAPACITY_OFFSET,
                (unsigned)current, (unsigned)updated);
        fflush(stderr);
    }
    ++g_applied;
}

static const ModernGekkoModHook hooks[] = {
    RECOMP_HOOK(PLAYER_INIT_FUNC, player_init_entry),
    RECOMP_HOOK_RETURN(PLAYER_INIT_FUNC, player_init_return),
};

static void mod_loaded(const ModernGekkoModHostApi *api)
{
    (void)api;
    read_setting();
    fprintf(stderr,
            "[starting-bombs] loaded: hooking 0x%08X, +%u bomb(s) at +0x%X (cap %u)\n",
            PLAYER_INIT_FUNC, (unsigned)g_bonus, BOMB_CAPACITY_OFFSET, MAX_BOMBS);
    fflush(stderr);
}

static void mod_unloaded(void)
{
    fprintf(stderr,
            "[starting-bombs] applied %llu, gate-skipped %llu, value-skipped %llu\n",
            g_applied, g_skipped_gate, g_skipped_value);
    if (g_applied == 0u) {
        fprintf(stderr,
                "[starting-bombs] never applied -- either the hooks did not fire, or the "
                "field never read %u at return\n", STOCK_STARTING_BOMBS);
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
