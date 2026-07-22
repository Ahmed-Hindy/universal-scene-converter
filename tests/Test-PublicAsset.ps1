[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $RuntimeZip,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $ManifestPath,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $AssetId,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $WorkRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false

function Assert-OutputFile([string] $Path, [string] $Description) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Description was not created: $Path"
    }

    $fileLength = (Get-Item -LiteralPath $Path).Length
    if ($fileLength -le 16) {
        throw "$Description is unexpectedly small ($fileLength bytes): $Path"
    }
}

function Assert-UsdaFile([string] $Path, [string] $Description) {
    Assert-OutputFile $Path $Description
    $contents = Get-Content -LiteralPath $Path -Raw
    if ($contents -notmatch '(?m)^#usda') {
        throw "$Description is not valid USDA text: $Path"
    }
}

function Get-NativeExitDescription([uint32] $ExitCodeBits) {
    switch ($ExitCodeBits.ToString("X8")) {
        "00000000" { return "success" }
        "80000003" { return "breakpoint" }
        "C0000005" { return "access violation" }
        "C000001D" { return "illegal instruction" }
        "C0000094" { return "integer divide by zero" }
        "C00000FD" { return "stack overflow" }
        "C0000135" { return "missing dependency" }
        "C0000374" { return "heap corruption" }
        "C0000409" { return "stack buffer overrun or fast-fail" }
        default { return "process failure" }
    }
}

$runtimeRoot = Join-Path $WorkRoot "runtime"
$assetRoot = Join-Path $WorkRoot "asset"
$outputsRoot = Join-Path $WorkRoot "outputs"
$artifactsRoot = Join-Path $WorkRoot "usd-artifacts"
$logsRoot = Join-Path $WorkRoot "logs"

function Invoke-UsdConvert([string] $Name, [string[]] $Arguments) {
    $logPath = Join-Path $logsRoot "$Name.log"
    $output = & $script:converter @Arguments 2>&1
    $exitCode = [int32]$LASTEXITCODE
    $output | Tee-Object -FilePath $logPath

    $exitCodeBits = [System.BitConverter]::ToUInt32(
        [System.BitConverter]::GetBytes($exitCode),
        0
    )
    $exitCodeHex = "0x$($exitCodeBits.ToString('X8'))"
    $exitDescription = Get-NativeExitDescription $exitCodeBits
    Write-Host "$Name exit code: $exitCode ($exitCodeHex, $exitDescription)"

    if ($exitCode -ne 0) {
        throw "$Name failed with exit code $exitCode ($exitCodeHex, $exitDescription)."
    }
}

foreach ($requiredPath in @($RuntimeZip, $ManifestPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Required file was not found: $requiredPath"
    }
}

Remove-Item -LiteralPath $WorkRoot -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force `
    $runtimeRoot, $assetRoot, $outputsRoot, $artifactsRoot, $logsRoot | Out-Null

$manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
if ($manifest.schema_version -ne 1) {
    throw "Unsupported public asset manifest schema version: $($manifest.schema_version)"
}

$matchingAssets = @($manifest.assets | Where-Object { $_.id -eq $AssetId })
if ($matchingAssets.Count -ne 1) {
    throw "Expected one manifest entry for '$AssetId', found $($matchingAssets.Count)."
}
$asset = $matchingAssets[0]

Expand-Archive -LiteralPath $RuntimeZip -DestinationPath $runtimeRoot -Force

$assetFiles = @($asset.files)
if ($assetFiles.Count -eq 0) {
    throw "The manifest entry '$AssetId' contains no files."
}

foreach ($assetFile in $assetFiles) {
    if ($assetFile.url -notmatch [regex]::Escape([string]$asset.source_revision)) {
        throw "Asset URL is not pinned to revision $($asset.source_revision): $($assetFile.url)"
    }
    if ($assetFile.sha256 -notmatch '^[0-9a-f]{64}$') {
        throw "Invalid SHA-256 value for $($assetFile.path)."
    }

    $destinationPath = Join-Path $assetRoot ([string]$assetFile.path)
    $destinationDirectory = Split-Path -Parent $destinationPath
    New-Item -ItemType Directory -Force $destinationDirectory | Out-Null

    Write-Host "Downloading $($assetFile.url)"
    Invoke-WebRequest -Uri $assetFile.url -OutFile $destinationPath `
        -MaximumRetryCount 3 -RetryIntervalSec 2

    $actualHash = (Get-FileHash -LiteralPath $destinationPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $assetFile.sha256) {
        throw "SHA-256 mismatch for $($assetFile.path). Expected $($assetFile.sha256), got $actualHash."
    }
}

$inputPath = Join-Path $assetRoot ([string]$asset.input)
if (-not (Test-Path -LiteralPath $inputPath -PathType Leaf)) {
    throw "The matrix input file was not downloaded: $inputPath"
}

$script:converter = Join-Path $runtimeRoot "bin/usdconvert.exe"
if (-not (Test-Path -LiteralPath $script:converter -PathType Leaf)) {
    throw "usdconvert.exe is missing from the portable runtime."
}

$env:PATH = "$env:SystemRoot\System32;$env:SystemRoot"
Remove-Item Env:PXR_PLUGINPATH_NAME -ErrorAction SilentlyContinue
Remove-Item Env:TF_DEBUG -ErrorAction SilentlyContinue

