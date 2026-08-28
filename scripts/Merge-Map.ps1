<#
.SYNOPSIS
    Merge real function names from another symbol map into the generated one.
.DESCRIPTION
    The generated map (tools/find_functions.py) has complete address coverage
    with fn_* placeholders. Dolphin's Save Symbol Map, or a Ghidra export, has
    real names for some addresses. This keeps the union, preferring real names
    and never overwriting one you wrote by hand.

    Placeholder names are recognised whoever invented them -- fn_ (ours),
    zz_800xxxxx_ (Dolphin's PPCAnalyst, applied before the signature database
    renames what it can match) and FUN_ (Ghidra) -- so a merge cannot quietly
    swap one meaningless name for another and report progress.

    -DolphinMap is discovered rather than assumed when not given, because the
    location differs between a standard install and a portable one.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = 'Repository root. No default.')]
    [string] $RepoRoot,

    [Parameter(Mandatory = $true, HelpMessage = 'Generated map with full address coverage. No default.')]
    [string] $BaseMap,

    [Parameter(Mandatory = $true, HelpMessage = 'Where to write the merged map. No default.')]
    [string] $OutputMap,

    [Parameter(HelpMessage = 'Maps carrying real names. If omitted, Dolphin''s exported map is searched for.')]
    [string[]] $OverlayMap = @(),

    [Parameter(HelpMessage = 'Disc ID used to find Dolphin''s exported map.')]
    [string] $DiscId = 'GBGE5G',

    [Parameter(HelpMessage = 'Also keep overlay addresses that are not in the base map.')]
    [switch] $KeepUnknown
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')

if (-not (Test-Path $BaseMap)) { throw "Base map not found: $BaseMap" }
$tool = Join-Path $RepoRoot 'tools\merge_map.py'
if (-not (Test-Path $tool))    { throw "merge_map.py not found: $tool" }

if ($OverlayMap.Count -eq 0) {
    Write-Host "No -OverlayMap given; looking for Dolphin's exported $DiscId.map" -ForegroundColor Cyan
    $roots = @(
        (Join-Path $env:USERPROFILE 'Documents\Dolphin Emulator\Maps'),
        (Join-Path $env:APPDATA     'Dolphin Emulator\Maps'),
        (Join-Path $env:USERPROFILE 'OneDrive\Documents\Dolphin Emulator\Maps')
    ) | Where-Object { Test-Path $_ }

    $found = @()
    foreach ($root in $roots) {
        $found += @(Get-ChildItem -Path $root -Filter "$DiscId.map" -ErrorAction SilentlyContinue)
    }
    if ($found.Count -eq 0) {
        Write-Host ''
        Write-Host "Not in any standard location. Searched:" -ForegroundColor Yellow
        foreach ($root in $roots) { Write-Host "  $root" }
        if ($roots.Count -eq 0) { Write-Host '  (none of the standard Dolphin user directories exist)' }
        Write-Host ''
        throw ("Could not find $DiscId.map. If Dolphin is a portable install its user folder sits beside Dolphin.exe -- " +
               "pass that path with -OverlayMap. Note the map is only written after Symbols -> Save Symbol Map, " +
               "which needs the game running and the debugging UI enabled.")
    }
    $OverlayMap = @($found | Select-Object -ExpandProperty FullName)
    foreach ($m in $OverlayMap) { Write-Host ("  found: {0}" -f $m) -ForegroundColor Green }
}

foreach ($m in $OverlayMap) {
    if (-not (Test-Path $m)) { throw "Overlay map not found: $m" }
}

# Not $args: that is a PowerShell automatic variable holding the script's own
# unbound arguments, and assigning to it works until it silently does not.
$pyArgs = @($tool, $BaseMap) + $OverlayMap + @('-o', $OutputMap)
if ($KeepUnknown) { $pyArgs += '--keep-unknown' }

Write-Host ''
Invoke-NativeChecked -FilePath 'python' -ArgumentList $pyArgs -What 'merge_map.py' | Out-Null

if (-not (Test-Path $OutputMap)) { throw "merge_map.py reported success but $OutputMap was not written." }
Write-Host ''
Write-Host ("Merged map: {0}" -f $OutputMap) -ForegroundColor Green
