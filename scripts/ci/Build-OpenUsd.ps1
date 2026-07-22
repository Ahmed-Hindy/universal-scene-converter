. "$PSScriptRoot/Common.ps1"

$workRoot = Get-WorkRoot
$openUsdSource = Join-Path $workRoot "OpenUSD"
$usdInstall = Join-Path $workRoot "usd-install"
$dependencySource = Join-Path $workRoot "usd-dependency-source"
$buildRoot = Join-Path $workRoot "usd-build"

$arguments = @(
    (Join-Path $openUsdSource "build_scripts/build_usd.py"),
    $usdInstall,
    "--build-shared",
    "--no-python",
    "--imaging",
    "--openimageio",
    "--no-usdview",
    "--no-examples",
    "--no-tutorials",
    "--tools",
    "--no-tests",
    "--no-docs",
    "--no-python-docs",
    "--no-materialx",
    "--no-usdValidation",
    "--no-ptex",
    "--no-openvdb",
    "--no-vulkan",
    "--no-embree",
    "--no-prman",
    "--no-opencolorio",
    "--no-alembic",
    "--no-draco",
    "--onetbb",
    "--build-variant", "release",
    "--generator", "Visual Studio 17 2022",
    "--jobs", $env:BUILD_JOBS,
    "--src", $dependencySource,
    "--build", $buildRoot
)

python @arguments
if ($LASTEXITCODE -ne 0) { throw "OpenUSD build failed." }

$archiveBytes = 0
if (Test-Path -LiteralPath $dependencySource) {
    $archives = Get-ChildItem -LiteralPath $dependencySource -File -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '\.(zip|7z|tar|tar\.gz|tgz)$' }
    $archiveBytes = [int64](($archives | Measure-Object -Property Length -Sum).Sum ?? 0)
}

$dependencyBytes = Get-DirectoryBytes $dependencySource
$buildBytes = Get-DirectoryBytes $buildRoot
$installBytes = Get-DirectoryBytes $usdInstall

Write-Host "Retained dependency archives: $(Format-Bytes $archiveBytes)"
Write-Host "Dependency source footprint:  $(Format-Bytes $dependencyBytes)"
Write-Host "OpenUSD build footprint:      $(Format-Bytes $buildBytes)"
Write-Host "OpenUSD install footprint:    $(Format-Bytes $installBytes)"

Add-StepSummary @"
### OpenUSD build sizes

| Item | Size |
|---|---:|
| Retained downloaded archives | $(Format-Bytes $archiveBytes) |
| Dependency source directory | $(Format-Bytes $dependencyBytes) |
| Compiler build directory | $(Format-Bytes $buildBytes) |
| Installed OpenUSD SDK/runtime | $(Format-Bytes $installBytes) |
"@
