# Findings from a GameCube port with DolRecomp + ModernGekko

Bomberman Generation (USA), disc ID `GBGE5G`, Windows, Ninja + MinGW-w64 GCC,
C backend. Tested against ModernGekko `5417826` and DolRecomp `1bec355`.

The game runs natively, in widescreen, with GameCube controller support, a
mod that changes gameplay, and a launcher that compiles the module from the
user's own disc image on first run. Getting there needed seven fixes. Patches
for all of them are in `patches/` in the project repository and are offered
as-is — several are almost certainly not how you'd want to fix these upstream,
but each one names a concrete defect with a reproduction.

Ordered by how much they block someone starting out.

---

## 1. `CPUState` ABI drift: no generated module can load

**Blocks every GameCube port. First thing anyone hits.**

`GXRuntime/include/core/cpu.h` in the vendored Dolphin declares
`GXRUNTIME_CPU_ABI_VERSION 3u`, while `include/moderngekko/cpu_state.h`
declares `MODERNGEKKO_CPU_ABI_VERSION 4u` and carries an extra field
(`s64 cycle_budget` after `s64 downcount`).

`ModManager::Load` rejects on `desc->cpu_abi_version != MODERNGEKKO_CPU_ABI_VERSION
|| desc->cpu_state_size != sizeof(CPUState)`, and the static-recomp core makes the
same comparison for the module itself, so **every** freshly generated module is
refused. There is no partial failure and no useful message beyond "CPU ABI
mismatch".

*Patch:* `gxruntime-cpu-abi4.patch` adds the missing field and bumps the vendored
constant to `4u`.

*Worth noting:* generated modules embed `sizeof(CPUState)`, and the module cache
key does not cover this header, so cached modules survive the fix and keep
failing. Anyone who fixes the header still has to clear the cache to see it work.
Folding the header's hash into the cache identity would remove a confusing
second failure.

---

## 2. Empty `GCPadNew.ini` stub deadlocks controller setup

**Blocks GameCube controller input.**

`ControllerConfigExists()` returns true when the profile file exists. Dolphin's
config system creates `GCPadNew.ini` as an empty stub during normal startup, so
after one launch the check passes while the file contains no configured device.
The frontend then refuses to start with "GCPadNew.ini has no configured
controller device", and because the stub keeps existing, it never recovers.

*Patch:* `moderngekko-controller-stub.patch` makes existence mean *a usable
device is configured*:

```cpp
if (!fs::is_regular_file(ControllerConfigPath(user_directory), ec))
  return false;
return !ReadConfiguredControllers(user_directory).empty();
```

*Related:* `MODERNGEKKO_GAMECUBE_CONTROLLERS` must be `ON` or the frontend writes
`WiimoteNew.ini` (`[Wiimote1]` sections) and leaves `GCPadNew.ini` empty, so a
GameCube pad shows as selected in the launcher with no bindings. For a GameCube
title this is not really optional; defaulting it from the disc's platform would
save the next person the same hour.

---

## 3. Exit-time `0xC0000005`: the render window outlives the config

**Every session ends in a crash.** Cosmetic in that the game has already
finished, but it looks like a bug in whatever you shipped.

`Runtime::~Runtime()` (`src/runtime/dolphin_runtime.cpp:756`) calls
`UICommon::Shutdown()` — and so `Config::Shutdown()`, which clears every config
layer — *before* `~PlatformWin32()` destroys the render window. `DestroyWindow()`
dispatches `WM_KILLFOCUS` into the window procedure synchronously, and that
handler does:

```cpp
Config::SetCurrent(Config::MAIN_EMULATION_SPEED, 1.0f);   // PlatformWin32.cpp:406
```

`Config::Set` is `GetLayer(layer)->Set(...)` with no null check (`Config.h:114`),
so the window's own destruction dereferences null:

```
~Runtime -> ~PlatformWin32 -> WndProc -> Config::Set<float>
         -> Config::GetLayer (null) -> Config::Layer::Set   ← read of 0x20
```

