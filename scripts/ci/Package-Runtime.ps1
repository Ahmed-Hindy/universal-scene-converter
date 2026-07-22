. "$PSScriptRoot/Common.ps1"

function Get-PeDependencies {
    param([Parameter(Mandatory)][string] $Path)

    $dumpOutput = & dumpbin /NOLOGO /DEPENDENTS $Path 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "dumpbin failed while inspecting $Path."
    }

    $dependencies = @()
    foreach ($line in $dumpOutput) {
        if ($line -match '^\s+([^\s]+\.dll)\s*$') {
            $dependencies += $Matches[1]
        }
    }
    return $dependencies
}

$workRoot = Get-WorkRoot
$usdInstall = Join-Path $workRoot "usd-install"
$distRoot = Join-Path $workRoot "dist"
$portableRoot = Join-Path $distRoot "universal-scene-converter-windows-x64"
$zipPath = Join-Path $distRoot "universal-scene-converter-windows-x64.zip"

if (-not (Test-Path (Join-Path $usdInstall "bin/usdconvert.exe"))) {
    throw "usdconvert.exe was not found in the runtime."
}

Remove-Item -LiteralPath $distRoot -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $portableRoot | Out-Null

Copy-Item (Join-Path $usdInstall "bin") $portableRoot -Recurse -Force
$portableBin = Join-Path $portableRoot "bin"
$runtimeLibraries = Get-ChildItem -LiteralPath (Join-Path $usdInstall "lib") `
    -Filter "*.dll" -File -Recurse -ErrorAction SilentlyContinue
if (-not $runtimeLibraries) {
    throw "No runtime DLLs were found under the OpenUSD lib directory."
}
foreach ($runtimeLibrary in $runtimeLibraries) {
    Copy-Item -LiteralPath $runtimeLibrary.FullName -Destination $portableBin -Force
}
Write-Host "Copied $($runtimeLibraries.Count) runtime DLLs from lib to bin."

$corePluginRegistry = Join-Path $usdInstall "lib/usd"
if (-not (Test-Path -LiteralPath (Join-Path $corePluginRegistry "plugInfo.json"))) {
    throw "OpenUSD core plugin registry was not found under $corePluginRegistry."
}
Copy-Item -LiteralPath $corePluginRegistry -Destination $portableBin -Recurse -Force
Write-Host "Copied OpenUSD core plugin registry to portable bin/usd."

Copy-Item (Join-Path $usdInstall "plugin") $portableRoot -Recurse -Force
if (Test-Path (Join-Path $usdInstall "licenses")) {
    Copy-Item (Join-Path $usdInstall "licenses") $portableRoot -Recurse -Force
}

$projectLicense = Join-Path $env:GITHUB_WORKSPACE "LICENSE"
if (-not (Test-Path -LiteralPath $projectLicense -PathType Leaf)) {
    throw "The Universal Scene Converter project license is missing: $projectLicense"
}
$portableLicenseRoot = Join-Path $portableRoot "licenses"
New-Item -ItemType Directory -Force $portableLicenseRoot | Out-Null
Copy-Item -LiteralPath $projectLicense `
    -Destination (Join-Path $portableLicenseRoot "Universal-Scene-Converter-LICENSE.txt") -Force

$readme = Join-Path $env:GITHUB_WORKSPACE "README.md"
$developmentGuide = Join-Path $env:GITHUB_WORKSPACE "DEVELOPMENT.md"
$integrationGuide = Join-Path $env:GITHUB_WORKSPACE "JSON_OUTPUT.md"
$resultSchema = Join-Path $env:GITHUB_WORKSPACE "schemas/usdconvert-result.schema.json"
if (-not (Test-Path -LiteralPath $readme -PathType Leaf) -or
    -not (Test-Path -LiteralPath $developmentGuide -PathType Leaf) -or
    -not (Test-Path -LiteralPath $integrationGuide -PathType Leaf) -or
    -not (Test-Path -LiteralPath $resultSchema -PathType Leaf)) {
    throw "The packaged documentation or result schema is missing."
}
Copy-Item -LiteralPath $projectLicense -Destination (Join-Path $portableRoot "LICENSE") -Force
Copy-Item -LiteralPath $readme -Destination $portableRoot -Force
Copy-Item -LiteralPath $developmentGuide -Destination $portableRoot -Force
Copy-Item -LiteralPath $integrationGuide -Destination $portableRoot -Force
$portableSchemaRoot = Join-Path $portableRoot "schemas"
New-Item -ItemType Directory -Force $portableSchemaRoot | Out-Null
Copy-Item -LiteralPath $resultSchema -Destination $portableSchemaRoot -Force

