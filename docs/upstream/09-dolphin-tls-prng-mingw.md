**Title:** [MinGW] `thread_local EntropySeededPRNG` destructor faults at thread detach

*Context: porting Bomberman Generation (USA, `GBGE5G`) to Windows with the C
backend, Ninja + MinGW-w64 GCC, against ModernGekko `5417826` and DolRecomp
`1bec355`.*

**Repository: Dolphin (also affects ModernGekko's vendored copy).**

`Common/Random.cpp` declares:

```cpp
static thread_local EntropySeededPRNG s_esprng;
```

MinGW runs `thread_local` destructors from a TLS callback (`run_dtor_list`) at
thread and process detach, by which point the thread's storage may already be
released. The destructor then frees dead memory:

```
tls_callback -> run_dtor_list -> ~EntropySeededPRNG
             -> mbedtls_hmac_drbg_free -> mbedtls_md_free   ← 0xC0000005
```

Recovered from a WER minidump. It is silent in the sense that the process exit
status is already fixed by then, but it still writes a crash dump and can raise
a "stopped working" dialog.

It was invisible in our build until a separate shutdown-ordering crash was
fixed — the process previously died before ever reaching thread detach.

## Workaround in use

Making it a never-deleted pointer, constructed on first use:

```cpp
static thread_local EntropySeededPRNG* s_esprng = nullptr;
```

which costs a few hundred bytes per thread that draws randomness, for the
process lifetime, and removes the whole class of shutdown-ordering faults.

I appreciate MinGW may not be a supported configuration, in which case treat
this as a note for whoever tries it next rather than a bug report.
