<#
.SYNOPSIS
    Generate DolRecomp's <stem>_symbols.h from a symbol map, without rebuilding
    the game module.
.DESCRIPTION
    On the C backend a symbol map does NOT change generated code. Tracing
    DolRecomp's pipeline: the map reaches codegen only through
    collect_llvm_entry_points(), which is the LLVM backend's entry-point seed.
    The C path (pipeline.c) uses it for exactly one thing -- emitting
    <stem>_symbols.h -- and partitions on the fixed c_chunk_instructions()
    regardless.

    So building the module with --map would recompile everything to produce a
    header while emitting byte-identical code. This runs DolRecomp's codegen
    step alone into a scratch directory and keeps only the header.

    DolRecomp writes it rather than this script, so the identifier sanitising,
    collision suffixes and size derivation are upstream's, not a reimplementation
    that could drift.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = 'Repository root. No default.')]
    [string] $RepoRoot,

    [Parameter(Mandatory = $true, HelpMessage = 'Slug under extracted/. No default.')]
    [string] $Slug,

    [Parameter(Mandatory = $true, HelpMessage = 'Symbol map to read. No default.')]
    [string] $MapPath,

    [Parameter(Mandatory = $true, HelpMessage = 'Where to write the generated header. No default.')]
    [string] $OutputHeader,

    [Parameter(Mandatory = $true, HelpMessage = 'Scratch directory for DolRecomp output. No default.')]
    [string] $WorkDir,

    [Parameter(HelpMessage = 'Keep the scratch directory for inspection.')]
    [switch] $KeepWork
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')

$dolrecomp = Get-ChildItem -Path (Join-Path $RepoRoot 'lib\ModernGekko\build') -Recurse -Filter 'dolrecomp.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $dolrecomp) { throw 'dolrecomp.exe not found -- run Build-Tools.ps1 first.' }

$dol = Join-Path $RepoRoot ("extracted\" + $Slug + "\sys\main.dol")
if (-not (Test-Path $dol))     { throw "No extracted game at $dol. Run Extract-Iso.ps1 first." }
if (-not (Test-Path $MapPath)) { throw "Symbol map not found: $MapPath" }

if (Test-Path $WorkDir) { Remove-Item -LiteralPath $WorkDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null

$mapFull = (Resolve-Path -LiteralPath $MapPath).Path
$dolFull = (Resolve-Path -LiteralPath $dol).Path

Write-Host ''
Write-Host ("Running DolRecomp codegen with {0}" -f $MapPath) -ForegroundColor Cyan
Invoke-NativeChecked -FilePath $dolrecomp.FullName `
    -ArgumentList @('--cpu', 'gekko', '--gamecube', '--map', $mapFull, $dolFull, $WorkDir) `
    -What 'dolrecomp --map' | Out-Null

# Verify rather than trust: DolRecomp deletes the header when a map produces no
# symbols inside executable sections, and still exits 0.
$produced = @(Get-ChildItem -Path $WorkDir -Recurse -Filter '*_symbols.h' -ErrorAction SilentlyContinue)
if ($produced.Count -eq 0) {
    throw "DolRecomp produced no *_symbols.h under $WorkDir. The map may have no addresses inside executable sections."
}
if ($produced.Count -gt 1) {
    throw ("Expected one symbol header, found {0}: {1}" -f $produced.Count, ($produced.FullName -join ', '))
}

$defines = @(Select-String -Path $produced[0].FullName -Pattern '^#define DOLRECOMP_SYMBOL_[A-Za-z_]' -AllMatches)
if ($defines.Count -eq 0) {
    throw "$($produced[0].Name) contains no DOLRECOMP_SYMBOL_ defines."
}

$headerDir = Split-Path -Parent $OutputHeader
if ($headerDir -and -not (Test-Path $headerDir)) { New-Item -ItemType Directory -Force -Path $headerDir | Out-Null }
Copy-Item -LiteralPath $produced[0].FullName -Destination $OutputHeader -Force

Write-Host ''
Write-Host ("Wrote {0}" -f $OutputHeader) -ForegroundColor Green
Write-Host ("  {0} symbol defines" -f $defines.Count)

if ($KeepWork) {
    Write-Host ("  scratch kept at {0}" -f $WorkDir) -ForegroundColor DarkGray
} else {
    Remove-Item -LiteralPath $WorkDir -Recurse -Force
}
