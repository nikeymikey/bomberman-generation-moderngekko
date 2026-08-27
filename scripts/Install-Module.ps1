<#
.SYNOPSIS
    Install the compiled game module where the runner will find it on its own.
.DESCRIPTION
    moderngekko-port passes --module explicitly, so running through the scripts
    works. The LAUNCHER does not: it starts moderngekko-run without --module,
    and the runner then searches, in order:

      1. --module <path>                                  (port only)
      2. $env:STATICRECOMP_MODULE
      3. <executable directory>\g<DISCID>_recomp.dll      <-- shipping layout
      4. <user directory>\StaticRecompModules\g<DISCID>_recomp.dll

    Without one of those the launcher fails with:
      "initialization failed: no native module was supplied; use allow_interpreter explicitly"

    This copies the built module to a destination of your choice. Put it beside
    the executables for a distributable folder, or in the portable user
    directory to keep build output separate.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = 'Directory holding built modules (moderngekko-port --output). No default.')]
    [string] $ModulesDir,

    [Parameter(Mandatory = $true, HelpMessage = 'Where to install it. No default: pass the executable directory, or <user dir>\StaticRecompModules.')]
    [string] $Destination,

    [Parameter(HelpMessage = 'Disc ID, used to locate the module and to name it.')]
    [string] $DiscId = 'GBGE5G'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')

$discDir = Join-Path $ModulesDir $DiscId
if (-not (Test-Path $discDir)) {
    throw "No modules for $DiscId under $ModulesDir. Run Build-Module.ps1 first."
}

# active-module.txt names the module moderngekko-port last published.
$source = $null
$activeFile = Join-Path $discDir 'active-module.txt'
if (Test-Path $activeFile) {
    $candidate = (Get-Content -LiteralPath $activeFile -Raw).Trim()
    if ($candidate -and (Test-Path $candidate)) {
        $source = $candidate
        Write-Host "Using active module recorded by moderngekko-port." -ForegroundColor DarkGray
    } else {
        Write-Host "active-module.txt points at a missing file; falling back to newest build." -ForegroundColor Yellow
    }
}
if (-not $source) {
    # Ignore module-build\ -- that is the intermediate copy, not the published one.
    $newest = Get-ChildItem -Path $discDir -Recurse -Filter "g${DiscId}_recomp.dll" -ErrorAction SilentlyContinue |
              Where-Object { $_.DirectoryName -notmatch 'module-build$' } |
              Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $newest) { throw "No g${DiscId}_recomp.dll found under $discDir." }
    $source = $newest.FullName
}

$sourceInfo = Get-Item -LiteralPath $source
Write-Host ("Source     : {0}" -f $sourceInfo.FullName)
Write-Host ("Size       : {0:N0} bytes" -f $sourceInfo.Length)
Write-Host ("Built      : {0}" -f $sourceInfo.LastWriteTime)

New-Item -ItemType Directory -Force -Path $Destination | Out-Null
$target = Join-Path $Destination ("g{0}_recomp.dll" -f $DiscId)

if (Test-Path $target) {
    $existing = Get-Item -LiteralPath $target
    if ($existing.Length -eq $sourceInfo.Length -and $existing.LastWriteTime -ge $sourceInfo.LastWriteTime) {
        Write-Host ''
        Write-Host ("Already installed and current: {0}" -f $target) -ForegroundColor Green
        exit 0
    }
    Write-Host ("Replacing older copy at {0}" -f $target) -ForegroundColor Yellow
}

Copy-Item -LiteralPath $source -Destination $target -Force

# Verify rather than trust the copy.
$installed = Get-Item -LiteralPath $target -ErrorAction SilentlyContinue
if (-not $installed) { throw "Copy reported success but $target does not exist." }
if ($installed.Length -ne $sourceInfo.Length) {
    throw ("Copied file is {0:N0} bytes but the source is {1:N0}. Do not run it." -f $installed.Length, $sourceInfo.Length)
}

Write-Host ''
Write-Host ("Installed  : {0}" -f $target) -ForegroundColor Green
Write-Host ("Verified   : {0:N0} bytes, matches source" -f $installed.Length) -ForegroundColor Green
Write-Host ''
Write-Host 'The launcher can now start the game without --module.' -ForegroundColor Green
