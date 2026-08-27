<#
.SYNOPSIS
    Build DolRecomp (recompiler) and moderngekko-port (build/run driver).
.DESCRIPTION
    The upstream template uses -G Ninja. This uses the Visual Studio generator
    by default because v143 selection has already been verified that way on this
    machine, and Ninja would additionally require ninja on PATH plus a developer
    environment. Pass -Generator to override.

    ModernGekko builds Dolphin and ~49 Externals. The first build is long.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = 'Repository root. No default.')]
    [string] $RepoRoot,

    [Parameter(HelpMessage = 'CMake generator. Default matches the verified v143 setup.')]
    [string] $Generator = 'Visual Studio 17 2022',

    [Parameter(HelpMessage = 'Platform for the VS generator. Ignored by Ninja.')]
    [string] $Architecture = 'x64',

    [ValidateSet('Debug', 'Release', 'RelWithDebInfo')]
    [string] $Config = 'Release',

    [Parameter(HelpMessage = 'Optional CMake -T toolset spec, e.g. host=x64.')]
    [string] $Toolset = '',

    [switch] $EnableLlvm,
    [string] $LlvmDir = '',

    [Parameter(HelpMessage = 'Delete an existing build directory whose generator does not match. Without this, a mismatch STOPS rather than discarding work.')]
    [switch] $Fresh,

    [Parameter(HelpMessage = 'Also build the GUI launcher (moderngekko-launcher).')]
    [switch] $WithLauncher,

    [Parameter(HelpMessage = 'Six-character disc ID the launcher will accept. Without this the launcher has NO accept path and rejects every disc with "this disc is not the pinned patched release".')]
    [string] $DiscId = 'GBGE5G',

    [Parameter(HelpMessage = 'Optional: also require this exact main.dol SHA-256. Stricter ownership check; leave empty until the disc ID alone is known to work.')]
    [string] $DolSha256 = '',

    [Parameter(HelpMessage = 'Optional: branded display name shown by the frontend.')]
    [string] $FrontendName = '',

    [Parameter(HelpMessage = 'Optional: launcher executable filename, without extension.')]
    [string] $LauncherName = '',

    [Parameter(HelpMessage = 'Keep config, saves and logs in a User folder beside the executable instead of %LOCALAPPDATA%. Requires the moderngekko-portable-userdir patch.')]
    [switch] $PortableUserDir,

    [Parameter(HelpMessage = 'Write GameCube pad profiles (GCPadNew.ini) instead of Wii Remote profiles. Required for a GameCube game, or the pad has no bindings. Defaults ON for this project.')]
    [bool] $GameCubeControllers = $true,

    [Parameter(HelpMessage = 'Minimum Windows API level for MinGW builds. Dolphin never sets this and MinGW defaults to 0x0601 (Windows 7), which hides the Win8/Win10 APIs Dolphin uses. Ignored for MSVC. Empty string disables.')]
    [string] $WindowsTargetVersion = '0x0A00',

    [Parameter(HelpMessage = 'NTDDI level for MinGW builds; gates HCMNOTIFICATION and friends.')]
    [string] $NtddiVersion = '0x0A000004'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')

$dolSrc = Join-Path $RepoRoot 'lib\DolRecomp'
$mgSrc  = Join-Path $RepoRoot 'lib\ModernGekko'
foreach ($s in @($dolSrc, $mgSrc)) {
    if (-not (Test-Path (Join-Path $s 'CMakeLists.txt'))) {
        throw "No CMakeLists.txt in $s -- run Init-Repo.ps1 first."
    }
}

$llvmFlag = 'OFF'
if ($EnableLlvm) { $llvmFlag = 'ON' }

function Get-CacheValue([string] $CachePath, [string] $Key) {
    if (-not (Test-Path $CachePath)) { return $null }
    foreach ($line in (Get-Content -LiteralPath $CachePath)) {
        if ($line -match ("^" + [regex]::Escape($Key) + ":[^=]*=(.*)$")) { return $Matches[1].Trim() }
    }
    return $null
}

