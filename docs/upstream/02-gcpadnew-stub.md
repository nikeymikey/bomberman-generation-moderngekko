**Title:** Empty `GCPadNew.ini` stub makes `ControllerConfigExists()` permanently true, blocking launch

*Context: porting Bomberman Generation (USA, `GBGE5G`) to Windows with the C
backend, Ninja + MinGW-w64 GCC, against ModernGekko `5417826` and DolRecomp
`1bec355`. The game now runs natively. A patch is available if useful.*

## What happens

After one successful launch, the frontend refuses to start with

```
GCPadNew.ini has no configured controller device
```

and never recovers, because the condition that produces the error is also the
condition that makes the check believe the profile exists.

## Cause

`ControllerConfigExists()` treats *the file existing* as *a controller being
configured*. Dolphin's config system creates `GCPadNew.ini` as an empty stub
during normal startup, so the file exists while containing no device.

## Fix

Make existence mean a usable device is present:

```cpp
bool ControllerConfigExists(const fs::path &user_directory)
{
  std::error_code ec;
  if (!fs::is_regular_file(ControllerConfigPath(user_directory), ec))
    return false;
  // Dolphin's config system creates the profile as an empty stub on startup.
  return !ReadConfiguredControllers(user_directory).empty();
}
```

## Related, and arguably the root of it

`MODERNGEKKO_GAMECUBE_CONTROLLERS` must be `ON` or the frontend writes
`WiimoteNew.ini` (`[Wiimote1]` sections) and leaves `GCPadNew.ini` empty — so a
GameCube pad appears selected in the launcher while having no bindings at all.

For a GameCube title this is not really an option. Defaulting it from the disc's
platform would remove a whole class of "the pad does nothing" reports.
