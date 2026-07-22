. "$PSScriptRoot/Common.ps1"

$workRoot = Get-WorkRoot
$usdInstall = Join-Path $workRoot "usd-install"
$usdRootCmake = $usdInstall.Replace('\', '/')
$cliBuild = Join-Path $workRoot "usdconvert-build"
$usdHeader = Join-Path $usdInstall "include/pxr/pxr.h"

if (-not (Test-Path -LiteralPath $usdHeader -PathType Leaf)) {
    Write-Host "OpenUSD installation contents:"
    Get-ChildItem -LiteralPath $usdInstall -Force -ErrorAction SilentlyContinue |
        Format-Table -AutoSize
    throw "The cached OpenUSD installation does not contain $usdHeader."
}

Write-Host "OpenUSD header: $usdHeader"
Write-Host "OpenUSD import libraries:"
Get-ChildItem -LiteralPath (Join-Path $usdInstall "lib") -Filter "usd_*.lib" -File |
    Select-Object Name, Length |
    Format-Table -AutoSize

Remove-Item -LiteralPath $cliBuild -Recurse -Force -ErrorAction SilentlyContinue
cmake `
    -S $env:GITHUB_WORKSPACE `
    -B $cliBuild `
    -G "Visual Studio 17 2022" `
    -A x64 `
    -DUSD_ROOT:PATH=$usdRootCmake
if ($LASTEXITCODE -ne 0) { throw "usdconvert configuration failed." }

cmake --build $cliBuild --config Release --parallel $env:BUILD_JOBS
if ($LASTEXITCODE -ne 0) { throw "usdconvert build failed." }

$env:PATH = "$(Join-Path $usdInstall 'lib');$(Join-Path $usdInstall 'bin');$env:PATH"
ctest --test-dir $cliBuild -C Release --output-on-failure
if ($LASTEXITCODE -ne 0) { throw "converter_core native tests failed." }

cmake --install $cliBuild --config Release --prefix $usdInstall
if ($LASTEXITCODE -ne 0) { throw "usdconvert installation failed." }

& (Join-Path $usdInstall "bin/usdconvert.exe") --version
if ($LASTEXITCODE -ne 0) { throw "usdconvert version check failed." }