$canonicalUsd = Join-Path $artifactsRoot "$AssetId-import.usda"
$canonicalUsdc = Join-Path $artifactsRoot "$AssetId-import.usdc"
$roundTripAsset = Join-Path $outputsRoot "roundtrip.$($asset.roundtrip_extension)"
$verifiedUsd = Join-Path $artifactsRoot "$AssetId-roundtrip.usda"
$verifiedUsdc = Join-Path $artifactsRoot "$AssetId-roundtrip.usdc"
$canonicalUsdcCheck = Join-Path $outputsRoot "canonical-usdc-check.usda"
$verifiedUsdcCheck = Join-Path $outputsRoot "verified-usdc-check.usda"

Invoke-UsdConvert "import" @($inputPath, "-o", $canonicalUsd)
Assert-UsdaFile $canonicalUsd "Canonical USDA"

$expectedCountProperty = $asset.PSObject.Properties["expected_usda_minimum_counts"]
$expectedCountAssertions = @()
if ($null -ne $expectedCountProperty) {
    $expectedCountAssertions = @($expectedCountProperty.Value)
    $canonicalUsdText = Get-Content -LiteralPath $canonicalUsd -Raw
    foreach ($expectation in $expectedCountAssertions) {
        $expectedText = [string]$expectation.text
        $minimumCount = [int]$expectation.count
        if ([string]::IsNullOrEmpty($expectedText) -or $minimumCount -lt 1) {
            throw "Invalid expected_usda_minimum_counts entry for '$AssetId'."
        }

        $actualCount = [regex]::Matches(
            $canonicalUsdText,
            [regex]::Escape($expectedText)
        ).Count
        if ($actualCount -lt $minimumCount) {
            throw "Canonical USDA contains '$expectedText' $actualCount times; expected at least $minimumCount."
        }
        Write-Host "Verified '$expectedText' count: $actualCount >= $minimumCount"
    }
}

Invoke-UsdConvert "canonical-usdc" @($canonicalUsd, "-o", $canonicalUsdc)
Assert-OutputFile $canonicalUsdc "Canonical USDC"
Invoke-UsdConvert "canonical-usdc-check" @($canonicalUsdc, "-o", $canonicalUsdcCheck)
Assert-UsdaFile $canonicalUsdcCheck "Canonical USDC verification"

Invoke-UsdConvert "export" @($canonicalUsd, "-o", $roundTripAsset)
Assert-OutputFile $roundTripAsset "Round-trip $($asset.format) asset"

Invoke-UsdConvert "reimport" @($roundTripAsset, "-o", $verifiedUsd)
Assert-UsdaFile $verifiedUsd "Verified USDA"

Invoke-UsdConvert "verified-usdc" @($verifiedUsd, "-o", $verifiedUsdc)
Assert-OutputFile $verifiedUsdc "Verified USDC"
Invoke-UsdConvert "verified-usdc-check" @($verifiedUsdc, "-o", $verifiedUsdcCheck)
Assert-UsdaFile $verifiedUsdcCheck "Verified USDC verification"

foreach ($assetFile in $assetFiles) {
    $sourcePath = Join-Path $assetRoot ([string]$assetFile.path)
    if ($sourcePath -eq $inputPath) {
        continue
    }

    $sidecarDestination = Join-Path $artifactsRoot ([string]$assetFile.path)
    $sidecarDirectory = Split-Path -Parent $sidecarDestination
    New-Item -ItemType Directory -Force $sidecarDirectory | Out-Null
    Copy-Item -LiteralPath $sourcePath -Destination $sidecarDestination -Force
}

$sourceInfo = @"
Universal Scene Converter public asset conversion artifact

Asset ID: $($asset.id)
Format: $($asset.format)
Source repository: $($asset.source_repository)
Source revision: $($asset.source_revision)
License: $($asset.license)
License URL: $($asset.license_url)

The USDA and USDC files were generated by Universal Scene Converter from the pinned public source asset.
Additional files are source sidecars required by the converted USD asset.
"@
Set-Content -LiteralPath (Join-Path $artifactsRoot "SOURCE-ATTRIBUTION.txt") `
    -Value $sourceInfo.Trim() -Encoding utf8

$artifactFiles = Get-ChildItem -LiteralPath $artifactsRoot -File -Recurse |
    Sort-Object FullName
$artifactManifest = [ordered]@{
    schema_version = 1
    asset_id = [string]$asset.id
    format = [string]$asset.format
    source_repository = [string]$asset.source_repository
    source_revision = [string]$asset.source_revision
    license = [string]$asset.license
    license_url = [string]$asset.license_url
    converter_version = (& $script:converter --version 2>&1 | Out-String).Trim()
    files = @(
        $artifactFiles | ForEach-Object {
            [ordered]@{
                path = [System.IO.Path]::GetRelativePath($artifactsRoot, $_.FullName).Replace('\', '/')
                size = $_.Length
                sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        }
    )
}
$artifactManifestPath = Join-Path $artifactsRoot "ARTIFACT-INFO.json"
$artifactManifest | ConvertTo-Json -Depth 6 |
    Set-Content -LiteralPath $artifactManifestPath -Encoding utf8

if ($env:GITHUB_STEP_SUMMARY) {
    @"
### Public asset: ``$($asset.id)``

| Field | Value |
|---|---|
| Format | ``$($asset.format)`` |
| Repository | ``$($asset.source_repository)`` |
| Revision | ``$($asset.source_revision)`` |
| License | ``$($asset.license)`` |
| Downloaded files | $($assetFiles.Count) |
| Published USD files | 4 |
| USDA feature assertions | $($expectedCountAssertions.Count) |
| Import | Passed |
| USDC encoding | Passed |
| Export | Passed |
| Re-import | Passed |
"@ | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Append
}
