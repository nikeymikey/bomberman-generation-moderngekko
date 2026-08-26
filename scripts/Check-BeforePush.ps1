<#
.SYNOPSIS
    Audit a repository before its first push to a remote.
.DESCRIPTION
    Checks the whole COMMIT HISTORY, not just the working tree -- a file removed
    in a later commit is still published if an earlier commit contains it.

    Verifies:
      * no game-derived data in any commit (ISO, DOL, extracted assets, modules)
      * no generated recompiler output in any commit
      * no implausibly large blobs
      * submodules recorded as gitlinks, not vendored contents
      * a LICENSE exists if the tree links GPL code

    Read-only: runs no command that takes .git/index.lock.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = 'Repository root. No default.')]
    [string] $RepoRoot,

    [Parameter(HelpMessage = 'Flag any blob larger than this many MB.')]
    [int] $MaxBlobMB = 5
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')

if (-not (Test-GitRepository -Path $RepoRoot)) { throw "$RepoRoot is not a git repository." }

$commits = (Invoke-Native -FilePath 'git' -ArgumentList @('-C', $RepoRoot, 'rev-list', '--count', '--all') -Quiet).Text.Trim()
Write-Host ("Commits in history : {0}" -f $commits)
if ($commits -eq '0') { throw 'No commits yet -- commit before auditing.' }

$failures = @()

Write-Host ''
Write-Host '=== every path ever committed ===' -ForegroundColor Cyan
$allPaths = @((Invoke-Native -FilePath 'git' `
    -ArgumentList @('-C', $RepoRoot, 'log', '--all', '--pretty=format:', '--name-only', '--diff-filter=A') -Quiet).Output |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
Write-Host ("  {0} distinct path(s) across all commits" -f $allPaths.Count)

$gameData = '\.(iso|gcm|ciso|rvz|wbfs|nkit|dol|rel|adp|mdt|seb|tpl|cod|tnb|sqb|bnr|h4m|tgc)$'
$builtArt = '\.(mgm|dll|so|dylib|obj|o|a|lib|exe|pdb|ilk|exp)$'
$genCode  = '^(generated|recompiled)/|(^|/)(recomp_\d+\.cpp|generated\.c|chunk_\d+.*\.c)$'
$logSide  = '\.log(\.(out|err))?$'

foreach ($set in @(
    @{ Name = 'GAME DATA';        Pattern = $gameData },
    @{ Name = 'BUILT ARTIFACTS';  Pattern = $builtArt },
    @{ Name = 'GENERATED CODE';   Pattern = $genCode  },
    @{ Name = 'LOG FILES';        Pattern = $logSide  }
)) {
    $hits = @($allPaths | Where-Object { $_ -match $set.Pattern })
    if ($hits.Count -gt 0) {
        Write-Host ("  {0}: {1} found <-- FAIL" -f $set.Name, $hits.Count) -ForegroundColor Red
        $hits | Select-Object -First 10 | ForEach-Object { Write-Host ("    {0}" -f $_) }
        $failures += ("$($set.Name) present in history")
    } else {
        Write-Host ("  {0}: none" -f $set.Name) -ForegroundColor Green
    }
}

Write-Host ''
Write-Host '=== large blobs in history ===' -ForegroundColor Cyan
# --batch-all-objects needs no stdin, which PowerShell cannot redirect with '<'.
$big = @()
$sizes = (Invoke-Native -FilePath 'git' `
    -ArgumentList @('-C', $RepoRoot, 'cat-file', '--batch-check=%(objecttype) %(objectsize)', '--batch-all-objects') `
    -Quiet).Output
foreach ($line in $sizes) {
    if ($line -match '^blob\s+(\d+)$') {
        $mb = [double]$Matches[1] / 1MB
        if ($mb -ge $MaxBlobMB) { $big += ("{0:N1} MB" -f $mb) }
    }
}
if ($big.Count -gt 0) {
    Write-Host ("  {0} blob(s) >= {1} MB <-- review" -f $big.Count, $MaxBlobMB) -ForegroundColor Yellow
    $big | Sort-Object -Descending | Select-Object -First 5 | ForEach-Object { Write-Host ("    {0}" -f $_) }
} else {
    Write-Host ("  none >= {0} MB" -f $MaxBlobMB) -ForegroundColor Green
}

Write-Host ''
Write-Host '=== submodules are gitlinks (contents NOT published) ===' -ForegroundColor Cyan
$ls = (Invoke-Native -FilePath 'git' -ArgumentList @('-C', $RepoRoot, 'ls-files', '-s') -Quiet).Output
$links = @($ls | Where-Object { $_ -match '^160000' })
if ($links.Count -gt 0) {
    foreach ($l in $links) { Write-Host ("  ok  {0}" -f (($l -split "`t")[-1])) -ForegroundColor Green }
} else { Write-Host '  (no submodules)' }
$vendored = @($allPaths | Where-Object { $_ -match '^lib/(DolRecomp|ModernGekko)/.+' })
if ($vendored.Count -gt 0) {
    Write-Host ("  {0} submodule file(s) committed as CONTENT <-- FAIL" -f $vendored.Count) -ForegroundColor Red
    $failures += 'submodule contents committed instead of gitlinks'
}

Write-Host ''
Write-Host '=== licensing ===' -ForegroundColor Cyan
$hasLicense = $allPaths | Where-Object { $_ -match '^(LICENSE|COPYING)' }
$linksGpl = Test-Path (Join-Path $RepoRoot 'lib\ModernGekko')
if ($linksGpl -and -not $hasLicense) {
    Write-Host '  Links GPL-3.0 code (ModernGekko) but no LICENSE is committed.' -ForegroundColor Yellow
    Write-Host '  Publishing the combined work makes it GPL-3.0. Add a LICENSE before pushing.' -ForegroundColor Yellow
} elseif ($hasLicense) {
    Write-Host '  LICENSE present.' -ForegroundColor Green
} else {
    Write-Host '  No GPL dependency detected.' -ForegroundColor Green
}

Write-Host ''
if ($failures.Count -gt 0) {
    Write-Host ("NOT SAFE TO PUSH ({0} problem(s)):" -f $failures.Count) -ForegroundColor Red
    foreach ($f in $failures) { Write-Host "  - $f" -ForegroundColor Red }
    Write-Host ''
    Write-Host 'History rewriting is needed -- removing the file in a new commit is NOT enough.' -ForegroundColor Yellow
    exit 1
}
Write-Host 'SAFE TO PUSH: no game data, generated code or build output in any commit.' -ForegroundColor Green
exit 0
