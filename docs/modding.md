# Modding

How the mod system works on this game, what a hook costs, what it cannot do,
and a worked example from cheat search to shipped mod.

## Mods

The mod chain is proven end to end on this game by `mods/chain-test`, a mod
that registers three entry hooks, counts them and changes nothing. Its result:

```
mod loaded: chain_test 1.0.0
[chain-test] loaded: host ABI 1, CPUState 3536 bytes, 3 hooks
[chain-test] hooks fired: 0x80003140=2  0x80084110=340  0x80036AF8=0
```

### Where mod addresses come from

DolRecomp gives you **no** function inventory unless you pass `--map`: the 105
`func_XXXXXXXX` symbols in its generated header are partition boundaries, 103
of the 104 gaps being exactly 16384 bytes. `tools/find_functions.py` recovers
the real inventory instead — 3266 call targets, all inside `.text` — by
decoding every `bl` in `main.dol`.

`bl` targets specifically, not arbitrary addresses. DolRecomp compiles a `bl`
as `ctx->pc = <target>; return;`, handing control back to the block dispatcher,
which consults the mod manager. Control flow *within* a chunk is a plain
`goto`, so a hook on a mid-function address would never fire.

### What a hook costs

`ChunkContainsHostCall` (`StaticRecompCore_SMC.cpp:248`) asks the mod manager
whether any registered address falls inside each 16 KB chunk. If one does, that
whole chunk is demoted for the rest of the run:

```
[staticrecomp] mod fallback: chunk [0x80003100,0x80005600)
```

Demoted means Dolphin's `Jit64` (`StaticRecompCore_Run.cpp:250`) rather than
the statically recompiled native code — still JIT-compiled, not interpreted;
only *forced* fallback ranges go to the interpreter. So the unit of cost is
**16 KB of guest code per hook**, and several hooks scattered across the
address space cost far more than several hooks in one place.

### A hook is not exactly-once

`mods/chain-test` measured this rather than assuming it. The DOL entry point
executes once at boot, yet:

```
[chain-test]   0x80003140  fires=2  same-(lr,sp) repeats=1  first_lr=0x00000000  second_lr=0x00000000
```

Identical `lr` and stack pointer, so that is one guest call dispatched to the
hook twice. It is intermittent, not universal. Over a longer session:

```
[chain-test]   0x80084110  fires=3270  same-(lr,sp) repeats=73
```

so roughly 2% of dispatches are duplicates -- and that 2% is an upper bound,
because a loop calling one function repeatedly from a single call site produces
identical `(lr, sp)` pairs too. The entry point is the only address where the
result is unambiguous, since it executes exactly once.

