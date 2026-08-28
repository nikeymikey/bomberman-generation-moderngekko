**Title:** Three things about the mod API that cost me a day each, and are not written down

*Context: porting Bomberman Generation (USA, `GBGE5G`) to Windows with the C
backend, Ninja + MinGW-w64 GCC, against ModernGekko `5417826` and DolRecomp
`1bec355`.*

Not bugs. Each is a property of the design that I had to discover by reading
source or by measurement, and each would be a sentence or two to document.

## 1. A hook cannot change registers, but it can change memory

`ModManager::Dispatch` saves the `CPUState`, calls the hook, and restores it —
so register writes are discarded. But `moderngekko_mod_write` goes through
`external_write` to Dolphin's MMU, which is **not** part of the restored state,
so memory writes persist.

This asymmetry is the single most useful fact for writing a mod, and it is not
stated in `mod_abi.h`. It is the difference between "a hook-only mod can change
gameplay" and "a hook is read-only", and I initially assumed the latter.

## 2. One hook costs 16 KB of native code

`ChunkContainsHostCall` (`StaticRecompCore_SMC.cpp:248`) demotes any chunk
containing a registered mod address to `Jit64` for the rest of the run, and
prints `[staticrecomp] mod fallback: chunk [...]`.

Still JIT-compiled rather than interpreted — only *forced* fallback ranges reach
the interpreter — but the practical consequence is that hooks scattered across
the address space cost far more than hooks clustered together. That is real
design guidance for mod authors and is currently only discoverable from a log
line.

`DOLRECOMP_C_CHUNK_INSTRUCTIONS` (128–4096, default 4096) trades this granularity
against dispatcher round-trips. Also undocumented.

## 3. `PrepareDisc()`'s failure message names a different game

The accept path is inside `#ifdef MODERNGEKKO_REQUIRED_DISC_ID`. Without that
define, **every** disc falls through to the `#else` and is rejected with
"this disc is not the pinned patched release" — whose `#if` side is hardcoded
Sonic Riders Tournament Edition logic.

Someone porting a different game sees their correct disc rejected, with a
message describing a game they have never heard of, and no indication that a
CMake option is missing.

## Bonus: a useful property I could not find documented

DolRecomp compiles every `bl` as `ctx->pc = <target>; return;`, handing control
back to the block dispatcher, which consults the mod manager. **Every call
target is therefore a reliable hook address**, while intra-chunk flow is a plain
`goto` that never dispatches.

Decoding `bl` targets straight out of the DOL recovered 3266 real function entry
points, where the generated header offers only 105 partition boundaries. That is
the difference between "hooks work" and "hooks work at addresses I can
enumerate", and it deserves a line in the modding docs.
