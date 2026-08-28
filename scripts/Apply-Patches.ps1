<#
.SYNOPSIS
    Apply local patches to the vendored submodules, and invalidate only what
    each patch actually makes stale.
.DESCRIPTION
    Patches live in patches/ and are applied to different repositories, so this
    keeps an explicit table rather than globbing a directory.

    Safe to re-run: an already-applied patch is detected and skipped.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = 'Repository root. No default.')]
    [string] $RepoRoot,

    [Parameter(Mandatory = $true, HelpMessage = 'Module output directory to invalidate when needed. No default.')]
    [string] $ModulesDir,

    [Parameter(HelpMessage = 'Never remove cached modules, even when a patch requires it.')]
    [switch] $KeepModuleCache
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')

$patchDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'patches'

$patches = @(
    @{
        Name    = 'gxruntime-cpu-abi4'
        File    = 'gxruntime-cpu-abi4.patch'
        Repo    = 'lib\ModernGekko\vendor\dolphin'
        Marker  = @{ Path = 'GXRuntime\include\core\cpu.h'; Pattern = '^\s*s64\s+cycle_budget;' }
        # Generated modules embed sizeof(CPUState); the module cache key does
        # NOT cover this header, so cached modules must be discarded.
        ClearsModuleCache = $true
        Why     = 'vendored CPUState is one ABI revision behind; without it no module loads'
    },
    @{
        Name    = 'moderngekko-widescreen'
        File    = 'moderngekko-widescreen.patch'
        Repo    = 'lib\ModernGekko'
        Marker  = @{ Path = 'src\runtime\dolphin_runtime.cpp'; Pattern = 'MODERNGEKKO_WIDESCREEN' }
        # Runtime-only: the generated module is unaffected, so cached modules
        # stay valid and do not need rebuilding.
        ClearsModuleCache = $false
        Why     = 'adds opt-in 16:9 via MODERNGEKKO_WIDESCREEN'
    },
    @{
        Name    = 'moderngekko-widescreen-ui'
        File    = 'moderngekko-widescreen-ui.patch'
        Repo    = 'lib\ModernGekko'
        Marker  = @{ Path = 'tools\moderngekko_launcher.cpp'; Pattern = 'Widescreen \(16:9\)' }
        # Layers on top of moderngekko-widescreen: promotes the env var to a
        # config.ini key with a launcher checkbox. Runtime/launcher only.
        ClearsModuleCache = $false
        Why     = 'config.ini widescreen key + launcher checkbox (needs moderngekko-widescreen first)'
    },
    @{
        Name    = 'moderngekko-portable-userdir'
        File    = 'moderngekko-portable-userdir.patch'
        Repo    = 'lib\ModernGekko'
        Marker  = @{ Path = 'tools\moderngekko_run.cpp'; Pattern = 'MODERNGEKKO_PORTABLE_USER_DIRECTORY' }
        ClearsModuleCache = $false
        Why     = 'adds a portable user directory beside the executable (opt-in via CMake)'
    },
    @{
        Name    = 'moderngekko-controller-stub'
        File    = 'moderngekko-controller-stub.patch'
        Repo    = 'lib\ModernGekko'
        Marker  = @{ Path = 'tools\frontend_config.cpp'; Pattern = 'Treat a profile with no usable device' }
        ClearsModuleCache = $false
        Why     = 'stop treating Dolphin''s empty GCPadNew.ini stub as a configured controller'
    },
    @{
        Name    = 'moderngekko-shutdown-order'
        File    = 'moderngekko-shutdown-order.patch'
        Repo    = 'lib\ModernGekko'
        Marker  = @{ Path = 'src\runtime\dolphin_runtime.cpp'; Pattern = 'Destroy the render window BEFORE' }
        # Teardown ordering in ~Runtime only; the generated module is untouched.
        ClearsModuleCache = $false
        Why     = 'destroy the render window before Config::Shutdown, so DestroyWindow''s WM_KILLFOCUS does not write to a cleared config (exit-time 0xC0000005)'
    },
    @{
        Name    = 'dolphin-tls-prng-leak'
        File    = 'dolphin-tls-prng-leak.patch'
        Repo    = 'lib\ModernGekko\vendor\dolphin'
        Marker  = @{ Path = 'Source\Core\Common\Random.cpp'; Pattern = 'Deliberately a never-deleted pointer' }
        # Host-side only; the generated module never touches Common::Random.
        ClearsModuleCache = $false
        Why     = 'stop the thread_local PRNG destructor faulting in mbedtls at thread detach (silent shutdown 0xC0000005)'
    },
    @{
        Name    = 'moderngekko-mods-ui'
        File    = 'moderngekko-mods-ui.patch'
        Repo    = 'lib\ModernGekko'
        Marker  = @{ Path = 'tools\frontend_config.hpp'; Pattern = 'mods_configured' }
        # Frontend, launcher and runner argument handling only. The generated
        # module is untouched, so cached modules stay valid.
        ClearsModuleCache = $false
        Why     = 'mods= key in config.ini, launcher checkboxes, and per-package mod loading in the runner'
    },
    @{
        Name    = 'moderngekko-symbol-map'
        File    = 'moderngekko-symbol-map.patch'
        Repo    = 'lib\ModernGekko'
        Marker  = @{ Path = 'tools\port_command_line.hpp'; Pattern = 'symbol_map' }
        # Adds --map to moderngekko-port. The map is folded into the module
        # cache key by the patch itself, so changing a map rebuilds without
        # needing the cache cleared here.
        ClearsModuleCache = $false
        Why     = 'pass a linker MAP through to DolRecomp so it emits <stem>_symbols.h for mods'
    },
    @{
        Name    = 'moderngekko-mod-settings'
        File    = 'moderngekko-mod-settings.patch'
        Repo    = 'lib\\ModernGekko'
        Marker  = @{ Path = 'tools\\frontend_config.hpp'; Pattern = 'mod_settings' }
        # Frontend, launcher and runner only; the generated module is untouched.
        ClearsModuleCache = $false
        Why     = 'per-mod settings: declared in mod.ini, chosen in the launcher, stored in config.ini, delivered as environment variables'
    }
)

