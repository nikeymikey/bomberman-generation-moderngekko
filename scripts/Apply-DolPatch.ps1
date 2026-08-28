<#
.SYNOPSIS
    Apply a DOL patch manifest to the extracted main.dol, before the module is built.
.DESCRIPTION
    Some changes cannot be made by a mod. A mod hook cannot alter registers --
    ModManager::Dispatch restores the CPUState -- so a hardcoded immediate like
    `li r7, 1` is out of reach. Editing the instruction is the only way, and
    that means patching the DOL and recompiling.

    Applied here rather than by the runner's built-in startup applier because
    the recompiled module is cached against the DOL's SHA-256: patching at
    launch would leave the runner executing a module built from the unpatched
    DOL. Patch, then rebuild the module.

    The manifest format is ModernGekko's own, so the same file can later be
    shipped to end users via MODERNGEKKO_DOL_PATCH_MANIFEST.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = 'Repository root. No default.')]
    [string] $RepoRoot,

    [Parameter(Mandatory = $true, HelpMessage = 'Slug under extracted/. No default.')]
    [string] $Slug,

    [Parameter(Mandatory = $true, HelpMessage = 'Manifest CSV to apply. No default.')]
    [string] $ManifestPath,

    [Parameter(HelpMessage = 'Report what would change without writing.')]
    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')

$dol = Join-Path $RepoRoot ("extracted\" + $Slug + "\sys\main.dol")
if (-not (Test-Path $dol))          { throw "No extracted game at $dol. Run Extract-Iso.ps1 first." }
if (-not (Test-Path $ManifestPath)) { throw "Manifest not found: $ManifestPath" }
$tool = Join-Path $RepoRoot 'tools\apply_dol_patch.py'
if (-not (Test-Path $tool))         { throw "apply_dol_patch.py not found: $tool" }

$pyArgs = @($tool, $dol, $ManifestPath)
if ($DryRun) { $pyArgs += '--dry-run' }

Write-Host ''
Invoke-NativeChecked -FilePath 'python' -ArgumentList $pyArgs -What 'apply_dol_patch.py' | Out-Null

if (-not $DryRun) {
    Write-Host ''
    Write-Host 'Rebuild the module next -- the old one was compiled from the unpatched DOL:' -ForegroundColor Yellow
    Write-Host ("  .\scripts\Build-Module.ps1 -RepoRoot {0} -Slug {1} -OutputDir {0}\build\modules" -f $RepoRoot, $Slug) -ForegroundColor DarkGray
    Write-Host ("  .\scripts\Install-Module.ps1 -RepoRoot {0} ..." -f $RepoRoot) -ForegroundColor DarkGray
}
