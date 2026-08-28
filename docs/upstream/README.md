# Upstream submissions

One file per issue, each self-contained and ready to paste. Open a new issue in
the repository named below, use the `**Title:**` line as the title, and paste
the rest of the file as the body.

`../../UPSTREAM-REPORT.md` is the same material as a single narrative document,
for linking to from an issue or sending as a whole.

## ExpansionPak/ModernGekko

Submit **01 and 02 first**. They block anyone attempting a GameCube port before
they see anything work at all, and everything else is downstream of getting past
them.

| File | Issue | Patch |
|---|---|---|
| [01-cpu-abi-mismatch.md](01-cpu-abi-mismatch.md) | `CPUState` ABI drift rejects every generated module | yes |
| [02-gcpadnew-stub.md](02-gcpadnew-stub.md) | Empty `GCPadNew.ini` stub permanently blocks launch | yes |
| [03-exit-crash-shutdown-order.md](03-exit-crash-shutdown-order.md) | Access violation on exit: window outlives the config | yes |
| [04-hook-dispatch-not-exactly-once.md](04-hook-dispatch-not-exactly-once.md) | Hooks can fire twice per guest call | no — see below |
| [05-mingw-win32-winnt.md](05-mingw-win32-winnt.md) | MinGW builds fail without `_WIN32_WINNT` | yes |
| [06-bzip2-submodule-403.md](06-bzip2-submodule-403.md) | `Externals/bzip2` URL returns HTTP 403 | yes |
| [07-port-no-map-option.md](07-port-no-map-option.md) | `moderngekko-port` cannot pass `--map` | yes |
| [08-documentation-gaps.md](08-documentation-gaps.md) | Three undocumented mod-API properties | n/a |

## ExpansionPak/DolRecomp

| File | Issue | Patch |
|---|---|---|
| [10-map-no-codegen-effect.md](10-map-no-codegen-effect.md) | `--map` recompiles everything for a header on the C backend | n/a |

## Dolphin

| File | Issue | Patch |
|---|---|---|
| [09-dolphin-tls-prng-mingw.md](09-dolphin-tls-prng-mingw.md) | `thread_local` PRNG destructor faults at thread detach on MinGW | workaround |

Dolphin may not treat MinGW as supported. If it is turned away, ModernGekko
still wants it — the fault is reachable in their vendored copy, and it is what
becomes visible once issue 03 is fixed.

## Notes on submitting

**04 has no patch, deliberately.** Every candidate fix touches a JIT/dispatch
interaction that could not be validated without a full rebuild-and-play cycle
per attempt. The issue describes the mechanism precisely and says so. Do not let
it get downgraded to "works for me" — the measurement (an address that executes
once, firing twice, with identical `lr` and stack pointer) is the evidence.

**Patches are in `../../patches/`** and apply to the revisions named in each
issue. They are offered as-is; several are not how upstream would want to fix
these, and each issue says what the defect is independently of the patch.

**If asked for a repro project**, this repository is it, and the patch table in
`scripts/Apply-Patches.ps1` shows each fix applied in order with a marker that
verifies it took effect.