$needsCacheClear = $false

foreach ($p in $patches) {
    $repo    = Join-Path $RepoRoot $p.Repo
    $patch   = Join-Path $patchDir $p.File
    $marker  = Join-Path $repo $p.Marker.Path

    Write-Host ''
    Write-Host ("--- {0}" -f $p.Name) -ForegroundColor Cyan
    Write-Host ("    {0}" -f $p.Why) -ForegroundColor DarkGray

    if (-not (Test-Path $patch))  { throw "Patch not found: $patch" }
    if (-not (Test-Path $marker)) { throw "Target file not found: $marker" }

    if (Select-String -Path $marker -Pattern $p.Marker.Pattern -Quiet) {
        Write-Host '    already applied.' -ForegroundColor DarkGray
        continue
    }

    $check = Invoke-Native -FilePath 'git' -ArgumentList @('-C', $repo, 'apply', '--check', $patch) -Quiet
    if (-not $check.Success) { throw "Patch does not apply cleanly:`n$($check.Text)" }
    Invoke-NativeChecked -FilePath 'git' -ArgumentList @('-C', $repo, 'apply', $patch) -What ("git apply " + $p.Name) | Out-Null

    # Verify the result rather than trusting the exit code.
    if (-not (Select-String -Path $marker -Pattern $p.Marker.Pattern -Quiet)) {
        throw "$($p.Name): applied without error but the expected change is not present."
    }
    Write-Host '    applied and verified.' -ForegroundColor Green
    if ($p.ClearsModuleCache) { $needsCacheClear = $true }
}

Write-Host ''
if ($needsCacheClear -and -not $KeepModuleCache) {
    if (Test-Path $ModulesDir) {
        $mods = @(Get-ChildItem -Path $ModulesDir -Recurse -Filter '*.dll' -ErrorAction SilentlyContinue)
        Write-Host ("Removing {0} cached module(s): a patch changed the module ABI." -f $mods.Count) -ForegroundColor Yellow
        Remove-Item -LiteralPath $ModulesDir -Recurse -Force
    } else {
        Write-Host 'No module cache to clear.' -ForegroundColor DarkGray
    }
} elseif ($needsCacheClear) {
    Write-Host 'Module cache kept at your request -- expect "CPU ABI mismatch" until it is cleared.' -ForegroundColor Yellow
} else {
    Write-Host 'No patch affected the module ABI; cached modules remain valid.' -ForegroundColor DarkGray
}

Write-Host ''
Write-Host 'Rebuild next: Build-Tools.ps1 (runtime changes need a relink).' -ForegroundColor Green
