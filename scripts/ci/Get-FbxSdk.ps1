. "$PSScriptRoot/Common.ps1"

$workRoot = Get-WorkRoot
$downloadRoot = Join-Path $workRoot "fbx-sdk-download"
$extractRoot = Join-Path $workRoot "fbx-sdk"
$installerName = "fbx202039_fbxsdk_vs2022_win.exe"
$installerPath = Join-Path $downloadRoot $installerName
$sdkUrl = "https://damassets.autodesk.net/content/dam/autodesk/www/files/$installerName"
$expectedSha256 = "b1db4330d327c8983c237d8fea605fd9447e28e9d0d6e08139d87d6a86c1c987"

Remove-Item -LiteralPath $downloadRoot, $extractRoot -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $downloadRoot, $extractRoot | Out-Null

Write-Host "Downloading Autodesk FBX SDK $env:FBX_SDK_VERSION from $sdkUrl"
Invoke-WebRequest -Uri $sdkUrl -OutFile $installerPath -MaximumRetryCount 3 -RetryIntervalSec 3

$signature = Get-AuthenticodeSignature -FilePath $installerPath
if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
    throw "The Autodesk FBX SDK installer signature is not valid: $($signature.StatusMessage)"
}
if ($signature.SignerCertificate.Subject -notmatch 'Autodesk') {
    throw "The FBX SDK installer is not signed by Autodesk: $($signature.SignerCertificate.Subject)"
}

$actualSha256 = (Get-FileHash -LiteralPath $installerPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($expectedSha256 -and $actualSha256 -ne $expectedSha256) {
    throw "The FBX SDK installer SHA-256 does not match. Expected $expectedSha256, got $actualSha256."
}
Write-Host "FBX SDK installer SHA-256: $actualSha256"
Write-Host "FBX SDK installer signer: $($signature.SignerCertificate.Subject)"

$sevenZip = Get-Command 7z -ErrorAction Stop
& $sevenZip.Source x $installerPath "-o$extractRoot" -y -bso0 -bsp0
if ($LASTEXITCODE -ne 0) {
    throw "Failed to extract the Autodesk FBX SDK installer."
}

$header = Get-ChildItem -LiteralPath $extractRoot -Filter "fbxsdk.h" -File -Recurse |
    Where-Object { $_.Directory.Name -eq "include" } |
    Select-Object -First 1
if (-not $header) {
    throw "fbxsdk.h was not found in the extracted Autodesk FBX SDK."
}

$sdkRoot = $header.Directory.Parent.FullName
if (-not (Test-Path -LiteralPath (Join-Path $sdkRoot "lib") -PathType Container)) {
    throw "The extracted Autodesk FBX SDK does not contain a lib directory: $sdkRoot"
}

"FBXSDK_ROOT=$sdkRoot" | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append
Write-Host "FBX SDK root: $sdkRoot"

$licenseDestination = Join-Path $workRoot "usd-install/licenses/Autodesk-FBX-SDK"
New-Item -ItemType Directory -Force $licenseDestination | Out-Null
Copy-Item -LiteralPath (Join-Path $env:GITHUB_WORKSPACE "licenses/Autodesk-FBX-SDK-NOTICE.txt") `
    -Destination $licenseDestination -Force

$licenseExtensions = @(".txt", ".rtf", ".html", ".htm", ".md", ".pdf")
$licenseCandidates = Get-ChildItem -LiteralPath $extractRoot -File -Recurse -ErrorAction SilentlyContinue |
    Where-Object {
        $_.Name -match '(?i)(license|eula|copyright|third.?party)' -and
        $_.Extension -in $licenseExtensions -and
        $_.Length -lt 2MB
    }
if (-not $licenseCandidates) {
    throw "No Autodesk FBX SDK license or notice documents were found in $extractRoot."
}

$seenHashes = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$copiedLicenseCount = 0
foreach ($licenseFile in $licenseCandidates) {
    $licenseHash = (Get-FileHash -LiteralPath $licenseFile.FullName -Algorithm SHA256).Hash
    if (-not $seenHashes.Add($licenseHash)) {
        continue
    }

    $copiedLicenseCount++
    $destinationName = "SDK-{0:D2}-{1}" -f $copiedLicenseCount, $licenseFile.Name
    Copy-Item -LiteralPath $licenseFile.FullName `
        -Destination (Join-Path $licenseDestination $destinationName) -Force
}

Write-Host "Captured Autodesk license documents: $copiedLicenseCount"

Add-StepSummary @"
### Autodesk FBX SDK

| Item | Value |
|---|---|
| Version | $env:FBX_SDK_VERSION |
| Installer | `$installerName` |
| SHA-256 | `$actualSha256` |
| Signer | `$($signature.SignerCertificate.Subject)` |
| Captured license files | $copiedLicenseCount |
"@