$portableBeforePruneBytes = Get-DirectoryBytes $portableRoot
$pluginRoot = Join-Path $portableRoot "plugin/usd"
$pluginNamesToKeep = @(
    "hioOiio",
    "hioOpenEXR",
    "usdFbx",
    "usdGltf",
    "usdObj",
    "usdShaders",
    "usdStl"
)
$pluginDllNamesToKeep = @($pluginNamesToKeep | ForEach-Object { "$_.dll" })

Get-ChildItem -LiteralPath $pluginRoot -Directory | Where-Object {
    $_.Name -notin $pluginNamesToKeep
} | Remove-Item -Recurse -Force

Get-ChildItem -LiteralPath $pluginRoot -File | Where-Object {
    $_.Extension -eq ".dll" -and $_.Name -notin $pluginDllNamesToKeep
} | Remove-Item -Force

Get-ChildItem -LiteralPath $portableBin -File -Filter "*.exe" | Where-Object {
    $_.Name -ne "usdconvert.exe"
} | Remove-Item -Force

Get-ChildItem -LiteralPath $portableRoot -File -Recurse | Where-Object {
    $_.Extension -in ".lib", ".exp", ".pdb"
} | Remove-Item -Force

$candidateDlls = @(Get-ChildItem -LiteralPath $portableRoot -File -Recurse -Filter "*.dll")
$candidateDllsByName = @{}
foreach ($candidateDll in $candidateDlls) {
    $candidateKey = $candidateDll.Name.ToLowerInvariant()
    if (-not $candidateDllsByName.ContainsKey($candidateKey)) {
        $candidateDllsByName[$candidateKey] = @()
    }
    $candidateDllsByName[$candidateKey] += $candidateDll
}

$rootPaths = @(
    (Join-Path $portableBin "usdconvert.exe"),
    (Join-Path $portableBin "fileformatUtils.dll"),
    (Join-Path $pluginRoot "usdFbx.dll"),
    (Join-Path $pluginRoot "usdObj.dll"),
    (Join-Path $pluginRoot "usdStl.dll"),
    (Join-Path $pluginRoot "usdGltf.dll"),
    (Join-Path $pluginRoot "hioOiio.dll"),
    (Join-Path $pluginRoot "hioOpenEXR.dll")
)
foreach ($rootPath in $rootPaths) {
    if (-not (Test-Path -LiteralPath $rootPath -PathType Leaf)) {
        throw "Required portable runtime root was not found: $rootPath"
    }
}

$requiredDllNames = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)
$inspectedPaths = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)
$inspectionQueue = [System.Collections.Generic.Queue[System.IO.FileInfo]]::new()

foreach ($rootPath in $rootPaths) {
    $rootFile = Get-Item -LiteralPath $rootPath
    if ($rootFile.Extension -eq ".dll") {
        [void]$requiredDllNames.Add($rootFile.Name)
    }
    $inspectionQueue.Enqueue($rootFile)
}

while ($inspectionQueue.Count -gt 0) {
    $currentFile = $inspectionQueue.Dequeue()
    if (-not $inspectedPaths.Add($currentFile.FullName)) {
        continue
    }

    foreach ($dependencyName in (Get-PeDependencies $currentFile.FullName)) {
        $dependencyKey = $dependencyName.ToLowerInvariant()
        if (-not $candidateDllsByName.ContainsKey($dependencyKey)) {
            continue
        }

        [void]$requiredDllNames.Add($dependencyName)
        foreach ($dependencyFile in $candidateDllsByName[$dependencyKey]) {
            $inspectionQueue.Enqueue($dependencyFile)
        }
    }
}

