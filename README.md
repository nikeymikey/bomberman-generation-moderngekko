# Bomberman Generation — ModernGekko recomp

Static recompilation of **Bomberman Generation (NTSC-U, `GBGE5G`)** using
[DolRecomp](https://github.com/ExpansionPak/DolRecomp) (CPU → C) and
[ModernGekko](https://github.com/ExpansionPak/ModernGekko) (Dolphin-derived
runtime).

No game code, assets or disc images are committed. Ignore rules are verified
by `scripts/Verify-Gitignore.ps1`, not assumed.

## Status: running

Bomberman Generation (NTSC-U) runs as native x86-64 code via DolRecomp +
ModernGekko. Two upstream bugs had to be fixed to get there, both documented
below and both worth reporting to ExpansionPak:

1. Dolphin + MinGW needs `_WIN32_WINNT` raised (it relies on MSVC defaults).
2. The vendored GXRuntime `CPUState` is one ABI revision behind ModernGekko's,
   so no generated module can load. See `patches/`.

## Why this toolkit rather than gcrecomp

The first attempt used [gcrecomp](https://github.com/sp00nznet/gcrecomp). It got
a long way — 5528 functions recompiled, clean MSVC build, booted through
runtime/DVD/D3D11/audio/input init and into PowerPC code — then stopped dead
issuing a DVD read. Findings from that attempt, all verified in source:

* `hw_write32_hle` has **no handler for the DVD DMA registers** (`DICR`,
  `DIMAR`, `DILENGTH`, `DICMDBUF`). The disc read is acknowledged but never
  performed, so the disc header never arrives in RAM.
* EXI DMA clears TSTART so `__OSInitSram` "succeeds", but transfers no data —
  the game gets 64 zero bytes of SRAM.
* The **OS HLE layer is wired to nothing**: `register_os_functions()` only
  increments a counter, and `lookup_os_func()` has zero callers anywhere in the
  repository. A symbol map would not have helped; the binding step it was meant
  to feed does not exist.
* gcrecomp's own status table marks *vertex format handling*, *draw call
  pipeline* and *TEV shader compilation* as **In Progress**, and its audio
  backend as a **stub**.

The blocking DVD fix was ~30 lines, but the road behind it meant finishing
someone else's emulator. ModernGekko *is* Dolphin's emulator — `disc_interface`,
`mmio_bus`, `gx_pipeline`, `gx_texture_decoder` all inherited working.

Measured on this exact DOL, DolRecomp decoded **every byte of both text
sections with 0 unknown opcodes** (text0: 2368 instructions, 725 code + 1643
embedded data; text1: 425,304 instructions, 425,296 code + 8 data). It sweeps
linearly and classifies data, rather than guessing function boundaries by
heuristic as gcrecomp does.

DolRecomp also warns that this DOL **may patch executable memory at runtime**,
listing 104 sites in `generated_smc.txt`. Inspected: mostly `stw` (a
conservative "this store might target code" heuristic) plus a few `icbi` in the
boot stub consistent with a normal post-apploader cache flush. Not evidence of
self-modifying code — but worth re-checking if execution ever goes somewhere
impossible.

## Facts about this game (carried over, independently verified)

| Value | Source |
|---|---|
| Game ID `GBGE5G` | disc header 0x00 (`E` = NTSC-U, `5G` = Majesco) |
| Entry point `0x80003140` | DOL header 0xE0 |
| r13 `_SDA_BASE_` = `0x8035DAC0` | `__init_registers` @ 0x80003264; `.sdata` + 0x8000 |
| r2 `_SDA2_BASE_` = `0x8035F780` | `__init_registers` @ 0x8000325C; `.sdata2` + 0x8000 |
| main.dol size | 2,195,744 bytes |
| REL modules | **None.** All 230 disc files scanned for PPC signatures: zero `mflr`/`blr` outside main.dol |

The REL result is the important one: there is no runtime-loaded code to chase.

## Licence

ModernGekko is **GPL-3.0-or-later** (Dolphin GPL-2.0+ underneath), unlike
gcrecomp's MIT. If this project is published, its source must be available under
GPL-3.0. The recompiled game code cannot be distributed regardless — it is
derived from Nintendo's binary. Each user supplies their own dump.

## Pipeline

```
Init-Repo      git init + pin lib/DolRecomp and lib/ModernGekko
Build-Tools    build dolrecomp.exe and moderngekko-port.exe
Extract-Iso    dolrecomp extract <iso> -> extracted/<slug>/
Build-Module   moderngekko-port build  -> a native module
Run-Game       moderngekko-port run    -> launch
```

Every script takes its directories as **mandatory parameters with no defaults**.

### CPU ABI mismatch: the vendored GXRuntime header is one revision behind

Symptom:

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
| `vendor/dolphin/GXRuntime/include/core/cpu.h` | `GXRUNTIME_CPU_ABI_VERSION 3u` | 3528 | the generated module |

The generated C emits `#define DOLRECOMP_CPU_HEADER "cpu/cpu.h"`, and
`cpu/cpu.h` includes `core/cpu.h` — so the module compiles against the stale
copy. The difference is exactly one field: **ABI v4 added `int64_t
cycle_budget` immediately after `downcount`**, and the GXRuntime copy never got
it. 8 bytes.

Both `ModernGekko` (`5417826`) and `RecompCore` (`55c7b02`) were at their remote
tips when this was found, so there is no upstream fix to pull. This is a live
inconsistency worth reporting upstream.

`patches/gxruntime-cpu-abi4.patch` adds the field and bumps the constant to
`4u`. Verified by measuring `sizeof(CPUState)` through the module's real include
chain before and after: 3528 → 3536.

Apply with:

```powershell
.\scripts\Apply-Patches.ps1 -RepoRoot <repo> -ModulesDir <repo>\build\modules
```

That script also **deletes the cached modules**, which is not optional:
`moderngekko-port`'s cache key covers the DolRecomp binary hash, compiler and
flags, but *not* the content of this header — so a patched header alone would
still serve the old module from cache and fail identically.

### Dolphin + MinGW needs _WIN32_WINNT raised

Dolphin never defines `_WIN32_WINNT` or `NTDDI_VERSION`. On MSVC the toolchain
defaults them to a Windows 10 level, so this never surfaces. **MinGW defaults to
`0x0601` (Windows 7)**, which hides every newer Win32 API behind its version
gate. Four files fail as a result:

| File | Missing symbol | Introduced in |
|---|---|---|
| `Common/Timer.cpp:114` | `SetProcessInformation` | Windows 8 (`0x0602`) |
| `Common/x64CPUDetect.cpp:74` | `GetProcessInformation` | Windows 8 (`0x0602`) |
| `Common/WindowsDevice.h:100` | `HCMNOTIFICATION` | Windows 10 1709 (NTDDI) |
| `InputCommon/.../Win32.cpp:25` | `HCMNOTIFICATION` | Windows 10 1709 (NTDDI) |

The configure log confirms the cause outright: `Found _WIN32_WINNT=0x0601`.

`Build-Tools.ps1` therefore passes, for non-MSVC generators only:

```
-D_WIN32_WINNT=0x0A00 -DWINVER=0x0A00 -DNTDDI_VERSION=0x0A000004
```

**Verified, not assumed.** `scripts/Test-WinApiFix.ps1` recompiles a failing
translation unit twice — once exactly as the build runs it, once with the API
level raised — using the command taken from `ninja -t commands`. `Timer.cpp`
fails with `'SetProcessInformation' was not declared` and then compiles clean.
Run it with `-Target` against another object to check a different file.

Note this is upstream-unsupported territory: Dolphin's supported Windows
toolchain is MSVC, which is why nobody has hit these gates. If further
MinGW-only breakage appears, switching to MSVC v143 (already verified present
and selectable on this machine) is the sane fallback.

### Toolchain: Ninja + MinGW GCC

```powershell
.\scripts\Build-Tools.ps1 -RepoRoot <repo> -Generator Ninja
```

The gcrecomp project used MSVC v143 because that matched *gcrecomp's* documented
build. That requirement does not carry over. This project uses **Ninja + MinGW
GCC (`C:\mingw64\bin\gcc.exe`)** because:

* Upstream's template builds with `-G Ninja` — it is the tested path.
* It is demonstrably working here: `dolrecomp.exe` built clean, and ModernGekko
  compiled 852 object files without error.
* Dolphin's primary Windows route has historically been its Visual Studio
  solution rather than CMake+MSVC, making CMake+MSVC the less-trodden option.

`moderngekko-port --toolchain auto` follows whichever compiler built it, so the
per-game module compiles with the same MinGW GCC. Keep one toolchain
throughout — mixing ABIs between runtime and module is not worth the risk.

Upstream drives this with a `Makefile`, which these PowerShell scripts replace
deliberately: MSYS2's login shell does not inherit the Windows PATH, so running
that make from MSYS2 would put `cmake` and the compiler out of reach.

`Build-Tools.ps1` refuses to reconfigure a build directory whose generator
differs from the one requested, reporting how many objects are already compiled,
rather than silently discarding the work. Pass `-Fresh` to discard deliberately.
