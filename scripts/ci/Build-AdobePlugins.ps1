. "$PSScriptRoot/Common.ps1"

$workRoot = Get-WorkRoot
$openUsdSource = Join-Path $workRoot "OpenUSD"
$adobeSource = Join-Path $workRoot "USD-Fileformat-plugins"
$adobeBuild = Join-Path $workRoot "adobe-build"
$usdInstall = Join-Path $workRoot "usd-install"
$fbxSdkRoot = $env:FBXSDK_ROOT

if (-not $fbxSdkRoot -or -not (Test-Path -LiteralPath (Join-Path $fbxSdkRoot "include/fbxsdk.h") -PathType Leaf)) {
    throw "FBXSDK_ROOT does not point to an extracted Autodesk FBX SDK."
}

Remove-Item -LiteralPath $adobeBuild -Recurse -Force -ErrorAction SilentlyContinue

$configureArguments = @(
    "-S", $adobeSource,
    "-B", $adobeBuild,
    "-G", "Visual Studio 17 2022",
    "-A", "x64",
    "-DCMAKE_BUILD_TYPE=Release",
    "-DCMAKE_INSTALL_PREFIX=$usdInstall",
    "-DCMAKE_PREFIX_PATH=$usdInstall",
    "-Dpxr_ROOT=$usdInstall",
    "-DUSD_FILEFORMATS_STANDALONE=ON",
    "-DUSD_FILEFORMATS_BUILD_TESTS=OFF",
    "-DUSD_FILEFORMATS_ENABLE_FBX=ON",
    "-DFBXSDK_ROOT=$fbxSdkRoot",
    "-DUSD_FILEFORMATS_ENABLE_GLTF=ON",
    "-DUSD_FILEFORMATS_ENABLE_OBJ=ON",
    "-DUSD_FILEFORMATS_ENABLE_PLY=OFF",
    "-DUSD_FILEFORMATS_ENABLE_SPZ=OFF",
    "-DUSD_FILEFORMATS_ENABLE_STL=ON",
    "-DUSD_FILEFORMATS_ENABLE_SBSAR=OFF",
    "-DUSD_FILEFORMATS_ENABLE_DRACO=OFF",
    "-DUSD_FILEFORMATS_FETCH_TINYGLTF=ON",
    "-DUSD_FILEFORMATS_FETCH_ZLIB=OFF",
    "-DUSD_FILEFORMATS_FETCH_LIBXML2=ON",
    "-DUSD_FILEFORMATS_FETCH_FMT=ON",
    "-DUSD_FILEFORMATS_FETCH_FASTFLOAT=ON",
    "-DUSD_FILEFORMATS_ENABLE_MTLX=OFF",
    "-DUSD_FILEFORMATS_ENABLE_ASM=OFF"
)

cmake @configureArguments
if ($LASTEXITCODE -ne 0) { throw "Adobe plugin configuration failed." }

cmake --build $adobeBuild --config Release --parallel $env:BUILD_JOBS
if ($LASTEXITCODE -ne 0) { throw "Adobe plugin build failed." }

cmake --install $adobeBuild --config Release
if ($LASTEXITCODE -ne 0) { throw "Adobe plugin installation failed." }

$licenseDirectory = Join-Path $usdInstall "licenses"
New-Item -ItemType Directory -Force $licenseDirectory | Out-Null
Copy-Item (Join-Path $openUsdSource "LICENSE.txt") `
    (Join-Path $licenseDirectory "OpenUSD-LICENSE.txt") -Force
Copy-Item (Join-Path $adobeSource "LICENSE-2.0.txt") `
    (Join-Path $licenseDirectory "Adobe-USD-Fileformat-plugins-LICENSE.txt") -Force

$fetchContentBytes = Get-DirectoryBytes (Join-Path $adobeBuild "_deps")
$adobeBuildBytes = Get-DirectoryBytes $adobeBuild
$combinedInstallBytes = Get-DirectoryBytes $usdInstall

Write-Host "Adobe FetchContent footprint: $(Format-Bytes $fetchContentBytes)"
Write-Host "Adobe build footprint:        $(Format-Bytes $adobeBuildBytes)"
Write-Host "Combined install footprint:   $(Format-Bytes $combinedInstallBytes)"

Add-StepSummary @"
### Adobe plugin build sizes

| Item | Size |
|---|---:|
| FetchContent dependencies | $(Format-Bytes $fetchContentBytes) |
| Adobe compiler build directory | $(Format-Bytes $adobeBuildBytes) |
| Combined OpenUSD + plugin installation | $(Format-Bytes $combinedInstallBytes) |
"@