The mechanism is the passthrough guard in the demoted-chunk path.
`StaticRecompCore_Run.cpp:218` dispatches the host call, and because a
hook-only mod returns `false` (that is the signal meaning "no patch replaced
this, run the original") the core sets `m_host_call_passthrough` and hands the
address to `Jit64`. `ShouldYieldAt` (`StaticRecompCore.cpp:129`) is supposed to
consume that flag so the JIT runs straight through. It is a **single-shot flag
with no stack**, and it is only consumed if the JIT actually consults it for
that address -- a block compiled before the address became a host-call address
will not. The flag then survives, and the next arrival at the same pc dispatches
the hook again. Note that line 224 invalidates the block at `lr`, not at `pc`.

**Consequence for mod authors: entry hooks must be idempotent.** Read guest
state, drive an overlay, trigger an effect that is safe to repeat -- but do not
count, accumulate, or advance a state machine in a hook without deduplicating
on something that changes between real calls.

By reasoning (not yet measured): a `RECOMP_PATCH` returns `true`, so
`Run.cpp:226` charges cycles and continues the loop without ever entering the
JIT passthrough path, which should make patches exactly-once. Treat that as
unverified until a patch is actually instrumented.

### Hooks cannot change behaviour

`ModManager::Dispatch` saves the CPUState, calls each entry hook, then restores
it, and returns `false` when no patch is registered so the original still runs.
Changing behaviour requires `RECOMP_PATCH`, which replaces the function.

### Choosing mods in the launcher

The launcher lists every `.mgm` package it finds in `Mods\\` beside the
executable and in the user folder, with a checkbox each. The selection is
stored in `config.ini`:

```ini
[Mods]
mods=chain_test.mgm,another_mod.mgm
```

Order in that list is load order, which is the one thing plain discovery cannot
express -- `DiscoverModSources` sorts whatever it finds. The runner reads the
same key, so a selection made in the launcher also applies to a direct
`moderngekko-run` invocation; `--mods` and `--no-mods` still override it.

A **missing** `mods=` key is not the same as an empty one. Missing means nothing
has chosen yet, and the runner keeps its default of loading everything it finds,
so adding this to an existing install never silently disables someone's mods.
An empty list means deliberately none. `SaveConfig` writes the key only once
something has actually chosen, because its other overload round-trips through
`LoadConfig` and would otherwise turn "never configured" into "explicitly none"
the first time an unrelated setting was toggled.

The launcher reads each package's name and version from an optional `mod.ini`
inside it, written by `Build-Mod.ps1`:

```ini
id=chain_test
name=Chain Test
version=1.0.0
```

Reading a text file rather than calling `moderngekko_get_mod()` in each library
is deliberate: loading a third-party DLL runs its `DllMain` and static
initialisers, and doing that merely to render a label would execute a mod's code
before the user has enabled anything. A package with no `mod.ini` is listed
under its directory name.

### A worked example: mods/starting-bombs

Every player starts a match with a chosen number of bombs, selectable in the
launcher. The method matters more than the mod, and two wrong turns along the
way are the most useful part of it.

**Find the value.** Dolphin cheat search (Tools -> Cheats Manager) narrowed to
the live bomb capacity by filtering on 1, then 2 after a powerup. Capacity, not
bombs-available: it rises on a powerup and does not drop when a bomb is placed.

**Find the code.** A memory write breakpoint on that address broke on the
store. The cheat-search address was a *byte* inside a big-endian 32-bit field,
so it was not 4-byte aligned -- `tools/whereis.py` rejects such addresses
instead of pretending to locate them.

**Confirm it statically**, because the debugger view is not the source of
truth. Read straight out of `main.dol`:

```
800B5D00  9421FFF0  stwu r1, -16(r1)     fn_800B5D00 entry
800B5D04  80030064  lwz  r0, 0x64(r3)
800B5D08  2C000001  cmpwi r0, 1
800B5D0C  408202F4  bne  +0x2F4
800B5D1C  38E00001  li   r7, 1           base bomb count
800B5D30  90E30184  stw  r7, 0x184(r3)
```

Nothing writes `r3` between the entry and the store, so `r3` on entry is the
pointer the store uses. That is the fact the mod rests on.

**First wrong turn: assuming it was an init routine.** It is not.
Instrumenting it showed the gate at `+0x64` true on *every* call, and the
function holds eight stores to `+0x184`: a bomb-up doing `capacity += 1` at
`800B5DEC`, a clamp to 8 at `800B5F08`, and resets to 1 and 0. It *recomputes*
`capacity = 1 + powerups` from scratch, constantly.

**Second wrong turn: setting instead of adding.** The first version wrote 2
whenever the field read 1. That is a floor, not a starting value -- after one
bomb-up the game computes `1+1 = 2`, the mod saw 2 rather than 1 and did
nothing, so the first powerup appeared to do nothing. Adding turns `1+N` into
`2+N`, which is what changing the base constant would do. Only the exit counters
(`applied 6629, gate-skipped 0, value-skipped 3147`) exposed this; the mod
looked correct at match start either way.

**Why not patch the DOL.** Changing `li r7, 1` to `li r7, 2` is a one-word DOL
patch and was built and tested (`tools/apply_dol_patch.py`). It was rejected:
the DOL's SHA-256 is the module cache key, so every combination of patches
would need its own prebuilt module. DOL patches cannot coexist with toggleable
mods on a shipped module.

**The mod.** Two hooks on the same function. `RECOMP_HOOK` at entry records
`r3` and nothing else, because the function computes the value afterwards;
`RECOMP_HOOK_RETURN` runs after it finishes and does the write. Registers are
restored after a hook, memory is not -- that asymmetry is why a hook-only mod
can change anything. The entry/return flag also absorbs duplicate dispatch,
which matters for an add: without it, a repeated return would add twice. A
capacity of 0 is left alone so a curse still strips bombs, and the result is
clamped to the same maximum of 8 the game uses.

Verified in a four-player Battle match at every setting from 2 to 8, with
powerups still incrementing beyond the chosen start.

**Battle-only, tested rather than assumed.** `fn_800B5D00` is the general
item/stat path, so there was every reason to expect it to run in story mode as
well. It was checked with the mod enabled: story mode bomb counts are
unchanged. The name claims Battle because that was measured, not because the
function looked like it belonged to Battle.

The scope was left out of the name until that test existed. If it had turned
out otherwise, the gate was already identified -- a global at `0x80306BB0`,
compared against 3 and 5 inside this same function -- and the mod would have
read it rather than being renamed to hide the problem.

### Packaging

A `.mgm` package is a *directory* named `<mod-id>.mgm` containing the platform
library under the exact name `mod` (`mod.dll`). Anything else is reported as
"package has no platform mod library". The runner searches `<exe dir>\Mods`
and `<user dir>\Mods`; `--mods <path>` adds a specific package or directory
and `--no-mods` suppresses only the two defaults.
