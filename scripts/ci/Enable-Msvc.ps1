$ErrorActionPreference = "Stop"

$vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio/Installer/vswhere.exe"
if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) {
    throw "vswhere.exe was not found."
}

$installationPath = & $vswhere -latest -products * `
    -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
    -property installationPath
if (-not $installationPath) {
    throw "A Visual Studio installation with the x64 C++ toolchain was not found."
}

$devCommand = Join-Path $installationPath "Common7/Tools/VsDevCmd.bat"
$environmentLines = & $env:ComSpec /s /c `
    "`"$devCommand`" -no_logo -arch=x64 -host_arch=x64 && set"
if ($LASTEXITCODE -ne 0) {
    throw "VsDevCmd.bat failed with exit code $LASTEXITCODE."
}

foreach ($environmentLine in $environmentLines) {
    if ($environmentLine -notmatch '^([^=]+)=(.*)$') {
        continue
    }
    "$($Matches[1])=$($Matches[2])" |
        Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append
}
