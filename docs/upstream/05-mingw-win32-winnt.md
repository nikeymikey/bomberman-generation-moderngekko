**Title:** MinGW builds fail on Win8/Win10 APIs because `_WIN32_WINNT` is never defined

*Context: porting Bomberman Generation (USA, `GBGE5G`) to Windows with the C
backend, Ninja + MinGW-w64 GCC, against ModernGekko `5417826` and DolRecomp
`1bec355`.*

Dolphin never defines `_WIN32_WINNT` or `NTDDI_VERSION`. MSVC's toolchain
defaults them to a Windows 10 level, so this is invisible there. **MinGW-w64
defaults to `0x0601` (Windows 7)**, so Win8/Win10 APIs Dolphin calls are hidden
behind version gates and the build fails on symbols that plainly exist in the
headers.

Defining these for MinGW builds fixes it:

```
_WIN32_WINNT=0x0A00
NTDDI_VERSION=0x0A000004
```

Both gates were confirmed independently by recompiling a single translation unit
with and without the definitions, rather than by adding them and observing that
the build passed.

The second is needed separately from the first: some declarations
(`HCMNOTIFICATION` and friends) are gated on `NTDDI_VERSION` rather than
`_WIN32_WINNT`.
