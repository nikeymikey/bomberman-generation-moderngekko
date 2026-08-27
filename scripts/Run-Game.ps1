<#
.SYNOPSIS
    Launch the recompiled game through the ModernGekko runtime.
.DESCRIPTION
    Drives `moderngekko-port run`, which rebuilds the module if needed and then
    starts the runner. Runner arguments after -- are forwarded (e.g. --headless,
    --graphics Vulkan).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = 'Repository root. No default.')]
    [string] $RepoRoot,

    [Parameter(Mandatory = $true, HelpMessage = 'Slug under extracted/. No default.')]
    [string] $Slug,

    # Not Mandatory: -Direct never uses it, and a mandatory parameter would make
    # PowerShell prompt for a value that is then discarded. The non-Direct branch
    # below still refuses to run without it -- there is no default.
    [Parameter(HelpMessage = 'Directory holding compiled modules. Required unless -Direct. No default.')]
    [string] $OutputDir,

    [Parameter(Mandatory = $true, HelpMessage = 'Where to write the captured log.')]
    [string] $LogPath,

    [ValidateSet('c', 'llvm')]
    [string] $Backend = 'c',

    [ValidateSet('auto', 'clang', 'gcc', 'msvc')]
    [string] $Toolchain = 'auto',

    [Parameter(HelpMessage = 'Extra runner arguments passed after --, e.g. @("--headless")')]
    [string[]] $RunnerArgs = @(),

    [Parameter(HelpMessage = 'Seconds before the process is killed. 0 = wait forever.')]
    [int] $TimeoutSeconds = 120,

    [Parameter(HelpMessage = 'Force 16:9 output with the projection hack. Requires the moderngekko-widescreen patch and a rebuilt runtime.')]
    [switch] $Widescreen,

    [Parameter(HelpMessage = 'Run moderngekko-run.exe directly instead of via moderngekko-port. Reports the RUNNER''s own exit code, which port would otherwise flatten to 1.')]
    [switch] $Direct
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')

$portExe = Get-ChildItem -Path (Join-Path $RepoRoot 'lib\ModernGekko\build') -Recurse -Filter 'moderngekko-port.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $portExe) { throw "moderngekko-port.exe not found -- run Build-Tools.ps1 first." }

