# Bomberman Generation — ModernGekko recomp

Static recompilation of **Bomberman Generation (NTSC-U, `GBGE5G`)** to native
x86-64, using [DolRecomp](https://github.com/ExpansionPak/DolRecomp) (PowerPC →
C) and [ModernGekko](https://github.com/ExpansionPak/ModernGekko) (a
Dolphin-derived runtime).

**Status: running.**

No game code, assets or disc images are in this repository, and none ever will
be — the ignore rules are verified by `scripts/Verify-Gitignore.ps1` against
`git add -An` ground truth, and `scripts/Check-BeforePush.ps1` audits the whole
commit history before anything is pushed. Bring your own disc dump.

## Quick start (Windows)

Requires CMake 3.20+, Ninja, MinGW-w64 GCC, git, and a legally obtained dump.

```powershell
$R = "C:\path\to\this\repo"

.\scripts\Init-Repo.ps1     -RepoRoot $R
.\scripts\Apply-Patches.ps1 -RepoRoot $R -ModulesDir $R\build\modules
.\scripts\Build-Tools.ps1   -RepoRoot $R -Generator Ninja
.\scripts\Extract-Iso.ps1   -RepoRoot $R -IsoPath "C:\path\to\game.iso"
.\scripts\Build-Module.ps1  -RepoRoot $R -Slug <slug> -OutputDir $R\build\modules
.\scripts\Run-Game.ps1      -RepoRoot $R -Slug <slug> -OutputDir $R\build\modules -LogPath $R\run.log
```

`Extract-Iso` prints the slug to use for the last two steps.

Cloning: use `git clone --recursive`, or run `git submodule update --init
--recursive` afterwards. Roughly 1.2 GB is fetched (Dolphin plus ~49 Externals).
`Init-Repo.ps1` handles the broken bzip2 URL described below.

`Apply-Patches.ps1` is **not optional** — without it no module will load.

## Scripts

Every script takes its directories as **mandatory parameters with no defaults**.
A tool silently pointed at the wrong build directory is the failure mode these
are guarding against.

| Script | Purpose |
|---|---|
| `Common.ps1` | Shared helpers; dot-sourced by the rest, not run directly |
| `Init-Repo.ps1` | `git init`, pin both submodules, work around the bzip2 URL |
| `Apply-Patches.ps1` | Apply `patches/`, and invalidate the module cache it makes stale |
| `Build-Tools.ps1` | Build `dolrecomp.exe` and `moderngekko-port.exe` |
| `Extract-Iso.ps1` | `dolrecomp extract` → `extracted/<slug>/` |
| `Build-Module.ps1` | `moderngekko-port build` → a native module |
| `Run-Game.ps1` | `moderngekko-port run`, under a timeout, with a log summary |
| `Install-Module.ps1` | copy the built module where the launcher's runner finds it |
| `Verify-Gitignore.ps1` | Prove the ignore rules work in both directions |
| `Check-BeforePush.ps1` | Audit the whole commit history before a first push |
| `Test-WinApiFix.ps1` | Recompile one file with/without a fix, to test a theory cheaply |
| `Enable-CrashDumps.ps1` | Point Windows Error Reporting at `build/crashdumps/` for one exe (needs elevation) |
| `Build-Mod.ps1` | Build a mod into a `.mgm` package and optionally install it |

### `tools/`

| Tool | Purpose |
|---|---|
| `parse_minidump.py` | Name the faulting module and address in a `.dmp`, no debugger needed |
| `dump_stack.py` | Recover a call chain from a `.dmp` by scanning the crashing thread's stack against `nm` output |
| `find_functions.py` | Recover the function inventory from `main.dol` by decoding every `bl`; can emit a DolRecomp `--map` |

## Layout

```
scripts/            PowerShell build and tooling steps
patches/            local fixes to vendored code (see below)
lib/DolRecomp       submodule — PowerPC → C recompiler
lib/ModernGekko     submodule — Dolphin-derived runtime
extracted/          extracted disc contents (ignored)
generated/          generated C (ignored)
build/              tools, modules, all build output (ignored)
iso/                somewhere to drop a dump (ignored)
```

