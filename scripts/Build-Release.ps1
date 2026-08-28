<#
.SYNOPSIS
    Assemble a distributable folder, and refuse to put game code in it.
.DESCRIPTION
    The recompiled module is derived from the game's own binary and cannot be
    distributed. Every recipient compiles it from the disc image they supply,
    which the launcher does on first run. This script therefore does two jobs:
    copy what may ship, and actively verify that nothing that may not ship has
    ended up in the output.

    That second job is the important one. The build directory contains
    g<DISCID>_recomp.dll right next to the executables, so a careless copy
    would ship the game. The check here is a positive scan of the finished
    folder rather than trust in the copy list.

    Dolphin's Sys directory is deliberately absent: this configuration runs
    without it (verified by running with no Sys folder next to the executable),
    so shipping one would be cargo cult.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = 'Repository root. No default.')]
    [string] $RepoRoot,

    [Parameter(Mandatory = $true, HelpMessage = 'Folder to assemble the release in. No default.')]
    [string] $OutputDir,

    [Parameter(HelpMessage = 'MinGW-w64 root to bundle, containing bin\gcc.exe. Omitted means recipients must supply their own compiler.')]
    [string] $ToolchainPath = '',

    [Parameter(HelpMessage = 'Version label recorded in the manifest.')]
    [string] $Version = '',

    [Parameter(HelpMessage = 'Mods to include, by .mgm directory name.')]
    [string[]] $Mods = @('starting_bombs.mgm'),

    [Parameter(HelpMessage = 'MinGW bin directory to take runtime DLLs from (libgcc, libstdc++, libwinpthread). Defaults to <ToolchainPath>\bin when that is given.')]
    [string] $RuntimeDllDir = '',

    [Parameter(HelpMessage = 'Also produce a .zip for upload. The folder is stored inside it under its own name.')]
    [string] $ZipPath = '',

    [Parameter(HelpMessage = 'Delete the output folder first.')]
    [switch] $Fresh
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')

$buildDir = Join-Path $RepoRoot 'lib\ModernGekko\build'
if (-not (Test-Path $buildDir)) { throw "No build directory at $buildDir. Run Build-Tools.ps1 first." }

