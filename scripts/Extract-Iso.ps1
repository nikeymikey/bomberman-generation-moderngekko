<#
.SYNOPSIS
    Extract a GameCube ISO into extracted/<slug>/ using DolRecomp's extractor.
.DESCRIPTION
    GameCube discs do NOT need Wiimms ISO Tools -- the upstream Makefile runs
    `dolrecomp --setup` unconditionally only to keep its pipeline uniform for Wii.
    This skips that download entirely.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = 'Repository root. No default.')]
    [string] $RepoRoot,

    [Parameter(Mandatory = $true, HelpMessage = 'Path to the disc image.')]
    [string] $IsoPath,

    [Parameter(HelpMessage = 'Slug for extracted/<slug>. Derived from the ISO filename if omitted.')]
    [string] $Slug = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')

if (-not (Test-Path $IsoPath)) { throw "Disc image not found: $IsoPath" }

$dolExe = Get-ChildItem -Path (Join-Path $RepoRoot 'lib\DolRecomp\build') -Recurse -Filter 'dolrecomp.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $dolExe) { throw "dolrecomp.exe not found -- run Build-Tools.ps1 first." }

if ([string]::IsNullOrWhiteSpace($Slug)) {
    $base = [System.IO.Path]::GetFileNameWithoutExtension($IsoPath)
    $Slug = ($base -replace '[^A-Za-z0-9]+', '-').Trim('-')
}
if ([string]::IsNullOrWhiteSpace($Slug)) { throw 'Could not derive a slug; pass -Slug explicitly.' }

$outDir = Join-Path $RepoRoot ("extracted\" + $Slug)
Write-Host ("Extracting to: {0}" -f $outDir) -ForegroundColor Cyan
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $outDir) | Out-Null

Invoke-NativeChecked -FilePath $dolExe.FullName `
    -ArgumentList @('extract', $IsoPath, $outDir) -What 'dolrecomp extract' | Out-Null

$mainDol = Join-Path $outDir 'sys\main.dol'
if (-not (Test-Path $mainDol)) {
    throw "Extraction finished but $mainDol is missing. Do not proceed -- the layout is not what the pipeline expects."
}
$size = (Get-Item $mainDol).Length
Write-Host ''
Write-Host ("main.dol : {0} ({1:N0} bytes)" -f $mainDol, $size) -ForegroundColor Green
if ($size -ne 2195744) {
    Write-Host ("NOTE: expected 2,195,744 bytes for Bomberman Generation (NTSC-U). Got {0:N0}." -f $size) -ForegroundColor Yellow
    Write-Host '      Different region or revision -- addresses in the notes may not apply.' -ForegroundColor Yellow
}
Write-Host ("Slug     : {0}" -f $Slug) -ForegroundColor Green
Write-Host 'Pass this slug to Build-Module.ps1 / Run-Game.ps1 with -Slug.'
