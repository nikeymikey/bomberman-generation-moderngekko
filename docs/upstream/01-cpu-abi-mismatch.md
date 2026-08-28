**Title:** `CPUState` ABI mismatch between GXRuntime and `mod_abi` rejects every generated GameCube module

*Context: porting Bomberman Generation (USA, `GBGE5G`) to Windows with the C
backend, Ninja + MinGW-w64 GCC, against ModernGekko `5417826` and DolRecomp
`1bec355`. The game now runs natively. A patch is available if useful.*

## What happens

Every freshly generated module is refused at load with `CPU ABI mismatch`. There
is no partial failure and no further detail.

## Cause

Two declarations of the same ABI disagree:

* `GXRuntime/include/core/cpu.h` — `#define GXRUNTIME_CPU_ABI_VERSION 3u`
* `include/moderngekko/cpu_state.h` — `#define MODERNGEKKO_CPU_ABI_VERSION 4u`

and the version-4 `struct CPUState` carries a field the version-3 header lacks:
`s64 cycle_budget`, immediately after `s64 downcount`.

`ModManager::Load` rejects on

```cpp
desc->cpu_abi_version != MODERNGEKKO_CPU_ABI_VERSION ||
desc->cpu_state_size  != sizeof(CPUState)
```

and the static-recomp core makes the equivalent comparison for the module
itself, so nothing can load.

## Fix

Add `s64 cycle_budget;` after `s64 downcount;` in the GXRuntime header and bump
`GXRUNTIME_CPU_ABI_VERSION` to `4u`. That is the entirety of the patch I am
using.

## Second-order problem worth fixing at the same time

Generated modules embed `sizeof(CPUState)`, but **the module cache key does not
cover this header**. After correcting the mismatch, cached modules built against
the old layout are still selected and still fail, so the fix appears not to
work. I had to clear the module cache manually before the correct behaviour
appeared.

Folding the header's hash into the cache identity (alongside the existing
`dolrecomp_binary` hash and `DolRecompCodegenIdentity()`) would remove a
confusing second failure for the next person.
