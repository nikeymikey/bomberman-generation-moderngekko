Bomberman Generation - native PC build
======================================

This is the GameCube game Bomberman Generation, statically recompiled to run
natively on Windows. It is not an emulator preset: the game's PowerPC code is
translated to C and compiled for your CPU.

You must supply your own disc image. None is included, and none will be.

This folder was assembled by scripts/Build-Release.ps1 from a source build. It
is not published as a download: the executables are unsigned, and Windows Smart
App Control blocks unsigned applications outright. Running unsigned binaries
someone sent you is your decision to make knowingly.


WHAT YOU NEED
-------------

  * A disc image of Bomberman Generation (USA), disc ID GBGE5G, dumped from
    your own copy. .iso, .rvz and .wbfs all work.
  * A gamepad. Keyboard play is not configured by default.


FIRST RUN
---------

1. Run ModernGekko.exe.
2. Choose your disc image. It is extracted once, into User\games.
3. Press "Build and Play".

The first launch COMPILES THE GAME and takes several minutes - on the order of
ten on a typical machine. This happens once. Afterwards the button says "Play"
and starts immediately.

The build step exists because the recompiled game code is derived from
Nintendo's binary and cannot legally be distributed. Everyone compiles it from
the disc image they own. That is also why this download does not contain
anything that would let it run without your disc image.

If the build fails saying a C compiler is required, this folder was assembled
without a bundled toolchain. Install MinGW-w64 GCC and make sure gcc is on your
PATH, or re-assemble with -ToolchainPath.


SETTINGS
--------

Everything is in the launcher window:

  Graphics backend    Vulkan or OpenGL
  Internal resolution the render resolution, independent of window size
  Widescreen          16:9 instead of the original 4:3
  Fullscreen
  Controller profile
  Mods                enable, disable, and configure - see below

Config, saves and logs live in User\ beside the executable. Delete that folder
to reset everything. Nothing is written to your Documents folder or registry.


MODS
----

Mods are folders named <something>.mgm inside Mods\. Drop one in and it appears
in the launcher with a checkbox; some have settings shown underneath.

Included:

  Battle: Starting Bombs (All Players)
      Every player begins a Battle match with the chosen number of bombs,
      1 to 8, instead of 1. Bomb powerups still work and still cap at 8.
      Story mode is unaffected.

Mods only load when ticked, and the choice is remembered.


TROUBLESHOOTING
---------------

  "this disc is not the pinned patched release"
      The disc image is not Bomberman Generation (USA). Only GBGE5G is
      supported; other regions have different code addresses.

  "no native module was supplied"
      The first-run build has not completed. Press "Build and Play".

  No controller
      Connect the gamepad before starting the launcher, then pick it in the
      Controller profile dropdown.

  Logs
      User\Logs\ModernGekko.log


LICENCE
-------

GPL-3.0-or-later. Built on ModernGekko and DolRecomp by ExpansionPak, which are
in turn built on the Dolphin emulator (GPL-2.0-or-later). See LICENSE.

The repository these binaries were built from is the corresponding source for
them. No game code or assets are included here.
