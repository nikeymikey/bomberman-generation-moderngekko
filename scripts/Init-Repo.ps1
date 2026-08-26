<#
.SYNOPSIS
    Initialise the ModernGekko recomp repository and pin both submodules.
.DESCRIPTION
    Pulls lib/DolRecomp (the recompiler) and lib/ModernGekko (the Dolphin-derived
    runtime). ModernGekko recurses into vendor/dolphin and ~49 Externals.

    Roughly 1.2 GB is fetched in total.

    Dolphin pins Externals/bzip2 to https://gitlab.com/bzip2/bzip2.git, which
    fails with HTTP 403 from at least two independent networks -- it is the URL,
    not your connection. This script works around it with a git `insteadOf`
    rewrite to https://github.com/libarchive/bzip2.git, which carries the SAME
    pinned commit (6a8690fc8d26c815e798c588f796eabe9d684cf0), so the checkout is
    byte-identical to upstream's intent rather than a version substitution.

    The rewrite must be GLOBAL: nested submodules are fetched in their own repo
    context, so a repo-local setting would not apply to Externals/bzip2. It is
    announced before it is applied, rewrites exactly one URL, and the undo
    command is printed. Pass -NoUrlRewrite to skip it.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = 'Repository root. No default.')]
    [string] $RepoRoot,

    [string] $DolRecompUrl   = 'https://github.com/ExpansionPak/DolRecomp.git',
    [string] $ModernGekkoUrl = 'https://github.com/ExpansionPak/ModernGekko.git',

    [Parameter(HelpMessage = 'Reachable mirror carrying the same pinned bzip2 commit.')]
    [string] $Bzip2MirrorUrl = 'https://github.com/libarchive/bzip2.git',

    [Parameter(HelpMessage = 'Skip the bzip2 URL rewrite (the clone will then fail if gitlab is unreachable).')]
    [switch] $NoUrlRewrite
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')

if (-not (Test-Path $RepoRoot)) { throw "RepoRoot does not exist: $RepoRoot" }

if (Test-GitRepository -Path $RepoRoot) {
    Write-Host "Git repository already present in $RepoRoot" -ForegroundColor DarkGray
} else {
    Write-Host "Initialising git repository in $RepoRoot" -ForegroundColor Cyan
    Invoke-NativeChecked -FilePath 'git' -ArgumentList @('-C', $RepoRoot, 'init') -What 'git init' | Out-Null
}

$subs = @(
    @{ Path = 'lib/DolRecomp';   Url = $DolRecompUrl },
    @{ Path = 'lib/ModernGekko'; Url = $ModernGekkoUrl }
)
foreach ($s in $subs) {
    $full = Join-Path $RepoRoot ($s.Path -replace '/', '\')
    if (Test-Path (Join-Path $full '.git')) {
        Write-Host ("Submodule already present: {0}" -f $s.Path) -ForegroundColor DarkGray
        continue
    }
    if ((Test-Path $full) -and -not (Get-ChildItem -Force $full -ErrorAction SilentlyContinue)) {
        Remove-Item $full -Force
    }
    Write-Host ("Adding submodule {0}" -f $s.Path) -ForegroundColor Cyan
    Invoke-NativeChecked -FilePath 'git' `
        -ArgumentList @('-C', $RepoRoot, 'submodule', 'add', $s.Url, $s.Path) `
        -What ("git submodule add " + $s.Path) | Out-Null
}

# ---- bzip2 URL rewrite ------------------------------------------------------
$gitlabBzip2 = 'https://gitlab.com/bzip2/bzip2.git'
if (-not $NoUrlRewrite) {
    $existing = Invoke-Native -FilePath 'git' `
        -ArgumentList @('config', '--global', '--get', ("url." + $Bzip2MirrorUrl + ".insteadOf")) -Quiet
    if ($existing.Success -and $existing.Text.Trim() -eq $gitlabBzip2) {
        Write-Host 'bzip2 URL rewrite already configured.' -ForegroundColor DarkGray
    } else {
        Write-Host ''
        Write-Host 'Applying a GLOBAL git URL rewrite:' -ForegroundColor Yellow
        Write-Host ("  {0}" -f $gitlabBzip2) -ForegroundColor Yellow
        Write-Host ("    -> {0}" -f $Bzip2MirrorUrl) -ForegroundColor Yellow
        Write-Host '  Dolphin pins bzip2 to a gitlab URL that returns HTTP 403 from multiple' -ForegroundColor Yellow
        Write-Host '  networks. The mirror carries the SAME pinned commit, so this is not a' -ForegroundColor Yellow
        Write-Host '  version substitution. It must be global because nested submodules fetch' -ForegroundColor Yellow
        Write-Host '  in their own repo context. It rewrites exactly one URL.' -ForegroundColor Yellow
        Write-Host '  Undo with:' -ForegroundColor Yellow
        Write-Host ("    git config --global --unset url.{0}.insteadOf" -f $Bzip2MirrorUrl) -ForegroundColor Yellow
        Write-Host ''
        Invoke-NativeChecked -FilePath 'git' `
            -ArgumentList @('config', '--global', ("url." + $Bzip2MirrorUrl + ".insteadOf"), $gitlabBzip2) `
            -What 'git config url.insteadOf' | Out-Null
    }
}

Write-Host 'Fetching submodules recursively (Dolphin + ~49 Externals, about 1.2 GB; expect several minutes)...' -ForegroundColor Cyan
$r = Invoke-Native -FilePath 'git' `
    -ArgumentList @('-C', $RepoRoot, 'submodule', 'update', '--init', '--recursive', '--depth', '1')
if (-not $r.Success) {
    Write-Host ''
    Write-Host "Recursive submodule fetch failed (exit $($r.ExitCode))." -ForegroundColor Red
    if ($r.Text -match 'gitlab\.com') {
        if ($NoUrlRewrite) {
            Write-Host 'It failed on the gitlab-hosted bzip2 External. Re-run WITHOUT' -ForegroundColor Yellow
            Write-Host '-NoUrlRewrite to route it through the mirror.' -ForegroundColor Yellow
        } else {
            Write-Host 'It still failed on a gitlab.com URL despite the rewrite. Check:' -ForegroundColor Yellow
            Write-Host '  git config --global --get-regexp "url\..*insteadOf"' -ForegroundColor Yellow
        }
    }
    throw 'Submodule fetch incomplete -- do not proceed until it succeeds.'
}

foreach ($needed in @('lib\DolRecomp\CMakeLists.txt',
                      'lib\ModernGekko\CMakeLists.txt',
                      'lib\ModernGekko\vendor\dolphin\CMakeLists.txt',
                      'lib\ModernGekko\vendor\dolphin\Externals\bzip2\bzip2\bzlib.c')) {
    $p = Join-Path $RepoRoot $needed
    if (-not (Test-Path $p)) { throw "Expected file missing after clone: $p" }
}

Write-Host ''
Write-Host 'Repository ready; DolRecomp and ModernGekko are checked out.' -ForegroundColor Green
Write-Host 'NOTHING IS COMMITTED YET. Run scripts\Verify-Gitignore.ps1 before the first commit.' -ForegroundColor Yellow