It appears as `0xC0000005` running the runner directly and `0xC000041D`
(`FATAL_USER_CALLBACK_EXCEPTION`) through the launcher — the same fault, wrapped
because it was raised inside a user callback. Diagnosed from a WER minidump.

*Patch:* `moderngekko-shutdown-order.patch` destroys the window before
`UICommon::Shutdown()`, restoring reverse-of-construction order.

*Also worth considering:* `Config::Get`/`Set`/`DeleteKey` all dereference
`GetLayer()` unchecked. Teardown ordering is one way to reach that; it probably
is not the only one.

---

## 4. `thread_local` PRNG destructor faults at thread detach (MinGW)

Once issue 3 is fixed, a second fault becomes reachable — the process used to
die in the config teardown before ever getting here.

`Common/Random.cpp` declares `static thread_local EntropySeededPRNG s_esprng`.
MinGW runs `thread_local` destructors from a TLS callback (`run_dtor_list`) at
thread and process detach, by which point the thread's storage is already
released:

```
tls_callback -> run_dtor_list -> ~EntropySeededPRNG
             -> mbedtls_hmac_drbg_free -> mbedtls_md_free   ← 0xC0000005
```

Silent — the exit status is already fixed at 0 — but it still writes a crash
dump, and on some machines a "stopped working" dialog.

*Patch:* `dolphin-tls-prng-leak.patch` makes it a never-deleted pointer: a few
hundred bytes per thread that draws randomness, in exchange for removing the
whole class of shutdown-ordering faults. Not necessarily the fix you want, but
the defect is real on MinGW.

---

## 5. Dolphin + MinGW needs `_WIN32_WINNT` raised

Dolphin never defines `_WIN32_WINNT` / `NTDDI_VERSION`. MSVC's toolchain
defaults them to a Windows 10 level; MinGW defaults to `0x0601` (Windows 7), so
Win8/Win10 APIs Dolphin calls are hidden behind version gates and the build
fails on symbols that plainly exist.

Setting `_WIN32_WINNT=0x0A00` and `NTDDI_VERSION=0x0A000004` for MinGW builds
fixes it. Both gates were confirmed independently by recompiling a single file
with and without the definitions.

---

## 6. `dolrecomp extract` and the gitlab-hosted bzip2 submodule

Dolphin pins `Externals/bzip2` to `https://gitlab.com/bzip2/bzip2.git`, which
returns **HTTP 403**, so a recursive submodule fetch fails and nothing builds.

`https://github.com/libarchive/bzip2.git` carries the *same pinned commit*
(`6a8690fc8d26c815e798c588f796eabe9d684cf0`), so redirecting the URL is
byte-identical to upstream's intent rather than a version substitution.

---

## 7. Mod hook dispatch is not exactly-once

**Affects correctness of any mod that counts, accumulates, or advances state in
a hook.**

Measured with a mod that hooks the DOL entry point — which executes once at boot
— and records the guest `lr` and stack pointer on each fire:

```
0x80003140  fires=2  same-(lr,sp) repeats=1  first_lr=0x00000000  second_lr=0x00000000
```

Identical `lr` and stack pointer: one guest call dispatched to the hook twice.
Over a longer session, roughly **2% to 17%** of fires on an ordinary function
were duplicates, the rate rising under load. (The 17% figure is an upper bound
for that address — a loop calling one function repeatedly from a single call
site produces identical `(lr, sp)` pairs too. The entry point is the
unambiguous case.)

The mechanism, as far as I traced it: a hook-only mod returns `false` from
`ModManager::Dispatch` — correctly, since `false` is what tells the caller "no
patch replaced this, run the original". `StaticRecompCore_Run.cpp:218` then sets
`m_host_call_passthrough` and hands the address to `Jit64`. `ShouldYieldAt`
(`StaticRecompCore.cpp:129`) is meant to consume that flag so the JIT runs
straight through, but it is a **single-shot flag with no stack** and is only
consumed if the JIT actually consults it for that address — a block compiled
before the address became a host-call address will not. The flag survives, and
the next arrival at the same pc dispatches again. Note that line 224 invalidates
the block at `lr`, not at `pc`.

