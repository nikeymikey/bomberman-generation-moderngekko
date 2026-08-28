**Title:** `moderngekko-port` has no way to pass a symbol map to DolRecomp

*Context: porting Bomberman Generation (USA, `GBGE5G`) to Windows with the C
backend, Ninja + MinGW-w64 GCC, against ModernGekko `5417826` and DolRecomp
`1bec355`.*

`moderngekko-port build` constructs the DolRecomp command line itself, so there
is no way to supply `--map` through the normal build path. Without a map,
DolRecomp emits no `<stem>_symbols.h` at all, and `mod-template`'s
`MOD_SYMBOL_HEADER` option has nothing to consume — mods are stuck writing raw
addresses.

I have this working as a patch that:

* adds `--map <path>` to `port_command_line.hpp` and appends it to the
  DolRecomp invocation, and
* folds the map file's SHA-256 into the module cache identity, so **editing a
  map rebuilds**.

That second part matters: the map changes generated output, so without it,
adding or changing a map would silently reuse a module built without one.
Hashing the contents rather than the path means renaming the file does not force
a rebuild while editing it does.

Happy to open a PR if the approach looks right.
