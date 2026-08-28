**Title:** On the C backend, `--map` recompiles everything to emit a header while producing identical code

*Context: porting Bomberman Generation (USA, `GBGE5G`) to Windows with the C
backend, Ninja + MinGW-w64 GCC, against ModernGekko `5417826` and DolRecomp
`1bec355`.*

**Repository: DolRecomp.**

Passing `--map` to a C-backend build triggers a full recompilation and emits
byte-identical generated code. The map's only effect is `<stem>_symbols.h`.

Tracing it: symbols reach codegen solely through `collect_llvm_entry_points()`,
which is the **LLVM** backend's entry-point seed. The C path (`pipeline.c`) uses
the map only to call `emit_symbol_definitions()`, and partitions on the fixed
`c_chunk_instructions()` regardless.

That is entirely reasonable behaviour — but it is expensive to discover. For
this game a module rebuild is 112 MB of generated C across 105 files. I now run
DolRecomp's codegen step alone into a scratch directory and keep only the
header, which is far quicker and produces the same result.

**Suggestion:** a line in `--map`'s help text saying it affects codegen on the
LLVM backend and only symbol output on the C backend. That is all it would have
taken.

## Smaller note on the same path

`symbol_map.c`'s `parse_line()` accepts a bare `<hex address> <name>` two-token
form, and `resolved_size()` derives a size from the next symbol when none is
given. That combination makes it trivial to generate a usable map from analysis
rather than from a linker — I generate one from `bl` targets decoded out of the
DOL. Genuinely useful, and not obvious from the docs, which describe it as "a
linker MAP".
