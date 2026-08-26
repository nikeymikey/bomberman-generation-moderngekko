# =============================================================================
# Common.ps1 -- shared helpers. Dot-source from every script:
#     . (Join-Path $PSScriptRoot 'Common.ps1')
# =============================================================================

function Invoke-Native {
<#
.SYNOPSIS
    Run a native command, returning its exit code and output, without letting
    stderr masquerade as a fatal error.

.DESCRIPTION
    Windows PowerShell 5.1 converts a native command's stderr writes into a
    terminating NativeCommandError whenever $ErrorActionPreference is 'Stop'.
    Both git and cmake write ordinary, non-fatal output to stderr:

        git rev-parse   on a non-repo  -> "fatal: not a git repository"
        git fetch / clone / submodule add -> progress meters
        git checkout                   -> "Note: switching to ..."
        cmake                          -> assorted diagnostics

    Calling those directly under 'Stop' aborts the script before $LASTEXITCODE
    can be examined -- so a perfectly normal "no, this isn't a repo yet" answer
    reads as a crash. This helper relaxes the preference for the duration of
    the call and judges the command by its exit code, which is the only
    trustworthy signal.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $FilePath,
        [string[]] $ArgumentList = @(),
        [switch] $Quiet
    )

    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $raw  = & $FilePath @ArgumentList 2>&1
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
    }

    # Normalise: merged stderr arrives as ErrorRecord objects, not strings.
    $lines = @($raw | ForEach-Object {
        if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.ToString() } else { "$_" }
    })
    if (-not $Quiet) { foreach ($l in $lines) { Write-Host $l } }
    if ($null -eq $code) { $code = 0 }

    return [pscustomobject]@{
        ExitCode = $code
        Output   = $lines
        Text     = ($lines -join [Environment]::NewLine)
        Success  = ($code -eq 0)
    }
}

function Invoke-NativeChecked {
<#
.SYNOPSIS
    As Invoke-Native, but throws when the command exits non-zero.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $FilePath,
        [string[]] $ArgumentList = @(),
        [string]   $What,
        [switch]   $Quiet
    )
    $r = Invoke-Native -FilePath $FilePath -ArgumentList $ArgumentList -Quiet:$Quiet
    if (-not $r.Success) {
        if ([string]::IsNullOrWhiteSpace($What)) {
            $What = "$FilePath $($ArgumentList -join ' ')"
        }
        throw "$What failed (exit $($r.ExitCode))`n$($r.Text)"
    }
    return $r
}

function Test-GitRepository {
<#
.SYNOPSIS
    Is $Path inside a git work tree? Returns $true/$false, never throws.
#>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $Path)

    if (Test-Path (Join-Path $Path '.git')) { return $true }
    $r = Invoke-Native -FilePath 'git' `
                       -ArgumentList @('-C', $Path, 'rev-parse', '--is-inside-work-tree') `
                       -Quiet
    return $r.Success
}

function Test-PathIgnored {
<#
.SYNOPSIS
    Does git ignore $RelativePath? Returns $true/$false, never throws.
.DESCRIPTION
    Note: `git check-ignore` exits 0 when ANY pattern matches, including a
    negation (!) pattern -- so its exit code alone can report a tracked file as
    ignored. Callers wanting ground truth should also consult `git add -An`.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $RepoRoot,
        [Parameter(Mandatory = $true)][string] $RelativePath
    )
    $r = Invoke-Native -FilePath 'git' `
                       -ArgumentList @('-C', $RepoRoot, 'check-ignore', '-v', '--', $RelativePath) `
                       -Quiet
    return [pscustomobject]@{ Ignored = $r.Success; Rule = $r.Text }
}
