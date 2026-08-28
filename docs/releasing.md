# Releasing

Why the recompiled module can never be distributed, and what that forces the
release to look like.

## Branded launcher and the shipping layout

`Build-Tools.ps1 -WithLauncher` builds the ImGui/SDL3 launcher, which browses
for an ISO, extracts it, compiles it on first run, and plays. Two options make
it work for one game:

* `-DiscId GBGE5G` — **required**. `PrepareDisc()` has its only accept path
  inside `#ifdef MODERNGEKKO_REQUIRED_DISC_ID`; without it every disc is
  rejected with "this disc is not the pinned patched release" (the `#else`
  branch, whose `#if` side is hardcoded Sonic Riders logic upstream).
* `-PortableUserDir` — keeps config, saves and logs in `User\` beside the
  executable instead of `%LOCALAPPDATA%\moderngekko`.

### What may not ship

**The recompiled module cannot be distributed.** `g<DISCID>_recomp.dll` is the
game's own code translated to another language; distributing it distributes the
game. Every recipient compiles it from the disc image they supply.

This is not a licensing footnote, it is the constraint the whole release design
follows from. An earlier version of this section listed the module in the
distributable folder while the Licence section said it could not be
distributed; both cannot be true.

### The distributable folder

```
ModernGekko.exe          launcher
moderngekko-run.exe      runner
moderngekko-port.exe     drives the first-run build
dolrecomp.exe            the recompiler
Mods/                    loaded from beside the executable
toolchain/               optional bundled MinGW-w64
README.txt  LICENSE  manifest.txt
```

`Build-Release.ps1` assembles it and then **scans the finished folder** for
anything game-derived — `g*_recomp.*`, `.dol`, `.iso`, `.rvz`, `.wbfs`, `.gcm`
— deleting the whole output and failing if it finds any. The scan exists
because `g<DISCID>_recomp.dll` sits directly beside the executables in the build
directory, so a slightly-too-broad copy ships the game. Trusting the copy list
is not the same as checking the result.

Dolphin's `Sys` directory is deliberately absent. `CreateSysDirectoryPath()`
looks for `Sys\` beside the executable on Windows; there is none, and the game
runs regardless, so shipping one would be cargo cult.

### First run

The launcher compiles the module itself (`moderngekko-first-run-build.patch`).
`ModuleReady()` mirrors the runner's search order, and while no module exists
the Play button reads **Build and Play**. The build output goes to
`<user dir>/StaticRecompModules/`, the runner's fourth search location, rather
than beside the executable: a release unpacked into Program Files is not
writable, and the user directory always is.

A bundled `toolchain/bin` is **prepended** to `PATH` before spawning
`moderngekko-port`, which resolves the compiler by bare name. Prepended rather
than appended so the shipped compiler wins over whatever the machine already
has, which is what makes the recipient's build reproducible.

Progress is indeterminate on purpose: `moderngekko-port` reports nothing the
launcher can read without piping its output, and an invented percentage would
be a lie.

### Runner module search order

1. `--module <path>` (what `moderngekko-port` uses)
2. `$env:STATICRECOMP_MODULE`
3. `<exe dir>\g<DISCID>_recomp.dll` — a developer build, never a release
4. `<user dir>\StaticRecompModules\g<DISCID>_recomp.dll` — the first-run build

Without one of these it fails with "no native module was supplied".

### Distributing binaries

These binaries are built from GPL sources (ModernGekko and DolRecomp are
GPL-3.0-or-later; Dolphin underneath is GPL-2.0-or-later). Distributing them
carries an obligation to offer the corresponding source to recipients, which
means the repository has to be reachable at the tagged commit.

## Why this project ships source, not binaries

Decided after testing an assembled release on a clean laptop rather than on the
machine that built it. Two things came out of that test, and only one of them
was what it looked like.

### Unsigned binaries are blocked, and there is no instruction around it

`ModernGekko.exe` would not start until a Windows security feature was disabled.
Microsoft's documented behaviour for Smart App Control is to check cloud
reputation, fall back to signature checking, and treat anything unsigned as
untrusted; their stated remedy is to sign the application. There is no "More
info -> Run anyway" for it as there is for SmartScreen.

Telling people to turn off protection to run a hobby project is not acceptable,
and code signing (an OV/EV certificate, annual cost, identity verification) is
not proportionate here. So the project publishes source. Anyone who builds it
has already made an informed decision about running their own binaries.

Bundling a compiler would have made this worse rather than better: several
hundred more unsigned executables, and a first run whose behaviour is
"unsigned program launches a compiler and writes a DLL", which is a reasonable
thing for a heuristic scanner to dislike.

### The missing Play button was not a bug

The same test showed no "Build and Play" button. That is the pre-existing
behaviour: the button is inside `if (current_metadata)`, and with a fresh
`User\` directory there is no extracted game, so the launcher shows "No
extracted game is configured yet." until a disc image is selected. Worth
recording because it looked like a symptom of the security problem and was not
related to it at all.

### What survives

The first-run build (`moderngekko-first-run-build.patch`) is not wasted work —
it is what makes a *source* build usable, since the module still cannot be
distributed and still has to be compiled from the user's own disc image.
`Build-Release.ps1` also stays: it assembles a folder, proves it is
self-contained by reading the PE import tables, and proves it contains nothing
game-derived. That is useful for moving your own build between your own
machines. It is not a download.
