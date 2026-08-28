# Porting notes

What DolRecomp and ModernGekko actually make of this game, and the seven
upstream defects that had to be fixed to get it running. Reported upstream in
`UPSTREAM-REPORT.md`.

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
