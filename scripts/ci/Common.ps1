Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-DirectoryBytes {
    param([Parameter(Mandatory)][string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return [int64]0
    }

    $measurement = Get-ChildItem -LiteralPath $Path -File -Recurse -Force -ErrorAction SilentlyContinue |
        Measure-Object -Property Length -Sum
    return [int64]($measurement.Sum ?? 0)
}

function Format-Bytes {
    param([Parameter(Mandatory)][int64] $Bytes)

    if ($Bytes -ge 1GB) { return "{0:N2} GiB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N2} MiB" -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return "{0:N2} KiB" -f ($Bytes / 1KB) }
    return "$Bytes B"
}

function Add-StepSummary {
    param([Parameter(Mandatory)][string] $Content)

    if ($env:GITHUB_STEP_SUMMARY) {
        $Content | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Append
    } else {
        Write-Host $Content
    }
}

function Get-WorkRoot {
    if (-not $env:GITHUB_WORKSPACE) {
        throw "GITHUB_WORKSPACE is not set."
    }
    return Join-Path $env:GITHUB_WORKSPACE "work"
}
