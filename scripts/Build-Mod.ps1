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

    [Parameter(HelpMessage = 'Override the display name shown in the launcher. Empty uses the mod CMakeLists default.')]
    [string] $ModDisplayName = '',

    [Parameter(HelpMessage = 'Override the mod version. Empty uses the mod CMakeLists default.')]
    [string] $ModVersion = '',

    [Parameter(HelpMessage = 'DolRecomp symbol header to force-include, from Build-Symbols.ps1. Lets the mod use names instead of raw addresses.')]
    [string] $SymbolHeader = '',

    [Parameter(HelpMessage = 'Override the launcher-visible settings. Semicolon-separated key|label|choices|default entries.')]
    [string] $ModSettings = '',

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
if (-not [string]::IsNullOrWhiteSpace($ModId))          { $cfg += "-DMOD_ID=$ModId" }
if (-not [string]::IsNullOrWhiteSpace($ModDisplayName)) { $cfg += "-DMOD_DISPLAY_NAME=$ModDisplayName" }
if (-not [string]::IsNullOrWhiteSpace($ModVersion))     { $cfg += "-DMOD_VERSION=$ModVersion" }
if (-not [string]::IsNullOrWhiteSpace($ModSettings)) { $cfg += "-DMOD_SETTINGS=$ModSettings" }
if (-not [string]::IsNullOrWhiteSpace($SymbolHeader)) {
    if (-not (Test-Path $SymbolHeader)) { throw "Symbol header not found: $SymbolHeader" }
    $cfg += "-DMOD_SYMBOL_HEADER=$((Resolve-Path -LiteralPath $SymbolHeader).Path)"
}

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

# The launcher lists mods by reading this file rather than by loading each
# mod library to call moderngekko_get_mod(), which would execute third-party
# code just to render a label. Values are read back out of the CMake cache so
# the manifest describes what was actually built, not what we assumed.
$cache = Join-Path $BuildDir 'CMakeCache.txt'
if (-not (Test-Path $cache)) { throw "No CMakeCache.txt in $BuildDir -- cannot determine the mod's identity." }
$cacheText = Get-Content -LiteralPath $cache
function Get-CacheValue([string] $Name) {
    $line = $cacheText | Where-Object { $_ -match "^$([regex]::Escape($Name)):[A-Z]+=" } | Select-Object -First 1
    if (-not $line) { return '' }
    return $line.Substring($line.IndexOf('=') + 1)
}
$manifestId      = Get-CacheValue 'MOD_ID'
$manifestName    = Get-CacheValue 'MOD_DISPLAY_NAME'
$manifestVersion = Get-CacheValue 'MOD_VERSION'
if ([string]::IsNullOrWhiteSpace($manifestId)) { throw 'MOD_ID is not set in the CMake cache.' }

$manifest = @(
    '# Read by the launcher to list this mod. Optional: a package without it',
    '# is listed under its directory name.',
    "id=$manifestId"
)
if (-not [string]::IsNullOrWhiteSpace($manifestName))    { $manifest += "name=$manifestName" }
if (-not [string]::IsNullOrWhiteSpace($manifestVersion)) { $manifest += "version=$manifestVersion" }

# Settings the launcher will render. Semicolon-separated in the cache because
# CMake lists are semicolon-separated; one "setting=" line each in mod.ini.
$manifestSettings = Get-CacheValue 'MOD_SETTINGS'
if (-not [string]::IsNullOrWhiteSpace($manifestSettings)) {
    foreach ($entry in $manifestSettings -split ';') {
        $trimmed = $entry.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
        if (($trimmed -split '\|').Count -lt 4) {
            throw "MOD_SETTINGS entry '$trimmed' needs four |-separated fields: key|label|choices|default"
        }
        $manifest += "setting=$trimmed"
    }
}
# WriteAllLines with an explicit no-BOM encoding: Set-Content -Encoding UTF8
# emits a byte order mark on PowerShell 5.1, and a BOM on the first line
# would only be harmless for as long as that line stays a comment.
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllLines((Join-Path $package.FullName 'mod.ini'), $manifest, $utf8NoBom)

Write-Host ''
Write-Host ("Built {0}" -f $package.Name) -ForegroundColor Green
Write-Host ("  manifest: id={0} name={1} version={2}" -f $manifestId, $manifestName, $manifestVersion)
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