$removedDllCount = 0
[int64]$removedDllBytes = 0
foreach ($candidateDll in $candidateDlls) {
    if ($requiredDllNames.Contains($candidateDll.Name)) {
        continue
    }
    $removedDllBytes += $candidateDll.Length
    $removedDllCount++
    Remove-Item -LiteralPath $candidateDll.FullName -Force
}

$removedRegistryCount = 0
[int64]$removedRegistryBytes = 0
$portableCoreRegistry = Join-Path $portableBin "usd"
foreach ($registryDirectory in (Get-ChildItem -LiteralPath $portableCoreRegistry -Directory)) {
    $registryInfo = Join-Path $registryDirectory.FullName "resources/plugInfo.json"
    if (-not (Test-Path -LiteralPath $registryInfo -PathType Leaf)) {
        continue
    }

    $registryContent = Get-Content -LiteralPath $registryInfo -Raw
    $libraryMatches = [regex]::Matches(
        $registryContent,
        '"LibraryPath"\s*:\s*"([^"]+\.dll)"'
    )
    if ($libraryMatches.Count -eq 0) {
        continue
    }

    $registryIsRequired = $false
    foreach ($libraryMatch in $libraryMatches) {
        $libraryPath = $libraryMatch.Groups[1].Value.Replace('/', '\')
        $libraryName = [System.IO.Path]::GetFileName($libraryPath)
        if ($requiredDllNames.Contains($libraryName)) {
            $registryIsRequired = $true
            break
        }
    }
    if ($registryIsRequired) {
        continue
    }

    $removedRegistryBytes += Get-DirectoryBytes $registryDirectory.FullName
    $removedRegistryCount++
    Remove-Item -LiteralPath $registryDirectory.FullName -Recurse -Force
}

$portableAfterPruneBytes = Get-DirectoryBytes $portableRoot
Write-Host "Portable runtime before pruning: $(Format-Bytes $portableBeforePruneBytes)"
Write-Host "Portable runtime after pruning:  $(Format-Bytes $portableAfterPruneBytes)"
Write-Host "Required DLL names:               $($requiredDllNames.Count)"
Write-Host "Removed DLLs:                     $removedDllCount ($(Format-Bytes $removedDllBytes))"
Write-Host "Removed core registry trees:      $removedRegistryCount ($(Format-Bytes $removedRegistryBytes))"

$buildInfo = @"
Universal Scene Converter portable runtime
OpenUSD: $env:OPENUSD_REF
Adobe USD Fileformat Plugins: $env:ADOBE_REF
Platform: Windows x64
"@
Set-Content -LiteralPath (Join-Path $portableRoot "BUILD-INFO.txt") `
    -Value $buildInfo.Trim() -Encoding utf8

Compress-Archive -Path (Join-Path $portableRoot "*") -DestinationPath $zipPath -CompressionLevel Optimal

$portableBytes = Get-DirectoryBytes $portableRoot
$zipBytes = (Get-Item -LiteralPath $zipPath).Length

Write-Host "Portable runtime: $(Format-Bytes $portableBytes)"
Write-Host "ZIP artifact:     $(Format-Bytes $zipBytes)"
Write-Host "Largest runtime files:"
Get-ChildItem -LiteralPath $portableRoot -File -Recurse |
    Sort-Object Length -Descending |
    Select-Object -First 20 @{Name="Size"; Expression={ Format-Bytes $_.Length }}, FullName |
    Format-Table -AutoSize

Add-StepSummary @"
### Final artifact sizes

| Item | Size |
|---|---:|
| Runtime before pruning | $(Format-Bytes $portableBeforePruneBytes) |
| Runtime after pruning | $(Format-Bytes $portableBytes) |
| Removed DLLs | $removedDllCount ($(Format-Bytes $removedDllBytes)) |
| Removed core registries | $removedRegistryCount ($(Format-Bytes $removedRegistryBytes)) |
| Required DLL names | $($requiredDllNames.Count) |
| ZIP artifact | $(Format-Bytes $zipBytes) |
"@
