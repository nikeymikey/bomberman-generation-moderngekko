<#
.SYNOPSIS
    Have Windows write a crash dump for moderngekko-run.exe into the project.
.DESCRIPTION
    Configures Windows Error Reporting LocalDumps for one executable only.
    DumpType 1 (mini) is deliberate: it is small (a few hundred KB) but still
    carries the module list and the exception record, which is all that is
    needed to identify the faulting module and address.

    Requires an ELEVATED PowerShell -- the LocalDumps key lives under HKLM.
    Use -Disable to remove the setting again.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = 'Where dumps should be written. No default.')]
    [string] $DumpFolder,

    [Parameter(HelpMessage = 'Executable to capture. Defaults to the runner.')]
    [string] $ExeName = 'moderngekko-run.exe',

    [Parameter(HelpMessage = 'Remove the setting instead of adding it.')]
    [switch] $Disable
)

$ErrorActionPreference = 'Stop'

$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'This needs an elevated PowerShell (the LocalDumps key is under HKLM). Right-click PowerShell -> Run as administrator.'
}

$root = 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps'
$key  = Join-Path $root $ExeName

if ($Disable) {
    if (Test-Path $key) { Remove-Item -LiteralPath $key -Recurse -Force; Write-Host "Removed $key" -ForegroundColor Green }
    else { Write-Host 'Nothing to remove.' -ForegroundColor DarkGray }
    exit 0
}

New-Item -ItemType Directory -Force -Path $DumpFolder | Out-Null
if (-not (Test-Path $root)) { New-Item -Path $root -Force | Out-Null }
if (-not (Test-Path $key))  { New-Item -Path $key  -Force | Out-Null }

New-ItemProperty -Path $key -Name 'DumpFolder' -Value $DumpFolder -PropertyType ExpandString -Force | Out-Null
New-ItemProperty -Path $key -Name 'DumpType'   -Value 1           -PropertyType DWord        -Force | Out-Null
New-ItemProperty -Path $key -Name 'DumpCount'  -Value 5           -PropertyType DWord        -Force | Out-Null

Write-Host ''
Write-Host ("Crash dumps enabled for {0}" -f $ExeName) -ForegroundColor Green
Write-Host ("  folder : {0}" -f $DumpFolder)
Write-Host  '  type   : 1 (mini - small, but carries the module list and exception record)'
Write-Host ''
Write-Host 'Reproduce the crash, then a .dmp will appear in that folder.' -ForegroundColor Cyan
Write-Host 'Undo later with:  -Disable' -ForegroundColor DarkGray
