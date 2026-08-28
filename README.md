# Bomberman Generation — native PC build

**Bomberman Generation** (NTSC-U, `GBGE5G`) statically recompiled to run
natively on Windows. Not an emulator configuration: the game's PowerPC code is
translated to C and compiled for your CPU, using
[DolRecomp](https://github.com/ExpansionPak/DolRecomp) and
[ModernGekko](https://github.com/ExpansionPak/ModernGekko), a Dolphin-derived
runtime.

**Status: playable.** Widescreen, GameCube controller support, savestates,
netplay, and a mod system with a working gameplay mod.

## You supply the game

**This project contains no game code, assets or disc images, and never will.**
You need your own dump of Bomberman Generation (USA), from a disc you own.

The recompiled module — the game's code translated to another language — is
derived from Nintendo's binary and **cannot be distributed under any licence**.
Downloads therefore do not contain it. Instead the launcher compiles the module
on your machine, once, from the disc image you provide.

That constraint shapes everything else here. It is why the first launch takes
several minutes, and why there is a compiler in the download.

## Getting it running

**Build it from source** — see [docs/building.md](docs/building.md). You need
CMake, Ninja, MinGW-w64 GCC and a disc dump. The scripts do the rest, and the
launcher compiles the game for your CPU on first run.

### Why there are no downloads

Distributing binaries would mean distributing **unsigned** executables. Windows
Smart App Control checks cloud reputation, falls back to signature checking, and
treats anything unsigned as untrusted — and Microsoft's remedy is to sign the
application, not to instruct users past it. Tested on a clean laptop: the
launcher would not start until a security feature was turned off.

Asking people to disable protection to run a hobby project is not something this
repository will do, so it publishes source rather than binaries. Code signing
would fix it, and is not worth a certificate and identity verification for this.

`scripts/Build-Release.ps1` still assembles a distributable folder — useful for
copying your own build between your own machines, and it verifies the result is
self-contained and free of game-derived files. It is not a download.

## Features

* **Native execution** — no interpreter, no JIT for the game's own code
* **Widescreen** 16:9, or the original 4:3
* **Internal resolution** independent of window size
* **Vulkan or OpenGL**
* **GameCube controller** support with profiles
* **Savestates** and netplay
* **Mods** — enable, disable and configure from the launcher

### Included mod

**Battle: Starting Bombs (All Players)** — every player begins a Battle match
with 1 to 8 bombs instead of 1, chosen from a dropdown. Bomb powerups still work
and still cap at 8. Story mode is unaffected.

## Documentation

| | |
|---|---|
| [docs/building.md](docs/building.md) | Building from source: scripts, layout, toolchain |
| [docs/modding.md](docs/modding.md) | Writing mods, what a hook costs and cannot do, a worked example |
| [docs/porting-notes.md](docs/porting-notes.md) | What the toolkit makes of this game, and the defects fixed to get here |
| [docs/releasing.md](docs/releasing.md) | Why the module cannot ship, and what that forces |
| [UPSTREAM-REPORT.md](UPSTREAM-REPORT.md) | Findings reported to ExpansionPak |

## Licence

**GPL-3.0-or-later.** ModernGekko is GPL-3.0-or-later with Dolphin
(GPL-2.0-or-later) underneath, and linking against it makes the combined work
GPL-3.0.

Distributed binaries are built from these sources, and this repository is the
corresponding source for them.

Recompiled game code cannot be distributed under any licence — it is derived
from Nintendo's binary. Each user supplies their own dump.

## Legal

This repository contains no copyrighted game code or assets. Recompiled output
is derived from a disc image you must dump yourself, from a disc you own, and is
never committed.

The ignore rules are verified by `scripts/Verify-Gitignore.ps1` against
`git add -An` ground truth, `scripts/Check-BeforePush.ps1` audits the whole
commit history before anything is pushed, and `scripts/Build-Release.ps1` scans
every assembled release for game-derived files and destroys the output if it
finds any.

Bomberman Generation is © Hudson Soft / Konami. This project is not affiliated
with, endorsed by, or connected to Hudson Soft, Konami or Nintendo.