## What DolRecomp makes of this game

Measured on `main.dol` (2,195,744 bytes):

| Section | Instructions | Code | Embedded data | Unknown opcodes |
|---|---|---|---|---|
| `text0` @ `0x80003100` | 2,368 | 725 | 1,643 | **0** |
| `text1` @ `0x800068E0` | 425,304 | 425,296 | 8 | **0** |

Every byte of both text sections decodes, with no unknown opcodes. DolRecomp
sweeps linearly and classifies data rather than guessing function boundaries.

Useful constants, each derived from the disc itself:

| Value | Source |
|---|---|
| Game ID `GBGE5G` | disc header `0x00` (`E` = NTSC-U, `5G` = Majesco) |
| Entry point `0x80003140` | DOL header `0xE0` |
| r13 `_SDA_BASE_` = `0x8035DAC0` | `__init_registers` @ `0x80003264`; `.sdata` + `0x8000` |
| r2 `_SDA2_BASE_` = `0x8035F780` | `__init_registers` @ `0x8000325C`; `.sdata2` + `0x8000` |
| REL modules | **None** — all 230 disc files scanned for PowerPC function signatures; zero `mflr`/`blr` outside `main.dol` |

That last row is the important one. Runtime-loaded code is what usually defeats
a static recompiler; this game has none, so everything executable is visible
ahead of time.

DolRecomp also warns that this DOL **may patch executable memory at runtime**,
listing 104 sites in `generated_smc.txt`. On inspection those are mostly `stw` —
a conservative "this store might target code" heuristic — plus a few `icbi` in
the boot stub consistent with a normal post-apploader cache flush. Not evidence
of self-modifying code, but the first place to look if execution ever ends up
somewhere impossible.

## Upstream issues fixed here

Both were found while bringing this game up, and both are worth reporting to
ExpansionPak. `ModernGekko` (`5417826`) and `RecompCore` (`55c7b02`) were at
their remote tips at the time, so neither has an upstream fix to pull.

### 1. CPU ABI mismatch — no generated module can load

```
initialization failed: native module was rejected: CPU ABI mismatch
```

The loader checks (`src/runtime/mod_loader.cpp:230`):

```cpp
desc->cpu_abi_version != MODERNGEKKO_CPU_ABI_VERSION ||
desc->cpu_state_size  != sizeof(CPUState)
```

There are **two definitions of `CPUState` in one build tree**, and they disagree:

| Header | ABI constant | `sizeof(CPUState)` | Used by |
|---|---|---|---|
| `ModernGekko/include/moderngekko/cpu_state.h` | `MODERNGEKKO_CPU_ABI_VERSION 4u` | 3536 | the runtime |
| `vendor/dolphin/GXRuntime/include/core/cpu.h` | `GXRUNTIME_CPU_ABI_VERSION 3u` | 3528 | generated modules |

Generated C emits `#define DOLRECOMP_CPU_HEADER "cpu/cpu.h"`, and `cpu/cpu.h`
includes `core/cpu.h` — so modules compile against the stale copy. The
difference is exactly one field: **ABI v4 added `int64_t cycle_budget`
immediately after `downcount`**, and the GXRuntime copy never received it.

`patches/gxruntime-cpu-abi4.patch` adds the field and bumps the constant.
Verified by measuring `sizeof(CPUState)` through the module's real include chain
before and after: 3528 → 3536.

`Apply-Patches.ps1` also **deletes cached modules**, which is not optional:
`moderngekko-port`'s cache key covers the DolRecomp binary hash, compiler and
flags, but *not* this header's contents — so a patched header alone would still
serve the old module from cache and fail identically.

### 2. Dolphin + MinGW needs `_WIN32_WINNT` raised

Dolphin never defines `_WIN32_WINNT` or `NTDDI_VERSION`; on MSVC the toolchain
defaults them to a Windows 10 level. **MinGW defaults to `0x0601` (Windows 7)**,
hiding newer Win32 APIs behind their version gates:

