<#
.SYNOPSIS
    Build a ModernGekko mod into a .mgm package, and optionally install it.
.DESCRIPTION
    A .mgm package is a DIRECTORY named <mod-id>.mgm containing the platform
    library under the exact name "mod" (mod.dll on Windows). That is what
    DiscoverModSources() looks for; anything else is reported as "package has
    no platform mod library" and skipped silently as far as the game is
    concerned.

    The runner searches <exe dir>\Mods and <user dir>\Mods by default, so
    -InstallDir is normally one of those. Nothing is guessed: every directory
    is a parameter.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = 'Repository root. No default.')]
    [string] $RepoRoot,

    [Parameter(Mandatory = $true, HelpMessage = 'Mod source directory containing CMakeLists.txt. No default.')]
    [string] $ModPath,

    [Parameter(Mandatory = $true, HelpMessage = 'Directory to configure and build in. No default.')]
    [string] $BuildDir,

    [Parameter(HelpMessage = 'Copy the finished .mgm here. Typically <runner dir>\Mods.')]
    [string] $InstallDir = '',

    [Parameter(HelpMessage = 'Disc ID the mod declares. Must match the running game or the loader rejects it.')]
    [string] $GameId = 'GBGE5G',

    [Parameter(HelpMessage = 'Override the mod ID. Empty uses the mod CMakeLists default.')]
    [string] $ModId = '',

    [string] $Generator = 'Ninja',

    [ValidateSet('Debug', 'Release', 'RelWithDebInfo')]
    [string] $Config = 'Release',

    [Parameter(HelpMessage = 'Delete the build directory first.')]
    [switch] $Fresh
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')

if (-not (Test-Path $RepoRoot)) { throw "RepoRoot does not exist: $RepoRoot" }
$cmakeLists = Join-Path $ModPath 'CMakeLists.txt'
if (-not (Test-Path $cmakeLists)) { throw "No CMakeLists.txt in ModPath: $ModPath" }

$mgSource = Join-Path $RepoRoot 'lib\ModernGekko'
if (-not (Test-Path (Join-Path $mgSource 'include\moderngekko\mod_abi.h'))) {
    throw "ModernGekko headers not found under $mgSource -- run Init-Repo.ps1 first."
}

if ($Fresh -and (Test-Path $BuildDir)) {
    Write-Host "Removing $BuildDir" -ForegroundColor Yellow
    Remove-Item -LiteralPath $BuildDir -Recurse -Force
}

$cfg = @(
    '-S', $ModPath,
    '-B', $BuildDir,
    '-G', $Generator,
    "-DCMAKE_BUILD_TYPE=$Config",
    "-DMODERNGEKKO_SOURCE_DIR=$mgSource",
    "-DMOD_GAME_ID=$GameId"
)
if (-not [string]::IsNullOrWhiteSpace($ModId)) { $cfg += "-DMOD_ID=$ModId" }

Write-Host ''
Write-Host ("Configuring {0}" -f $ModPath) -ForegroundColor Cyan
Invoke-NativeChecked -FilePath 'cmake' -ArgumentList $cfg -What 'cmake configure' | Out-Null

Write-Host ("Building ({0})" -f $Config) -ForegroundColor Cyan
Invoke-NativeChecked -FilePath 'cmake' -ArgumentList @('--build', $BuildDir, '--config', $Config) `
    -What 'cmake build' | Out-Null

# Verify the result rather than trusting the exit code: a build can succeed
# while putting the library somewhere the loader will never look.
$packages = @(Get-ChildItem -Path $BuildDir -Directory -Filter '*.mgm' -ErrorAction SilentlyContinue)
if ($packages.Count -eq 0) {
    throw "Build reported success but no .mgm package was produced under $BuildDir."
}
if ($packages.Count -gt 1) {
    throw ("Expected one .mgm package, found {0}: {1}" -f $packages.Count, ($packages.Name -join ', '))
}
$package = $packages[0]
$library = Join-Path $package.FullName 'mod.dll'
if (-not (Test-Path $library)) {
    throw "$($package.Name) has no mod.dll -- DiscoverModSources would skip it. Check OUTPUT_NAME/PREFIX in the mod's CMakeLists."
}

Write-Host ''
Write-Host ("Built {0}" -f $package.Name) -ForegroundColor Green
Write-Host ("  {0}  ({1:N0} bytes)" -f $library, (Get-Item $library).Length)

if (-not [string]::IsNullOrWhiteSpace($InstallDir)) {
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    $target = Join-Path $InstallDir $package.Name
    if (Test-Path $target) { Remove-Item -LiteralPath $target -Recurse -Force }
    Copy-Item -LiteralPath $package.FullName -Destination $target -Recurse -Force
    if (-not (Test-Path (Join-Path $target 'mod.dll'))) {
        throw "Copied $($package.Name) to $InstallDir but mod.dll is not there."
    }
    Write-Host ''
    Write-Host ("Installed to {0}" -f $target) -ForegroundColor Green
} else {
    Write-Host ''
    Write-Host 'Not installed: pass -InstallDir to copy it where the runner looks.' -ForegroundColor DarkGray
}
