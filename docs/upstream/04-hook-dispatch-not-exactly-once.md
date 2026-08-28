**Title:** Mod hooks can fire more than once per guest call (`m_host_call_passthrough` is a single-shot flag)

*Context: porting Bomberman Generation (USA, `GBGE5G`) to Windows with the C
backend, Ninja + MinGW-w64 GCC, against ModernGekko `5417826` and DolRecomp
`1bec355`. The game now runs natively. A patch is available if useful.*

**No patch offered** — see the last section.

## What happens

An entry hook can be invoked twice for a single guest call. This is silent, and
it corrupts any mod that counts, accumulates, or advances a state machine.

## Measurement

A mod hooking the DOL entry point — which executes exactly once at boot —
recording the guest `lr` and stack pointer on each fire:

```
0x80003140  fires=2  same-(lr,sp) repeats=1  first_lr=0x00000000  second_lr=0x00000000
```

Identical `lr` **and** stack pointer, on an address that runs once: one call,
dispatched twice.

Across longer sessions on an ordinary function, duplicates ran between **2% and
17%** of fires, the rate rising with load. (17% is an upper bound for that
address, since a loop calling one function repeatedly from a single call site
also yields identical `(lr, sp)` pairs. The entry point is the unambiguous
case.)

## Cause, as far as I traced it

A hook-only mod returns `false` from `ModManager::Dispatch` — correctly, since
`false` is what tells the caller "no patch replaced this, run the original".

`StaticRecompCore_Run.cpp:218` then sets `m_host_call_passthrough` and hands the
address to `Jit64`. `ShouldYieldAt` (`StaticRecompCore.cpp:129`) is meant to
consume that flag so the JIT runs straight through — but it is a **single-shot
flag with no stack**, and it is only consumed if the JIT actually consults it
for that address. A block compiled *before* the address became a host-call
address will not. The flag then survives, and the next arrival at the same `pc`
dispatches the hook again.

Possibly relevant: line 224 invalidates the block at `m_guest.lr`, not at
`m_guest.pc`.

## Why no patch

Every fix I could think of — invalidating at `pc`, making the flag a stack,
deduplicating inside `Dispatch` — is a change to a JIT/dispatch interaction I
could not validate without a full rebuild-and-play cycle per attempt. A precise
description of the defect seemed more useful than a guess with a patch attached.

## In the meantime

Mods can be written to be idempotent, and mine are. But that is a real
constraint on the mod API and is worth documenting even if the bug is not worth
fixing: **a hook may fire more than once per call.**
