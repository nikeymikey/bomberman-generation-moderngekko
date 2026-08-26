<#
.SYNOPSIS
    Apply local patches to the vendored submodules, and invalidate anything
    those patches make stale.
.DESCRIPTION
    patches/gxruntime-cpu-abi4.patch
      ModernGekko's moderngekko/cpu_state.h is at CPU ABI 4 and sizeof(CPUState)
      is 3536. The vendored GXRuntime copy (core/cpu.h) is still at ABI 3 and
      3528 -- it never got the `cycle_budget` field. Generated modules include
      cpu/cpu.h -> core/cpu.h, so every module reports cpu_state_size=3528 while
      the runtime expects 3536, and the loader rejects it:

          initialization failed: native module was rejected: CPU ABI mismatch

      Both repos are at their remote tips, so there is no upstream fix to pull.
      This adds the missing field and bumps the constant to 4u.

    IMPORTANT: moderngekko-port's module cache key does NOT include the content
    of this header, so a patched header alone will NOT invalidate an already
    built module -- it would be served from cache and rejected again. This
    script therefore removes the cached modules as well.

    Safe to re-run: an already-applied patch is detected and skipped.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = 'Repository root. No default.')]
    [string] $RepoRoot,

    [Parameter(Mandatory = $true, HelpMessage = 'Module output directory to invalidate. No default.')]
    [string] $ModulesDir,

    [Parameter(HelpMessage = 'Do not remove cached modules (they will then be reused and rejected).')]
    [switch] $KeepModuleCache
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')

$vendor = Join-Path $RepoRoot 'lib\ModernGekko\vendor\dolphin'
$header = Join-Path $vendor 'GXRuntime\include\core\cpu.h'
$patch  = Join-Path (Split-Path -Parent $PSScriptRoot) 'patches\gxruntime-cpu-abi4.patch'

if (-not (Test-Path $header)) { throw "Vendored header not found: $header" }
if (-not (Test-Path $patch))  { throw "Patch not found: $patch" }

if (Select-String -Path $header -Pattern 'cycle_budget' -Quiet) {
    Write-Host 'gxruntime-cpu-abi4: already applied.' -ForegroundColor DarkGray
} else {
    Write-Host 'Applying gxruntime-cpu-abi4.patch ...' -ForegroundColor Cyan
    $check = Invoke-Native -FilePath 'git' -ArgumentList @('-C', $vendor, 'apply', '--check', $patch) -Quiet
    if (-not $check.Success) { throw "Patch does not apply cleanly:`n$($check.Text)" }
    Invoke-NativeChecked -FilePath 'git' -ArgumentList @('-C', $vendor, 'apply', $patch) -What 'git apply' | Out-Null
    Write-Host '  applied.' -ForegroundColor Green
}

# Verify the result rather than trusting the exit code.
$abi = Select-String -Path $header -Pattern '#define\s+GXRUNTIME_CPU_ABI_VERSION\s+(\S+)' |
       Select-Object -First 1
$abiVal = if ($abi) { $abi.Matches[0].Groups[1].Value } else { '<not found>' }
$hasField = Select-String -Path $header -Pattern '^\s*s64\s+cycle_budget;' -Quiet

Write-Host ''
Write-Host ("GXRUNTIME_CPU_ABI_VERSION : {0}  (must be 4u)" -f $abiVal)
Write-Host ("cycle_budget field        : {0}" -f $(if ($hasField) { 'present' } else { 'MISSING' }))
if ($abiVal -ne '4u' -or -not $hasField) { throw 'Patch verification failed -- do not rebuild.' }

if (-not $KeepModuleCache) {
    if (Test-Path $ModulesDir) {
        $mods = @(Get-ChildItem -Path $ModulesDir -Recurse -Filter '*.dll' -ErrorAction SilentlyContinue)
        Write-Host ''
        Write-Host ("Removing {0} cached module(s) from {1}" -f $mods.Count, $ModulesDir) -ForegroundColor Yellow
        Write-Host '  (the cache key ignores this header, so a stale module would be reused)' -ForegroundColor DarkGray
        Remove-Item -LiteralPath $ModulesDir -Recurse -Force
    } else {
        Write-Host ''
        Write-Host 'No module cache to clear.' -ForegroundColor DarkGray
    }
}

Write-Host ''
Write-Host 'Done. Rebuild the module next (Build-Module.ps1), then run.' -ForegroundColor Green
