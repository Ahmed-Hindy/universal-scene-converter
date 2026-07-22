. "$PSScriptRoot/Common.ps1"

$workRoot = Get-WorkRoot
$openUsdSource = Join-Path $workRoot "OpenUSD"
$adobeSource = Join-Path $workRoot "USD-Fileformat-plugins"
New-Item -ItemType Directory -Force $workRoot | Out-Null

foreach ($sourceDirectory in @($openUsdSource, $adobeSource)) {
    Remove-Item -LiteralPath $sourceDirectory -Recurse -Force -ErrorAction SilentlyContinue
}

git clone --filter=blob:none --depth 1 --branch $env:OPENUSD_REF `
    https://github.com/PixarAnimationStudios/OpenUSD.git $openUsdSource
if ($LASTEXITCODE -ne 0) { throw "OpenUSD clone failed." }

git clone --filter=blob:none --depth 1 --branch $env:ADOBE_REF `
    https://github.com/adobe/USD-Fileformat-plugins.git $adobeSource
if ($LASTEXITCODE -ne 0) { throw "Adobe plugin clone failed." }

$openUsdGitBytes = Get-DirectoryBytes (Join-Path $openUsdSource ".git")
$adobeGitBytes = Get-DirectoryBytes (Join-Path $adobeSource ".git")
$openUsdTreeBytes = Get-DirectoryBytes $openUsdSource
$adobeTreeBytes = Get-DirectoryBytes $adobeSource

Write-Host "OpenUSD Git transfer footprint: $(Format-Bytes $openUsdGitBytes)"
Write-Host "Adobe Git transfer footprint:  $(Format-Bytes $adobeGitBytes)"
Write-Host "OpenUSD checkout on disk:      $(Format-Bytes $openUsdTreeBytes)"
Write-Host "Adobe checkout on disk:       $(Format-Bytes $adobeTreeBytes)"
Write-Host "Note: Git object-store size is a transfer-footprint estimate, not exact wire bytes."

Add-StepSummary @"
### Source checkout sizes

| Item | Size |
|---|---:|
| OpenUSD Git object store | $(Format-Bytes $openUsdGitBytes) |
| Adobe Git object store | $(Format-Bytes $adobeGitBytes) |
| OpenUSD checkout | $(Format-Bytes $openUsdTreeBytes) |
| Adobe checkout | $(Format-Bytes $adobeTreeBytes) |

Git object-store size is an estimate of clone transfer footprint, not exact network wire bytes.
"@