| File | Missing symbol | Introduced in |
|---|---|---|
| `Common/Timer.cpp:114` | `SetProcessInformation` | Windows 8 (`0x0602`) |
| `Common/x64CPUDetect.cpp:74` | `GetProcessInformation` | Windows 8 (`0x0602`) |
| `Common/WindowsDevice.h:100` | `HCMNOTIFICATION` | Windows 10 1709 (NTDDI) |
| `InputCommon/.../Win32.cpp:25` | `HCMNOTIFICATION` | Windows 10 1709 (NTDDI) |

The configure log confirms it outright: `Found _WIN32_WINNT=0x0601`.
`Build-Tools.ps1` therefore passes, for non-MSVC generators only:

```
-D_WIN32_WINNT=0x0A00 -DWINVER=0x0A00 -DNTDDI_VERSION=0x0A000004
```

Verified with `Test-WinApiFix.ps1`, which recompiles a failing file twice using
the command taken from `ninja -t commands` — once as the build runs it, once
with the API level raised. Both gates were confirmed independently: `Timer.cpp`
for `_WIN32_WINNT`, `WindowsDevice.cpp` for the separate `NTDDI_VERSION`
(`cfgmgr32.h`) gate.

### 3. Empty `GCPadNew.ini` stub deadlocks controller setup

On a GameCube branded build the launcher refuses to start with:

```
GCPadNew.ini has no configured controller device
```

Dolphin's config system creates the controller profile as a **0-byte stub** on
startup (alongside `FreeLook.ini`, `GCKeyNew.ini` and others). The launcher's
check was existence-only:

```cpp
bool ControllerConfigExists(...) {
  return fs::is_regular_file(ControllerConfigPath(user_directory), ec);
}
```

so the stub counts as "configured". `ReadConfiguredControllers()` then finds no
`[GCPad1]` section, and the caller bails — while the code that would *write* a
profile is only reached when the file is absent. The profile can never be
created. `EnsureControllerConfig()` is fooled the same way and reports "using
existing controller profile" for an empty file.

`patches/moderngekko-controller-stub.patch` makes the check ask whether a usable
device is configured rather than whether a file exists.

Note also that `MODERNGEKKO_GAMECUBE_CONTROLLERS` defaults **OFF**, so the
frontend writes Wii Remote profiles (`[Wiimote1]`) and leaves `GCPadNew.ini`
empty even when a pad is selected. `Build-Tools.ps1` sets it ON by default.

### 4. `dolrecomp extract` and gitlab-hosted bzip2

Dolphin pins `Externals/bzip2` to `https://gitlab.com/bzip2/bzip2.git`, which
returns HTTP 403. `Init-Repo.ps1` rewrites it to
`https://github.com/libarchive/bzip2.git`, which carries the **same pinned
commit** (`6a8690fc8d26c815e798c588f796eabe9d684cf0`) — so the checkout is
byte-identical to upstream's intent, not a version substitution.

### 5. Exit-time `0xC0000005` — the window outliving the config

`Runtime::~Runtime()` called `UICommon::Shutdown()` — and so `Config::Shutdown()`,
which clears every config layer — *before* `~PlatformWin32()` destroyed the render
window. `DestroyWindow()` dispatches `WM_KILLFOCUS` into the window procedure
synchronously, and that handler does:

```cpp
Config::SetCurrent(Config::MAIN_EMULATION_SPEED, 1.0f);   // PlatformWin32.cpp:406
```

`Config::Set` is `GetLayer(layer)->Set(...)` with no null check (`Config.h:114`),
so with the layers already gone the window's own destruction killed the process:

```
~Runtime -> ~PlatformWin32 -> WndProc -> Config::Set<float>
         -> Config::GetLayer (null) -> Config::Layer::Set   ← read of 0x20
```

It surfaced as `0xC0000005` when the runner was launched directly and
`0xC000041D` (`FATAL_USER_CALLBACK_EXCEPTION`) through the launcher — the same
fault, wrapped because it was raised inside a user callback.
`moderngekko-shutdown-order.patch` destroys the window first, restoring plain
reverse-of-construction order.

### 6. thread_local PRNG destructor faulting at thread detach

`Common/Random.cpp` declares `static thread_local EntropySeededPRNG s_esprng`.
MinGW runs thread_local destructors from a TLS callback (`run_dtor_list`) at
thread and process detach, by which point the thread's storage is already
released, so `~EntropySeededPRNG` freed dead memory:

