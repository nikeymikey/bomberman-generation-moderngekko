<#
.SYNOPSIS
    Test whether raising _WIN32_WINNT fixes the Dolphin/MinGW build failures,
    WITHOUT committing to a full rebuild.
.DESCRIPTION
    Recompiles one known-failing translation unit twice: exactly as the build
    does it, then again with the Windows API level raised.

    The command comes from ninja itself (`ninja -t commands`), so it is what the
    build really runs. Three adjustments, each for a reason:
      * -o and -MF are redirected to a scratch directory, so the real build tree
        is not touched. The dependency flags are LEFT IN PLACE -- an earlier
        version stripped -MD but left -MT, and GCC rejects -MT without -M/-MD,
        so both probes died before the compiler read the source and the verdict
        was meaningless.
      * ccache is dropped from the front of the command, so a cached result
        cannot masquerade as a real compile.
      * The command is written to a .bat and run from there, because it contains
        nested quotes (-DDATA_DIR="\"C:/Program Files (x86)/...\"") that do not
        survive being passed through cmd /c inline.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = 'Repository root. No default.')]
    [string] $RepoRoot,

    [Parameter(HelpMessage = 'Object file to rebuild as the probe.')]
    [string] $Target = 'vendor/dolphin/Source/Core/Common/CMakeFiles/common.dir/Timer.cpp.obj',

    [string] $WindowsTargetVersion = '0x0A00',
    [string] $NtddiVersion         = '0x0A000004'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')

$buildDir = Join-Path $RepoRoot 'lib\ModernGekko\build'
$cache    = Join-Path $buildDir 'CMakeCache.txt'
if (-not (Test-Path $cache)) { throw "No CMakeCache.txt in $buildDir -- configure first." }

$ninja = $null
foreach ($line in (Get-Content -LiteralPath $cache)) {
    if ($line -match '^CMAKE_MAKE_PROGRAM:[^=]*=(.*)$') { $ninja = $Matches[1].Trim(); break }
}
if (-not $ninja -or -not (Test-Path $ninja)) { throw "Could not locate ninja via CMAKE_MAKE_PROGRAM (got '$ninja')." }
Write-Host ("ninja : {0}" -f $ninja) -ForegroundColor DarkGray
Write-Host ("target: {0}" -f $Target) -ForegroundColor DarkGray

$scratch = Join-Path $env:TEMP 'winapi-probe'
New-Item -ItemType Directory -Force -Path $scratch | Out-Null
$probeObj = Join-Path $scratch 'probe.obj'
$probeDep = Join-Path $scratch 'probe.d'

Push-Location $buildDir
try {
    $cmdResult = Invoke-Native -FilePath $ninja -ArgumentList @('-t', 'commands', $Target) -Quiet
    if (-not $cmdResult.Success) { throw "ninja -t commands failed for $Target`n$($cmdResult.Text)" }
    $compileCmd = @($cmdResult.Output | Where-Object { $_ -match '\s-c\s' } | Select-Object -Last 1)[0]
    if ([string]::IsNullOrWhiteSpace($compileCmd)) { throw "No compile command found for $Target." }

    # Drop ccache so nothing can be served from cache.
    $baseCmd = $compileCmd -replace '^\s*\S*ccache\.exe\s+', ''
    # Redirect outputs to scratch; keep -MD/-MT intact.
    $baseCmd = $baseCmd -replace '-o\s+\S+\.obj', ('-o "' + $probeObj + '"')
    $baseCmd = $baseCmd -replace '-MF\s+\S+',     ('-MF "' + $probeDep + '"')

    $defs = "-D_WIN32_WINNT=$WindowsTargetVersion -DWINVER=$WindowsTargetVersion -DNTDDI_VERSION=$NtddiVersion"
    $fixedCmd = $baseCmd -replace '(\s-c\s)', " $defs`$1"

    if ($fixedCmd -eq $baseCmd) { throw 'Failed to insert the defines into the command.' }

    function Invoke-Probe([string] $Label, [string] $Cmd, [string] $BatName) {
        Write-Host ''
        Write-Host ("--- {0} ---" -f $Label) -ForegroundColor Cyan
        Remove-Item $probeObj -ErrorAction SilentlyContinue
        $bat = Join-Path $scratch $BatName
        Set-Content -LiteralPath $bat -Value @('@echo off', $Cmd) -Encoding ASCII
        $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        $out = & cmd /c $bat 2>&1
        $code = $LASTEXITCODE
        $ErrorActionPreference = $prev
        $errs = @($out | Where-Object { "$_" -match 'error:' })
        if ($code -eq 0 -and (Test-Path $probeObj)) {
            Write-Host '  RESULT: COMPILED OK' -ForegroundColor Green
            return $true
        }
        Write-Host ("  RESULT: FAILED (exit {0})" -f $code) -ForegroundColor Red
        if ($errs.Count -gt 0) { $errs | Select-Object -First 5 | ForEach-Object { Write-Host ("    {0}" -f $_) } }
        else { $out | Select-Object -Last 5 | ForEach-Object { Write-Host ("    {0}" -f $_) } }
        return $false
    }

    $before = Invoke-Probe 'AS THE BUILD RUNS IT (expected to FAIL)'          $baseCmd  'probe_base.bat'
    $after  = Invoke-Probe 'WITH RAISED WINDOWS API LEVEL (expected to PASS)' $fixedCmd 'probe_fixed.bat'

    Write-Host ''
    Write-Host '================ VERDICT ================' -ForegroundColor Cyan
    if ((-not $before) -and $after) {
        Write-Host 'CONFIRMED: the failure is the Windows API level, and raising it fixes it.' -ForegroundColor Green
        exit 0
    } elseif ($before -and $after) {
        Write-Host 'INCONCLUSIVE: this file compiles either way now.' -ForegroundColor Yellow
        exit 2
    } elseif ($before -and -not $after) {
        Write-Host 'ODD: it compiled WITHOUT the fix and failed WITH it. Send the errors.' -ForegroundColor Red
        exit 3
    } else {
        Write-Host 'NOT CONFIRMED: it fails both ways.' -ForegroundColor Red
        Write-Host 'Check the errors above are real compiler diagnostics about the SOURCE.' -ForegroundColor Yellow
        Write-Host 'If they are about command-line flags, this probe is still wrong -- send them.' -ForegroundColor Yellow
        exit 1
    }
}
finally { Pop-Location }