$gameRoot = Join-Path $RepoRoot ("extracted\" + $Slug)
if (-not (Test-Path (Join-Path $gameRoot 'sys\main.dol'))) {
    throw "No extracted game at $gameRoot. Run Extract-Iso.ps1 first."
}

$logDir = Split-Path -Parent $LogPath
if ($logDir -and -not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
$outFile = "$LogPath.out"
$errFile = "$LogPath.err"

if ($Direct) {
    # moderngekko-port wraps the runner and returns its own status, so an
    # abnormal child exit arrives as a bare 1 and the real code is lost. Going
    # straight to the runner preserves it -- which is what a crash diagnosis
    # needs. Requires the module to be installed beside the runner
    # (Install-Module.ps1) so it can find it without --module.
    $runExe = Get-ChildItem -Path (Join-Path $RepoRoot 'lib\ModernGekko\build') -Recurse -Filter 'moderngekko-run.exe' -ErrorAction SilentlyContinue |
              Select-Object -First 1
    if (-not $runExe) { throw 'moderngekko-run.exe not found -- run Build-Tools.ps1 first.' }
    $expectedModule = Join-Path $runExe.DirectoryName 'gGBGE5G_recomp.dll'
    if (-not (Test-Path $expectedModule)) {
        throw "Direct mode needs the module beside the runner. Expected: $expectedModule`nRun Install-Module.ps1 first."
    }
    $portExe = $runExe
    $argList = @('--game', $gameRoot)
    if ($RunnerArgs.Count -gt 0) { $argList += $RunnerArgs }
    Write-Host 'Direct mode: bypassing moderngekko-port to capture the runner exit code.' -ForegroundColor Cyan
} else {
    if (-not $OutputDir) { throw 'OutputDir is required unless -Direct is used. Pass -OutputDir explicitly; there is deliberately no default.' }
    $argList = @('run', $gameRoot, '--backend', $Backend, '--toolchain', $Toolchain, '--output', $OutputDir)
    if ($RunnerArgs.Count -gt 0) { $argList += '--'; $argList += $RunnerArgs }
}

# Quote every argument: paths here contain spaces, and Start-Process joins
# -ArgumentList without quoting.
$quoted = ($argList | ForEach-Object { '"' + ($_ -replace '"', '\"') + '"' }) -join ' '
Write-Host ("Launching: {0} {1}" -f $portExe.FullName, $quoted) -ForegroundColor DarkGray

# Start-Process inherits this process's environment, so setting it here reaches
# the runner. Saved and restored so it does not leak into the caller's session.
$previousWidescreen = $env:MODERNGEKKO_WIDESCREEN
if ($Widescreen) {
    $env:MODERNGEKKO_WIDESCREEN = '1'
    Write-Host 'Widescreen: MODERNGEKKO_WIDESCREEN=1 (needs the widescreen patch + rebuilt runtime)' -ForegroundColor Cyan
}

$proc = Start-Process -FilePath $portExe.FullName -ArgumentList $quoted `
    -RedirectStandardOutput $outFile -RedirectStandardError $errFile -PassThru -NoNewWindow
# Touch .Handle so .NET caches a handle; without it ExitCode is $null after exit.
$haveHandle = $false
try { $null = $proc.Handle; $haveHandle = $true } catch { }

$timedOut = $false
if ($TimeoutSeconds -gt 0) {
    if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
        $timedOut = $true
        Write-Host 'Timeout reached -- stopping.' -ForegroundColor Yellow
        try { $proc.Kill() } catch { }
        $proc.WaitForExit(5000) | Out-Null
    }
} else { $proc.WaitForExit() }

$env:MODERNGEKKO_WIDESCREEN = $previousWidescreen

$exitCode = $null
try { if ($haveHandle) { $exitCode = $proc.ExitCode } } catch { }
Start-Sleep -Milliseconds 200

$lines = @()
foreach ($f in @($outFile, $errFile)) {
    if (Test-Path $f) { $lines += @(Get-Content -LiteralPath $f -ErrorAction SilentlyContinue) }
}
Set-Content -LiteralPath $LogPath -Value $lines -Encoding UTF8
foreach ($tmp in @($outFile, $errFile)) {
    if (Test-Path $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
}

Write-Host ''
Write-Host '================ SUMMARY ================' -ForegroundColor Cyan
if ($timedOut) {
    Write-Host 'Outcome    : TIMED OUT (killed) -- it was still running' -ForegroundColor Yellow
} elseif ($null -ne $exitCode) {
    $hex = '0x{0:X8}' -f ([uint32]([uint32]::MaxValue -band $exitCode))
    $meaning = ''
    switch ($hex) {
        '0xC0000005' { $meaning = '  <-- ACCESS VIOLATION (crash)' }
        '0xC00000FD' { $meaning = '  <-- STACK OVERFLOW (crash)' }
        '0xC0000135' { $meaning = '  <-- MISSING DLL' }
        '0xC000041D' { $meaning = '  <-- FATAL USER CALLBACK EXCEPTION (fault inside an OS-invoked callback: WndProc, or DllMain on unload)' }
        '0xC0000005' { $meaning = '  <-- ACCESS VIOLATION' }
        '0x00000000' { $meaning = '  (clean exit)' }
    }
    Write-Host ("Outcome    : exited, code {0} ({1}){2}" -f $exitCode, $hex, $meaning)
} else {
    Write-Host 'Outcome    : exited, code unreadable' -ForegroundColor Yellow
}
Write-Host ("Log        : {0}" -f $LogPath)
Write-Host ("Log lines  : {0:N0}" -f $lines.Count)
Write-Host ''
Write-Host '--- last 25 lines ---' -ForegroundColor Cyan
$lines | Select-Object -Last 25 | ForEach-Object { Write-Host "  $_" }