if ($Fresh -and (Test-Path $OutputDir)) { Remove-Item -LiteralPath $OutputDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

# ---- executables ------------------------------------------------------------
# dolrecomp and moderngekko-port are not optional extras: they are what turns
# the recipient's disc image into a playable module on first run.
$required = @(
    'ModernGekko.exe',      # launcher
    'moderngekko-run.exe',  # runner
    'moderngekko-port.exe', # drives the first-run build
    'dolrecomp.exe'         # the recompiler itself
)
foreach ($name in $required) {
    $source = Join-Path $buildDir $name
    if (-not (Test-Path $source)) { throw "Missing $name in $buildDir -- build with -WithLauncher." }
    Copy-Item -LiteralPath $source -Destination (Join-Path $OutputDir $name) -Force
    Write-Host ("  {0}" -f $name) -ForegroundColor DarkGray
}

# SDL is linked statically in this configuration; a loose DLL appearing here
# would mean the build changed, so say so rather than silently omitting it.
$strayDlls = @(Get-ChildItem -Path $buildDir -Filter '*.dll' -File -ErrorAction SilentlyContinue |
               Where-Object { $_.Name -notlike 'g*_recomp.dll' })
if ($strayDlls.Count -gt 0) {
    Write-Host ''
    Write-Host 'Runtime DLLs found beside the executables; copying them:' -ForegroundColor Yellow
    foreach ($dll in $strayDlls) {
        Copy-Item -LiteralPath $dll.FullName -Destination (Join-Path $OutputDir $dll.Name) -Force
        Write-Host ("  {0}" -f $dll.Name) -ForegroundColor DarkGray
    }
}

# ---- mods -------------------------------------------------------------------
$modsOut = Join-Path $OutputDir 'Mods'
New-Item -ItemType Directory -Force -Path $modsOut | Out-Null
foreach ($mod in $Mods) {
    $source = Join-Path $buildDir (Join-Path 'Mods' $mod)
    if (-not (Test-Path $source)) { throw "Mod not found: $source. Build it with Build-Mod.ps1 -InstallDir $buildDir\Mods" }
    Copy-Item -LiteralPath $source -Destination (Join-Path $modsOut $mod) -Recurse -Force
    Write-Host ("  Mods\{0}" -f $mod) -ForegroundColor DarkGray
}

# ---- documents --------------------------------------------------------------
Copy-Item -LiteralPath (Join-Path $RepoRoot 'release\README.txt') -Destination (Join-Path $OutputDir 'README.txt') -Force
Copy-Item -LiteralPath (Join-Path $RepoRoot 'LICENSE') -Destination (Join-Path $OutputDir 'LICENSE') -Force

# ---- optional bundled toolchain --------------------------------------------
if (-not [string]::IsNullOrWhiteSpace($ToolchainPath)) {
    $gcc = Join-Path $ToolchainPath 'bin\gcc.exe'
    if (-not (Test-Path $gcc)) { throw "No bin\gcc.exe under $ToolchainPath -- point -ToolchainPath at a MinGW-w64 root." }
    # Prove it runs before shipping it: a toolchain that fails on the recipient's
    # machine turns the first run into an unexplainable failure.
    $probe = Invoke-Native -FilePath $gcc -ArgumentList @('--version') -Quiet
    if (-not $probe.Success) { throw "$gcc did not run: $($probe.Text)" }
    Write-Host ''
    Write-Host ("Bundling toolchain: {0}" -f (($probe.Text -split "`n")[0]).Trim()) -ForegroundColor Cyan
    Copy-Item -LiteralPath $ToolchainPath -Destination (Join-Path $OutputDir 'toolchain') -Recurse -Force
} else {
    Write-Host ''
    Write-Host 'No -ToolchainPath: recipients will need their own MinGW-w64 GCC on PATH.' -ForegroundColor Yellow
}

# ---- runtime DLLs -----------------------------------------------------------
# MinGW builds link against libgcc/libstdc++/libwinpthread, which live in the
# compiler's bin directory -- on a developer's PATH, and on nobody else's. The
# absence of DLLs beside the executables says nothing about what they import,
# which is why this is measured rather than assumed.
$checker = Join-Path $RepoRoot 'tools\check_imports.py'
if (-not (Test-Path $checker)) { throw "check_imports.py not found: $checker" }
if ([string]::IsNullOrWhiteSpace($RuntimeDllDir) -and -not [string]::IsNullOrWhiteSpace($ToolchainPath)) {
    $RuntimeDllDir = Join-Path $ToolchainPath 'bin'
}
# `where.exe gcc` prints the executable, not the folder, and that is the obvious
# thing to paste here. Accept it rather than making the user edit the path.
if (-not [string]::IsNullOrWhiteSpace($RuntimeDllDir)) {
    if (Test-Path -LiteralPath $RuntimeDllDir -PathType Leaf) {
        $RuntimeDllDir = Split-Path -Parent $RuntimeDllDir
        Write-Host ("Using the containing folder: {0}" -f $RuntimeDllDir) -ForegroundColor DarkGray
    }
    if (-not (Test-Path -LiteralPath $RuntimeDllDir -PathType Container)) {
        throw "-RuntimeDllDir is not a directory: $RuntimeDllDir"
    }
}

$missing = @(Invoke-Native -FilePath 'python' -ArgumentList @($checker, $OutputDir, '--list-missing') -Quiet |
             ForEach-Object { $_.Text } | Out-String) -split "`r?`n" | Where-Object { $_.Trim() }
if ($missing.Count -gt 0) {
    Write-Host ''
    Write-Host ("Executables need {0} runtime DLL(s) not in the release:" -f $missing.Count) -ForegroundColor Yellow
    foreach ($dll in $missing) { Write-Host ("  {0}" -f $dll.Trim()) -ForegroundColor Yellow }
    if ([string]::IsNullOrWhiteSpace($RuntimeDllDir)) {
        throw ("The release is not self-contained and would fail on any machine without a compiler installed. " +
               "Pass -RuntimeDllDir pointing at your MinGW bin directory (or -ToolchainPath, which implies it).")
    }
    foreach ($dll in $missing) {
        $name = $dll.Trim()
        $source = Join-Path $RuntimeDllDir $name
        if (-not (Test-Path $source)) { throw "$name is required but not in $RuntimeDllDir" }
        Copy-Item -LiteralPath $source -Destination (Join-Path $OutputDir $name) -Force
        Write-Host ("  copied {0}" -f $name) -ForegroundColor DarkGray
    }
}

# Re-check rather than assume the copies were sufficient: a runtime DLL can
# itself import another one.
$verify = Invoke-Native -FilePath 'python' -ArgumentList @($checker, $OutputDir) -Quiet
if (-not $verify.Success) {
    Write-Host ''
    Write-Host $verify.Text -ForegroundColor Red
    throw 'The release is still not self-contained. It would fail on a machine without a compiler.'
}
Write-Host '  verified: self-contained, every non-system import present' -ForegroundColor Green

# ---- the check that matters -------------------------------------------------
# Recompiled game code must never leave this machine. Scan the finished folder
# rather than trusting the copy list above.
$forbidden = @(Get-ChildItem -Path $OutputDir -Recurse -File -ErrorAction SilentlyContinue |
               Where-Object { $_.Name -like 'g*_recomp.*' -or
                              @('.dol', '.iso', '.rvz', '.wbfs', '.gcm') -contains $_.Extension })
if ($forbidden.Count -gt 0) {
    Write-Host ''
    foreach ($file in $forbidden) { Write-Host ("  {0}" -f $file.FullName) -ForegroundColor Red }
    Remove-Item -LiteralPath $OutputDir -Recurse -Force
    throw "Game-derived files ended up in the release. Output deleted. Nothing above may be distributed."
}

# ---- manifest ---------------------------------------------------------------
$allFiles = @(Get-ChildItem -Path $OutputDir -Recurse -File)
$total = ($allFiles | Measure-Object -Property Length -Sum).Sum
# Hash what a recipient might want to verify. The bundled toolchain is thousands
# of files of somebody else's compiler; hashing it would take minutes and prove
# nothing useful, so it is recorded as one line instead.
$toolchainRoot = Join-Path $OutputDir 'toolchain'
$files = @($allFiles | Where-Object { -not $_.FullName.StartsWith($toolchainRoot, 'OrdinalIgnoreCase') } |
           Sort-Object FullName)
$toolchainFiles = @($allFiles | Where-Object { $_.FullName.StartsWith($toolchainRoot, 'OrdinalIgnoreCase') })
$lines = @(
    "# Bomberman Generation native build",
    "# version: $(if ($Version) { $Version } else { 'unversioned' })",
    "# built:   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
    "# files:   $($allFiles.Count), $([math]::Round($total / 1MB, 1)) MB",
    "# Contains no game code: the module is compiled on the recipient's machine.",
    ""
)
foreach ($file in $files) {
    $relative = $file.FullName.Substring($OutputDir.Length).TrimStart('\')
    $lines += ("{0}  {1}" -f (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLower(), $relative)
}
if ($toolchainFiles.Count -gt 0) {
    $toolchainBytes = ($toolchainFiles | Measure-Object -Property Length -Sum).Sum
    $lines += ""
    $lines += ("# toolchain\: {0} files, {1:N1} MB, not hashed individually" -f $toolchainFiles.Count, ($toolchainBytes / 1MB))
}
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllLines((Join-Path $OutputDir 'manifest.txt'), $lines, $utf8NoBom)

# ---- archive -----------------------------------------------------------------
if (-not [string]::IsNullOrWhiteSpace($ZipPath)) {
    $zipDir = Split-Path -Parent $ZipPath
    if ($zipDir -and -not (Test-Path $zipDir)) { New-Item -ItemType Directory -Force -Path $zipDir | Out-Null }
    if (Test-Path $ZipPath) { Remove-Item -LiteralPath $ZipPath -Force }

    Write-Host ''
    Write-Host 'Compressing...' -ForegroundColor Cyan
    # -Path the folder itself, not its contents: extracting should produce one
    # named folder rather than scattering 8 files into someone's Downloads.
    Compress-Archive -Path $OutputDir -DestinationPath $ZipPath -CompressionLevel Optimal
    if (-not (Test-Path $ZipPath)) { throw "Compress-Archive reported success but $ZipPath does not exist." }

    # The last gate before anything is uploaded. The folder was scanned above,
    # but this is the artefact that actually leaves the machine, so check the
    # thing itself rather than the thing it was made from.
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $bad = @($archive.Entries | Where-Object {
            $leaf = $_.Name
            $ext = [System.IO.Path]::GetExtension($leaf)
            $leaf -like 'g*_recomp.*' -or @('.dol', '.iso', '.rvz', '.wbfs', '.gcm') -contains $ext
        })
    } finally {
        $archive.Dispose()
    }
    if ($bad.Count -gt 0) {
        foreach ($entry in $bad) { Write-Host ("  {0}" -f $entry.FullName) -ForegroundColor Red }
        Remove-Item -LiteralPath $ZipPath -Force
        throw "Game-derived files are inside the archive. Zip deleted. Nothing above may be distributed."
    }

    $zipItem = Get-Item -LiteralPath $ZipPath
    $zipHash = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash.ToLower()
    Write-Host ''
    Write-Host ("Archive: {0}" -f $ZipPath) -ForegroundColor Green
    Write-Host ("  {0:N1} MB" -f ($zipItem.Length / 1MB))
    Write-Host ("  sha256 {0}" -f $zipHash)
    Write-Host '  verified: archive contains no game-derived files' -ForegroundColor Green
}

Write-Host ''
Write-Host ("Release assembled: {0}" -f $OutputDir) -ForegroundColor Green
Write-Host ("  {0} files, {1:N1} MB" -f $allFiles.Count, ($total / 1MB))
Write-Host '  verified: no recompiled module, no disc image, no DOL' -ForegroundColor Green
