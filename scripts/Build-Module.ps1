<#
.SYNOPSIS
    Recompile the extracted game and compile it into a native module.
.DESCRIPTION
    Drives `moderngekko-port build`, which invokes DolRecomp and then compiles
    the generated C. Modules are cached by DOL hash + toolchain, so repeat runs
    are cheap.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = 'Repository root. No default.')]
    [string] $RepoRoot,

    [Parameter(Mandatory = $true, HelpMessage = 'Slug under extracted/. No default.')]
    [string] $Slug,

    [ValidateSet('c', 'llvm')]
    [string] $Backend = 'c',

    [ValidateSet('auto', 'clang', 'gcc', 'msvc')]
    [string] $Toolchain = 'auto',

    [ValidateRange(0, 3)]
    [int] $OptLevel = 2,

    [Parameter(HelpMessage = 'Directory for compiled modules. No default.')]
    [string] $OutputDir,

    [Parameter(HelpMessage = 'Linker MAP of function names. Without it DolRecomp emits no <stem>_symbols.h, so mods can only use raw addresses. Requires the moderngekko-symbol-map patch.')]
    [string] $MapPath = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    throw 'OutputDir is required -- pass it explicitly rather than relying on a default.'
}

$portExe = Get-ChildItem -Path (Join-Path $RepoRoot 'lib\ModernGekko\build') -Recurse -Filter 'moderngekko-port.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $portExe) { throw "moderngekko-port.exe not found -- run Build-Tools.ps1 first." }

$gameRoot = Join-Path $RepoRoot ("extracted\" + $Slug)
if (-not (Test-Path (Join-Path $gameRoot 'sys\main.dol'))) {
    throw "No extracted game at $gameRoot (expected sys\main.dol). Run Extract-Iso.ps1 first."
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

Write-Host ("Inspecting {0}" -f $gameRoot) -ForegroundColor Cyan
Invoke-Native -FilePath $portExe.FullName -ArgumentList @('inspect', $gameRoot) | Out-Null

Write-Host ("Building module (backend={0} toolchain={1} opt={2})" -f $Backend, $Toolchain, $OptLevel) -ForegroundColor Cyan
$portArgs = @('build', $gameRoot,
              '--backend',   $Backend,
              '--toolchain', $Toolchain,
              '--opt-level', "$OptLevel",
              '--output',    $OutputDir)
if (-not [string]::IsNullOrWhiteSpace($MapPath)) {
    if (-not (Test-Path $MapPath)) { throw "Symbol map not found: $MapPath" }
    # Resolved to a full path: moderngekko-port passes this straight to
    # DolRecomp, which runs with its own working directory.
    $portArgs += @('--map', (Resolve-Path -LiteralPath $MapPath).Path)
    Write-Host ("Symbol map: {0}" -f $MapPath) -ForegroundColor Cyan
}

Invoke-NativeChecked -FilePath $portExe.FullName `
    -ArgumentList $portArgs `
    -What 'moderngekko-port build' | Out-Null

$modules = @(Get-ChildItem -Path $OutputDir -Recurse -Include '*.dll', '*.mgm' -ErrorAction SilentlyContinue)
Write-Host ''
if ($modules.Count -eq 0) {
    throw "moderngekko-port reported success but no module was produced under $OutputDir."
}
foreach ($m in $modules) { Write-Host ("Module: {0} ({1:N0} bytes)" -f $m.FullName, $m.Length) -ForegroundColor Green }
