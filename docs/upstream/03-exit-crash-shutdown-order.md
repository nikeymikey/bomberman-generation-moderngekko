**Title:** Access violation on exit: the render window is destroyed after `Config::Shutdown()`

*Context: porting Bomberman Generation (USA, `GBGE5G`) to Windows with the C
backend, Ninja + MinGW-w64 GCC, against ModernGekko `5417826` and DolRecomp
`1bec355`. The game now runs natively. A patch is available if useful.*

## What happens

Every session ends in a crash after the game has cleanly shut down — the
`[staticrecomp] shutdown:` stats line prints first. It appears as

* `0xC0000005` running `moderngekko-run` directly
* `0xC000041D` (`FATAL_USER_CALLBACK_EXCEPTION`) through the launcher

which is the same fault, wrapped because it is raised inside a window-procedure
callback.

## Cause

Diagnosed from a WER minidump; the faulting frame is `Config::Layer::Set`
reading offset `0x20` of a null pointer, reached from:

```
~Runtime -> ~PlatformWin32 -> WndProc -> Config::Set<float>
         -> Config::GetLayer (returns null) -> Config::Layer::Set
```

`Runtime::~Runtime()` (`src/runtime/dolphin_runtime.cpp:756`) calls
`UICommon::Shutdown()` — and therefore `Config::Shutdown()`, which does
`s_layers.clear()` — **before** `m_impl` is destroyed and `~PlatformWin32()`
calls `DestroyWindow()`.

`DestroyWindow()` dispatches `WM_KILLFOCUS` into the window procedure
synchronously, and that handler does:

```cpp
Config::SetCurrent(Config::MAIN_EMULATION_SPEED, 1.0f);   // PlatformWin32.cpp:406
```

`Config::Set` is `GetLayer(layer)->Set(...)` with no null check
(`Config.h:114`), so with the layers gone the window's own destruction
dereferences null.

## Fix

Destroy the render window before `UICommon::Shutdown()`, restoring
reverse-of-construction order. Clearing `s_platform` first keeps host callbacks
from reaching a dying platform while its remaining messages are dispatched.

## Broader point

`Config::Get`, `Config::Set` and `Config::DeleteKey` all dereference
`GetLayer()` unchecked. Teardown ordering is one route to a null layer; it seems
unlikely to be the only one.