**Not patched.** Every candidate fix is a change to a JIT/dispatch interaction I
could not validate without a full rebuild-and-play cycle per attempt, and
guessing at it seemed worse than reporting it precisely. Mods can be written
idempotently to work around it, but that is a constraint worth documenting even
if it is not worth fixing.

---

# Smaller notes

**A hook cannot change registers.** `Dispatch` saves the `CPUState`, calls the
hook, restores it. It *can* change memory, since `moderngekko_mod_write` goes
through `external_write` to Dolphin's MMU, which is not part of the restored
state. That asymmetry is the single most useful thing to know when writing a
mod, and it is not stated anywhere in `mod_abi.h`. A sentence in the header
would save real time.

**One hook costs 16 KB of native code.** `ChunkContainsHostCall`
(`StaticRecompCore_SMC.cpp:248`) demotes any chunk containing a registered mod
address to `Jit64` for the rest of the run. Still JIT-compiled, not interpreted
— only *forced* fallback ranges reach the interpreter — but it means hooks
scattered across the address space cost far more than hooks clustered together.
`DOLRECOMP_C_CHUNK_INSTRUCTIONS` (128–4096, default 4096) trades this against
dispatcher round-trips; that trade-off is not documented and is worth a line.

**`--map` produces no symbol header on the C backend without a map, and changes
no code with one.** Symbols reach codegen only via `collect_llvm_entry_points`,
the LLVM backend's entry-point seed; the C path uses them solely to emit
`<stem>_symbols.h` and partitions on the fixed `c_chunk_instructions()`
regardless. So building a module with `--map` recompiles everything to produce a
header while emitting byte-identical code. Running DolRecomp's codegen step
alone is enough. Documenting that would spare a long pointless rebuild.

**`moderngekko-port` has no `--map`.** It builds the DolRecomp command line
itself, so there is no way to pass a symbol map through the normal build path.
`moderngekko-symbol-map.patch` adds it and folds the map's SHA-256 into the
module cache identity, so editing a map rebuilds.

**The launcher's `PrepareDisc()` accept path is inside
`#ifdef MODERNGEKKO_REQUIRED_DISC_ID`.** Without that define every disc falls
through to the `#else` and is rejected with "this disc is not the pinned patched
release" — whose `#if` side is hardcoded Sonic Riders TE logic. For anyone
porting a different game, the failure message describes a game they have never
heard of.

**A useful property, in case it is accidental:** DolRecomp compiles every `bl`
as `ctx->pc = <target>; return;`, handing control back to the block dispatcher,
which consults the mod manager. That makes every call target a reliable hook
address, while intra-chunk flow is a plain `goto` that never dispatches.
Decoding `bl` targets out of the DOL recovered 3266 real function entry points
where the generated header offers only 105 partition boundaries. Worth stating
in the modding documentation, because it is the difference between "hooks work"
and "hooks work at addresses you can actually enumerate".

---

# What worked well

Not everything needed a patch, and some of this was better than expected.

**Zero unknown opcodes** on a full commercial title. `fallback=0` and
`smc_failed=0` across every session, hundreds of millions of instructions.

**The `.mgm` package format and `DiscoverModSources`** are a good design — a
directory with a platform library, discovered from two search roots, with clear
issue reporting through `ModLoadReport`. The runtime printing `mod rejected:
<path>: <reason>` to stderr made every mod problem in this project
self-diagnosing.

**`--mods <path>` accepting an individual package, and `--no-mods` suppressing
only the defaults**, meant a launcher could express an exact enabled set with no
runtime change at all. That composability was not obvious from the help text but
it is exactly right.

**The DOL patch manifest** (`address,expected,replacement`, verifying `expected`
before writing, idempotent when the word already holds `replacement`) is a
careful design. I built a build-time applier against the same format and then
did not use it, having realised the DOL's SHA-256 is the module cache key — so a
DOL patch cannot coexist with toggleable mods on a shipped module. That
consequence might be worth a note beside the option.