function Assert-GeneratorMatches([string] $BuildDir, [string] $Wanted) {
    $cache = Join-Path $BuildDir 'CMakeCache.txt'
    $existing = Get-CacheValue $cache 'CMAKE_GENERATOR'
    if (-not $existing) { return }
    if ($existing -eq $Wanted) { return }

    # Report what is actually there before touching anything -- a configured
    # build directory can represent a lot of compiled work.
    $objs = @(Get-ChildItem -Path $BuildDir -Recurse -Include '*.obj', '*.o' -ErrorAction SilentlyContinue)
    $cc   = Get-CacheValue $cache 'CMAKE_C_COMPILER'
    Write-Host ''
    Write-Host ("Build directory already configured with a DIFFERENT generator:" ) -ForegroundColor Yellow
    Write-Host ("  directory : {0}" -f $BuildDir)
    Write-Host ("  existing  : {0}" -f $existing)
    Write-Host ("  requested : {0}" -f $Wanted)
    if ($cc) { Write-Host ("  compiler  : {0}" -f $cc) }
    Write-Host ("  compiled  : {0} object file(s) already built" -f $objs.Count)

    if (-not $Fresh) {
        Write-Host ''
        Write-Host 'STOPPING rather than discarding that work.' -ForegroundColor Red
        Write-Host 'Either keep the existing generator:' -ForegroundColor Yellow
        Write-Host ("    -Generator '{0}'" -f $existing) -ForegroundColor Yellow
        Write-Host 'or discard the build directory and start over:' -ForegroundColor Yellow
        Write-Host '    -Fresh' -ForegroundColor Yellow
        throw "Generator mismatch in $BuildDir (have '$existing', want '$Wanted')."
    }

    Write-Host ''
    Write-Host ("-Fresh given: deleting {0}" -f $BuildDir) -ForegroundColor Yellow
    Remove-Item -LiteralPath $BuildDir -Recurse -Force
}

function Invoke-CMakeBuild([string] $Source, [string] $BuildDir, [string] $Target, [string] $Label) {
    Assert-GeneratorMatches $BuildDir $Generator

    $cfg = @('-S', $Source, '-B', $BuildDir, '-G', $Generator)
    if ($Generator -like 'Visual Studio*') {
        $cfg += @('-A', $Architecture)
        if (-not [string]::IsNullOrWhiteSpace($Toolset)) { $cfg += @('-T', $Toolset) }
    }
    $cfg += @("-DCMAKE_BUILD_TYPE=$Config", '-DBUILD_TESTING=OFF', "-DDOLRECOMP_ENABLE_LLVM=$llvmFlag")
    if ($EnableLlvm -and -not [string]::IsNullOrWhiteSpace($LlvmDir)) { $cfg += "-DLLVM_DIR=$LlvmDir" }

    # ---- Branded build -------------------------------------------------------
    # moderngekko-launcher's PrepareDisc() only has an accept path inside
    #   #ifdef MODERNGEKKO_REQUIRED_DISC_ID
    # Without it every disc falls through to the #else and is rejected with
    # "this disc is not the pinned patched release". These are cache variables,
    # so they apply to both moderngekko-run and moderngekko-launcher.
    if (-not [string]::IsNullOrWhiteSpace($DiscId)) {
        $cfg += "-DMODERNGEKKO_REQUIRED_DISC_ID=$DiscId"
    }
    if (-not [string]::IsNullOrWhiteSpace($DolSha256)) {
        $cfg += "-DMODERNGEKKO_REQUIRED_DOL_SHA256=$DolSha256"
    }
    if (-not [string]::IsNullOrWhiteSpace($FrontendName)) {
        $cfg += "-DMODERNGEKKO_FRONTEND_NAME=$FrontendName"
    }
    if (-not [string]::IsNullOrWhiteSpace($LauncherName)) {
        $cfg += "-DMODERNGEKKO_LAUNCHER_OUTPUT_NAME=$LauncherName"
    }
    if ($PortableUserDir) {
        $cfg += '-DMODERNGEKKO_PORTABLE_USER_DIRECTORY=ON'
    }
    # Without this the frontend writes WiimoteNew.ini ([Wiimote1] sections) and
    # leaves GCPadNew.ini empty, so a GameCube pad ends up with no bindings even
    # though the launcher shows it as selected.
    if ($GameCubeControllers) {
        $cfg += '-DMODERNGEKKO_GAMECUBE_CONTROLLERS=ON'
    }

    # ---- MinGW: raise the Windows API level ---------------------------------
    # Dolphin never defines _WIN32_WINNT / NTDDI_VERSION; on MSVC the toolchain
    # defaults them to a Windows 10 level. MinGW defaults to 0x0601 (Windows 7),
    # so Win8/Win10 APIs Dolphin calls are hidden behind version gates:
    #   SetProcessInformation / GetProcessInformation  (Win8,  0x0602)
    #   HCMNOTIFICATION                                 (Win10 1709)
    # producing "was not declared in this scope" / "does not name a type".
    # Applied only for a GNU/Clang compiler; MSVC neither needs nor wants it.
    if ($Generator -notlike 'Visual Studio*' -and -not [string]::IsNullOrWhiteSpace($WindowsTargetVersion)) {
        $winDefs = "-D_WIN32_WINNT=$WindowsTargetVersion -DWINVER=$WindowsTargetVersion"
        if (-not [string]::IsNullOrWhiteSpace($NtddiVersion)) { $winDefs += " -DNTDDI_VERSION=$NtddiVersion" }
        $cfg += @("-DCMAKE_C_FLAGS=$winDefs", "-DCMAKE_CXX_FLAGS=$winDefs")
        Write-Host ("Windows API level for MinGW: {0}" -f $winDefs) -ForegroundColor DarkGray
    }

    Write-Host ""
    Write-Host ("=== Configuring {0} -> {1}" -f $Label, $BuildDir) -ForegroundColor Cyan
    Invoke-NativeChecked -FilePath 'cmake' -ArgumentList $cfg -What "cmake configure ($Label)" | Out-Null

    Write-Host ("=== Building {0} target '{1}' ({2})" -f $Label, $Target, $Config) -ForegroundColor Cyan
    $buildArgs = @('--build', $BuildDir, '--target', $Target)
    # --config is meaningful only for multi-config generators; Ninja warns.
    if ($Generator -like 'Visual Studio*') { $buildArgs += @('--config', $Config) }
    Invoke-NativeChecked -FilePath 'cmake' -ArgumentList $buildArgs -What "cmake build ($Label)" | Out-Null
}

