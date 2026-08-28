# Building from source

Everything here is Windows + Ninja + MinGW-w64 GCC. Nothing in this document is
needed to *play* the game -- see the release for that.

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
