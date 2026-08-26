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
