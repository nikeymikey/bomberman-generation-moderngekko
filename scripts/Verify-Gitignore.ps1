<#
.SYNOPSIS
    Prove the .gitignore excludes game-derived data and keeps project sources.
.DESCRIPTION
    Uses `git add -An` as ground truth. `git check-ignore` exits 0 when ANY
    pattern matches -- including a negation -- so its exit code alone can report
    a tracked file as ignored. Submodule contents are never staged by the parent
    (they are recorded as gitlinks, mode 160000), so they are not asserted here.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = 'Repository root. No default.')]
    [string] $RepoRoot,

    [Parameter(Mandatory = $true, HelpMessage = 'Directory holding compiled modules; must be proven ignored.')]
    [string] $ModulesDir
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')

if (-not (Test-GitRepository -Path $RepoRoot)) {
    throw "$RepoRoot is not a git repository. Run Init-Repo.ps1 first."
}

$failures = @()

Write-Host '=== GROUND TRUTH: git add -An (stages nothing) ===' -ForegroundColor Cyan
$addOut = Invoke-Native -FilePath 'git' -ArgumentList @('-C', $RepoRoot, 'add', '-An') -Quiet
if (-not $addOut.Success) {
    # Do NOT carry on: empty output from a FAILED command looks identical to
    # "nothing to stage", and every later check would then report a false
    # failure. Stop and say what actually went wrong.
    Write-Host ''
    Write-Host 'git add -An FAILED -- ground truth is unavailable.' -ForegroundColor Red
    Write-Host $addOut.Text
    if ($addOut.Text -match 'index\.lock') {
        Write-Host ''
        Write-Host 'That is a stale lock from an interrupted git process. Check no git is' -ForegroundColor Yellow
        Write-Host 'running, then remove it and re-run:' -ForegroundColor Yellow
        Write-Host ("    Get-Process git -ErrorAction SilentlyContinue") -ForegroundColor Yellow
        Write-Host ("    Remove-Item '{0}'" -f (Join-Path $RepoRoot '.git\index.lock')) -ForegroundColor Yellow
    }
    throw 'Cannot verify ignore rules while git add -An is failing.'
}
$wouldStage = @($addOut.Output | ForEach-Object { if ($_ -match "^add '(.+)'$") { $Matches[1] } })

$badPattern = '\.(iso|gcm|ciso|rvz|wbfs|dol|rel|adp|mdt|seb|tpl|cod|tnb|sqb|bnr|h4m|tgc|mgm|dll|so|dylib|obj|pdb|ilk|exp|exe|lib|log)$'
# Also catch foo.log.out / foo.log.err -- `\.log$` misses them, and two such
# files reached a commit because the rule and this check shared that blind spot.
$badPattern2 = '\.log\.(out|err)$'
$badStage = @($wouldStage | Where-Object {
    $_ -match $badPattern -or $_ -match $badPattern2 -or
    $_ -match '^(extracted|generated|iso|extern|saves)/' -or
    $_ -match '(^|/)build/'
})
if ($badStage.Count -gt 0) {
    foreach ($b in $badStage) { Write-Host ("  WOULD STAGE: {0}   <-- FAIL" -f $b) -ForegroundColor Red }
    $failures += 'game data, generated code or build output would be committed'
} else {
    Write-Host ("  {0} file(s) would stage, none of them game data, generated code or build output." -f $wouldStage.Count)
}

Write-Host ''
Write-Host '=== project sources must be tracked ===' -ForegroundColor Cyan
foreach ($needed in @('.gitignore', 'README.md', '.gitmodules',
                      'scripts/Common.ps1', 'scripts/Build-Tools.ps1',
                      'scripts/Extract-Iso.ps1', 'scripts/Build-Module.ps1',
                      'scripts/Run-Game.ps1', 'scripts/Verify-Gitignore.ps1',
                      'scripts/Init-Repo.ps1')) {
    $tracked = $wouldStage -contains $needed
    if (-not $tracked) {
        $ls = Invoke-Native -FilePath 'git' -ArgumentList @('-C', $RepoRoot, 'ls-files', '--', $needed) -Quiet
        $tracked = -not [string]::IsNullOrWhiteSpace($ls.Text)
    }
    if ($tracked) { Write-Host ("  ok        {0}" -f $needed) }
    else { Write-Host ("  MISSING   {0}   <-- FAIL" -f $needed) -ForegroundColor Red; $failures += "not committed: $needed" }
}

Write-Host ''
Write-Host '=== submodules recorded as gitlinks (not contents) ===' -ForegroundColor Cyan
foreach ($sub in @('lib/DolRecomp', 'lib/ModernGekko')) {
    $ls = Invoke-Native -FilePath 'git' -ArgumentList @('-C', $RepoRoot, 'ls-files', '-s', '--', $sub) -Quiet
    if ($ls.Text -match '^160000') { Write-Host ("  ok        {0} (gitlink)" -f $sub) }
    elseif ([string]::IsNullOrWhiteSpace($ls.Text)) { Write-Host ("  not yet staged: {0}" -f $sub) -ForegroundColor DarkGray }
    else { Write-Host ("  {0} is NOT a gitlink -- its contents may get committed   <-- FAIL" -f $sub) -ForegroundColor Red
           $failures += "$sub is not a submodule gitlink" }
}

Write-Host ''
Write-Host '=== already-tracked game data? ===' -ForegroundColor Cyan
$tracked = (Invoke-Native -FilePath 'git' -ArgumentList @('-C', $RepoRoot, 'ls-files') -Quiet).Output
$big = @($tracked | Where-Object { $_ -match $badPattern -or $_ -match $badPattern2 })
if ($big.Count -gt 0) {
    foreach ($b in $big) { Write-Host ("  TRACKED: {0}   <-- FAIL" -f $b) -ForegroundColor Red }
    $failures += 'game data is already tracked'
} else { Write-Host '  none' }

Write-Host ''
if ($failures.Count -gt 0) {
    Write-Host ("VERIFICATION FAILED ({0}):" -f $failures.Count) -ForegroundColor Red
    foreach ($f in $failures) { Write-Host "  - $f" -ForegroundColor Red }
    exit 1
}
Write-Host 'VERIFIED: ignore rules behave correctly in both directions.' -ForegroundColor Green
exit 0