if (-not [string]::IsNullOrWhiteSpace($DiscId)) {
    Write-Host ("Branded build: accepting disc ID '{0}'" -f $DiscId) -ForegroundColor Cyan
} elseif ($WithLauncher) {
    Write-Host 'WARNING: no -DiscId given. The launcher will reject every disc.' -ForegroundColor Yellow
}

Invoke-CMakeBuild $dolSrc (Join-Path $dolSrc 'build') 'dolrecomp'        'DolRecomp'
Invoke-CMakeBuild $mgSrc  (Join-Path $mgSrc  'build') 'moderngekko-port' 'ModernGekko'
if ($WithLauncher) {
    Invoke-CMakeBuild $mgSrc (Join-Path $mgSrc 'build') 'moderngekko-launcher' 'ModernGekko launcher'
}

$dolExe = Get-ChildItem -Path (Join-Path $dolSrc 'build') -Recurse -Filter 'dolrecomp.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
$portExe = Get-ChildItem -Path (Join-Path $mgSrc 'build') -Recurse -Filter 'moderngekko-port.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $dolExe)  { throw "Build succeeded but dolrecomp.exe was not found under $dolSrc\build" }
if (-not $portExe) { throw "Build succeeded but moderngekko-port.exe was not found under $mgSrc\build" }

Write-Host ''
Write-Host ("dolrecomp        : {0}" -f $dolExe.FullName)  -ForegroundColor Green
Write-Host ("moderngekko-port : {0}" -f $portExe.FullName) -ForegroundColor Green
if ($WithLauncher) {
    $launcherExe = Get-ChildItem -Path (Join-Path $mgSrc 'build') -Recurse -Filter 'ModernGekko.exe' -ErrorAction SilentlyContinue |
                   Select-Object -First 1
    if (-not $launcherExe) {
        $launcherExe = Get-ChildItem -Path (Join-Path $mgSrc 'build') -Recurse -Filter 'moderngekko-launcher.exe' -ErrorAction SilentlyContinue |
                       Select-Object -First 1
    }
    if ($launcherExe) { Write-Host ("launcher         : {0}" -f $launcherExe.FullName) -ForegroundColor Green }
    else { Write-Host 'launcher         : built, but the executable was not found by name' -ForegroundColor Yellow }
}