```
tls_callback -> run_dtor_list -> ~EntropySeededPRNG
             -> mbedtls_hmac_drbg_free -> mbedtls_md_free   ← 0xC0000005
```

This was invisible until issue 5 was fixed — the process used to die in the
config teardown before it ever reached thread detach.
`dolphin-tls-prng-leak.patch` makes it a never-deleted pointer: a few hundred
bytes per thread that draws randomness, in exchange for removing the whole class
of shutdown-ordering faults.

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

### Hooks cannot change behaviour

`ModManager::Dispatch` saves the CPUState, calls each entry hook, then restores
it, and returns `false` when no patch is registered so the original still runs.
Changing behaviour requires `RECOMP_PATCH`, which replaces the function.

### Packaging

A `.mgm` package is a *directory* named `<mod-id>.mgm` containing the platform
library under the exact name `mod` (`mod.dll`). Anything else is reported as
"package has no platform mod library". The runner searches `<exe dir>\Mods`
and `<user dir>\Mods`; `--mods <path>` adds a specific package or directory
and `--no-mods` suppresses only the two defaults.

## Branded launcher and the shipping layout

`Build-Tools.ps1 -WithLauncher` builds the ImGui/SDL3 launcher, which browses
for an ISO, extracts it and plays. Two options make it work for one game:

* `-DiscId GBGE5G` — **required**. `PrepareDisc()` has its only accept path
  inside `#ifdef MODERNGEKKO_REQUIRED_DISC_ID`; without it every disc is
  rejected with "this disc is not the pinned patched release" (the `#else`
  branch, whose `#if` side is hardcoded Sonic Riders logic upstream).
* `-PortableUserDir` — keeps config, saves and logs in `User\` beside the
  executable instead of `%LOCALAPPDATA%\moderngekko`.

The launcher does **not** pass `--module`, so the runner falls back to its own
search order:

1. `--module <path>` (what `moderngekko-port` uses)
2. `$env:STATICRECOMP_MODULE`
3. `<exe dir>\g<DISCID>_recomp.dll`  ← the shipping layout
4. `<user dir>\StaticRecompModules\g<DISCID>_recomp.dll`

Without one of these it fails with "no native module was supplied".
`Install-Module.ps1` puts the built module at option 3. A distributable folder
therefore looks like:

```
ModernGekko.exe          launcher
moderngekko-run.exe      runner
gGBGE5G_recomp.dll       the recompiled game
Mods/                    loaded from beside the executable
User/                    config, saves, logs (portable build)
```

## Toolchain: Ninja + MinGW GCC

```powershell
.\scripts\Build-Tools.ps1 -RepoRoot <repo> -Generator Ninja
```

Upstream's template builds with `-G Ninja`, and MinGW GCC is what this project
is known to build with. `moderngekko-port --toolchain auto` follows whichever
compiler built it, so the per-game module compiles with the same GCC. Keep one
toolchain throughout — mixing ABIs between runtime and module is not worth the
risk.

Upstream drives this with a `Makefile`, replaced here by PowerShell scripts
deliberately: MSYS2's login shell does not inherit the Windows PATH, so running
that make from MSYS2 puts `cmake` and the compiler out of reach.

`Build-Tools.ps1` refuses to reconfigure a build directory whose generator
differs from the one requested, reporting how many objects are already compiled
rather than silently discarding the work. Pass `-Fresh` to discard deliberately.

Note this is upstream-unsupported territory: Dolphin's supported Windows
toolchain is MSVC, which is why issue 2 above had gone unnoticed.

## Licence

This repository is **GPL-3.0-or-later**. ModernGekko is GPL-3.0-or-later with
Dolphin (GPL-2.0+) underneath, and linking against it makes the combined work
GPL-3.0.

Recompiled game code cannot be distributed under any licence — it is derived
from Nintendo's binary. Each user supplies their own dump.

## Legal

This repository contains no copyrighted game code or assets. Recompiled output
is derived from a disc image you must dump yourself, from a disc you own, and is
never committed.
