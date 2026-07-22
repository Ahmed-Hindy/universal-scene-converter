. "$PSScriptRoot/Common.ps1"

$PSNativeCommandUseErrorActionPreference = $false

$workRoot = Get-WorkRoot
$portableRoot = Join-Path $workRoot "dist/universal-scene-converter-windows-x64"
$smokeRoot = Join-Path $workRoot "smoke"
$diagnosticsRoot = Join-Path $workRoot "diagnostics"
$usdconvert = Join-Path $portableRoot "bin/usdconvert.exe"
$pluginRoot = Join-Path $portableRoot "plugin/usd"

function Invoke-Usdconvert {
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]] $Arguments,
        [int] $ExpectedExitCode = 0
    )

    $logPath = Join-Path $diagnosticsRoot "$Name.log"
    $output = & $usdconvert @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $output | Tee-Object -FilePath $logPath
    Write-Host "$Name exit code: $exitCode"
    if ($exitCode -ne $ExpectedExitCode) {
        throw "$Name returned $exitCode; expected $ExpectedExitCode."
    }
}

function Invoke-UsdconvertCaptured {
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]] $Arguments,
        [int] $ExpectedExitCode = 0
    )

    $processInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $processInfo.FileName = $usdconvert
    $processInfo.UseShellExecute = $false
    $processInfo.RedirectStandardOutput = $true
    $processInfo.RedirectStandardError = $true
    foreach ($argument in $Arguments) {
        [void] $processInfo.ArgumentList.Add($argument)
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $processInfo
    [void] $process.Start()
    $standardOutput = $process.StandardOutput.ReadToEnd()
    $standardError = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    $standardOutput | Set-Content -LiteralPath (Join-Path $diagnosticsRoot "$Name.stdout.log") -Encoding utf8
    $standardError | Set-Content -LiteralPath (Join-Path $diagnosticsRoot "$Name.stderr.log") -Encoding utf8
    Write-Host "$Name exit code: $($process.ExitCode)"
    if ($process.ExitCode -ne $ExpectedExitCode) {
        throw "$Name returned $($process.ExitCode); expected $ExpectedExitCode."
    }

    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        Stdout = $standardOutput
        Stderr = $standardError
    }
}

function Assert-NoTransactionDirectories {
    param([Parameter(Mandatory)][string] $Path)

    $transactionDirectories = @(Get-ChildItem -LiteralPath $Path -Directory -Filter ".usdconvert-*" -ErrorAction SilentlyContinue)
    if ($transactionDirectories.Count -ne 0) {
        $names = ($transactionDirectories.Name -join ", ")
        throw "Temporary transaction directories were not cleaned up: $names"
    }
}

Remove-Item -LiteralPath $smokeRoot, $diagnosticsRoot -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $smokeRoot, $diagnosticsRoot | Out-Null
$env:PATH = "$(Join-Path $portableRoot 'bin');$pluginRoot;$env:PATH"
$env:PXR_PLUGINPATH_NAME = $pluginRoot

Write-Host "=== Portable plugin tree ==="
Get-ChildItem -LiteralPath $pluginRoot -Recurse | Select-Object FullName, Length | Format-Table -AutoSize

Write-Host "=== Plugin metadata ==="
Get-ChildItem -LiteralPath $pluginRoot -Filter plugInfo.json -File -Recurse | ForEach-Object {
    "--- $($_.FullName)" | Tee-Object -FilePath (Join-Path $diagnosticsRoot "plugInfo.txt") -Append
    Get-Content -LiteralPath $_.FullName | Tee-Object -FilePath (Join-Path $diagnosticsRoot "plugInfo.txt") -Append
}

Write-Host "=== Native dependencies ==="
$nativeFiles = @($usdconvert) + @(
    (Join-Path $pluginRoot "usdFbx.dll"),
    (Join-Path $pluginRoot "usdObj.dll"),
    (Join-Path $pluginRoot "usdStl.dll"),
    (Join-Path $pluginRoot "usdGltf.dll"),
    (Join-Path $portableRoot "bin/fileformatUtils.dll")
)
foreach ($nativeFile in $nativeFiles) {
    "--- $nativeFile" | Tee-Object -FilePath (Join-Path $diagnosticsRoot "dependencies.txt") -Append
    dumpbin /DEPENDENTS $nativeFile 2>&1 |
        Tee-Object -FilePath (Join-Path $diagnosticsRoot "dependencies.txt") -Append
}

Invoke-Usdconvert -Name "usdconvert-help" -Arguments @("--help")
Invoke-Usdconvert -Name "invalid-arguments" -Arguments @() -ExpectedExitCode 2
$jsonArgumentError = Invoke-UsdconvertCaptured -Name "json-argument-error" `
    -Arguments @("--json", "--unknown") -ExpectedExitCode 2
$jsonArgumentErrorObject = $jsonArgumentError.Stdout | ConvertFrom-Json
if ($jsonArgumentError.Stderr -ne "" -or $jsonArgumentErrorObject.exit_code -ne 2 -or $jsonArgumentErrorObject.success) {
    throw "JSON argument errors must produce one structured stdout result and no stderr output."
}
$jsonAsOptionValue = Invoke-UsdconvertCaptured -Name "json-as-option-value" `
    -Arguments @("-o", "--json") -ExpectedExitCode 2
if ($jsonAsOptionValue.Stdout -ne "" -or $jsonAsOptionValue.Stderr -eq "") {
    throw "An option value named --json must not enable JSON output mode."
}
Invoke-Usdconvert -Name "missing-input" `
    -Arguments @((Join-Path $smokeRoot "missing.obj"), "-o", (Join-Path $smokeRoot "missing.usda")) `
    -ExpectedExitCode 4

@'
v 0 0 0
v 1 0 0
v 0 1 0
f 1 2 3
'@ | Set-Content -LiteralPath (Join-Path $smokeRoot "triangle.obj") -Encoding ascii

@'
solid triangle
  facet normal 0 0 1
    outer loop
      vertex 0 0 0
      vertex 1 0 0
      vertex 0 1 0
    endloop
  endfacet
endsolid triangle
'@ | Set-Content -LiteralPath (Join-Path $smokeRoot "triangle.stl") -Encoding ascii

@'
{
  "asset": {"version": "2.0"},
  "scene": 0,
  "scenes": [{"nodes": []}]
}
'@ | Set-Content -LiteralPath (Join-Path $smokeRoot "empty.gltf") -Encoding ascii

Remove-Item Env:TF_DEBUG -ErrorAction SilentlyContinue
Invoke-Usdconvert -Name "obj-import" -Arguments @(
    (Join-Path $smokeRoot "triangle.obj"),
    "-o", (Join-Path $smokeRoot "triangle-obj.usda")
)
Invoke-Usdconvert -Name "stl-import" -Arguments @(
    (Join-Path $smokeRoot "triangle.stl"),
    "-o", (Join-Path $smokeRoot "triangle-stl.usda")
)
Invoke-Usdconvert -Name "gltf-import" -Arguments @(
    (Join-Path $smokeRoot "empty.gltf"),
    "-o", (Join-Path $smokeRoot "empty-gltf.usda")
)

$sourceUsd = Join-Path $smokeRoot "source-mesh.usda"
@'
#usda 1.0
(
    defaultPrim = "Triangle"
    metersPerUnit = 1
    upAxis = "Y"
)

def Mesh "Triangle"
{
    int[] faceVertexCounts = [3]
    int[] faceVertexIndices = [0, 1, 2]
    normal3f[] normals = [(0, 0, 1)] (
        interpolation = "uniform"
    )
    point3f[] points = [(0, 0, 0), (1, 0, 0), (0, 1, 0)]
    texCoord2f[] primvars:st = [(0, 0), (1, 0), (0, 1)] (
        interpolation = "vertex"
    )
    uniform token subdivisionScheme = "none"
}
'@ | Set-Content -LiteralPath $sourceUsd -Encoding ascii

$jsonOutputPath = Join-Path $smokeRoot "json-output.usdc"
$jsonSuccess = Invoke-UsdconvertCaptured -Name "json-success" `
    -Arguments @($sourceUsd, "-o", $jsonOutputPath, "--json")
$jsonSuccessObject = $jsonSuccess.Stdout | ConvertFrom-Json
if ($jsonSuccess.Stderr -ne "" -or -not $jsonSuccessObject.success -or $jsonSuccessObject.exit_code -ne 0) {
    throw "Successful JSON conversion produced an invalid process result."
}
if ($jsonSuccessObject.schema_version -ne 1 -or $jsonSuccessObject.version -ne "0.6.4") {
    throw "The JSON result schema or tool version is incorrect."
}
if ($jsonSuccessObject.jobs.Count -ne 1 -or $jsonSuccessObject.jobs[0].generated_files.Count -lt 1) {
    throw "The JSON result did not report its job and generated files."
}
if ($jsonSuccessObject.jobs[0].output -ne $jsonOutputPath) {
    throw "The JSON result reported the wrong output path."
}

$jsonExisting = Invoke-UsdconvertCaptured -Name "json-existing-output" `
    -Arguments @($sourceUsd, "-o", $jsonOutputPath, "--json") -ExpectedExitCode 2
$jsonExistingObject = $jsonExisting.Stdout | ConvertFrom-Json
if ($jsonExisting.Stderr -ne "" -or $jsonExistingObject.exit_code -ne 2 -or $jsonExistingObject.jobs[0].status -ne "failed") {
    throw "JSON output protection did not report a structured failure."
}

$quietOutputPath = Join-Path $smokeRoot "quiet-output.usdc"
$quietSuccess = Invoke-UsdconvertCaptured -Name "quiet-success" `
    -Arguments @($sourceUsd, "-o", $quietOutputPath, "--quiet")
if ($quietSuccess.Stdout -ne "" -or $quietSuccess.Stderr -ne "") {
    throw "--quiet must suppress successful stdout and stderr output."
}

$automaticOutput = Join-Path $smokeRoot "source-mesh_converted.usda"
Remove-Item -LiteralPath $automaticOutput -Force -ErrorAction SilentlyContinue
Invoke-Usdconvert -Name "automatic-output" -Arguments @($sourceUsd)
if (-not (Test-Path -LiteralPath $automaticOutput -PathType Leaf)) {
    throw "The implicit output path was not created beside the input."
}
if ((Get-Content -LiteralPath $automaticOutput -Raw) -notmatch 'def Mesh') {
    throw "The implicit output conversion did not preserve a mesh."
}

$automaticOutputHash = (Get-FileHash -LiteralPath $automaticOutput -Algorithm SHA256).Hash
Invoke-Usdconvert -Name "automatic-output-exists" -Arguments @($sourceUsd) -ExpectedExitCode 2
if ((Get-FileHash -LiteralPath $automaticOutput -Algorithm SHA256).Hash -ne $automaticOutputHash) {
    throw "The existing implicit output changed without --force."
}
Invoke-Usdconvert -Name "automatic-output-force" -Arguments @($sourceUsd, "--force")

$protectedOutput = Join-Path $smokeRoot "protected.usda"
"preserve this file" | Set-Content -LiteralPath $protectedOutput -Encoding ascii
$protectedHash = (Get-FileHash -LiteralPath $protectedOutput -Algorithm SHA256).Hash
Invoke-Usdconvert -Name "existing-output" -Arguments @($sourceUsd, "-o", $protectedOutput) -ExpectedExitCode 2
if ((Get-FileHash -LiteralPath $protectedOutput -Algorithm SHA256).Hash -ne $protectedHash) {
    throw "An existing output changed without --force."
}
Invoke-Usdconvert -Name "force-overwrite" -Arguments @($sourceUsd, "-o", $protectedOutput, "--force")
if ((Get-Content -LiteralPath $protectedOutput -Raw) -notmatch 'def Mesh') {
    throw "--force did not replace the existing output with converted data."
}

$failedDeviceOutput = Join-Path $smokeRoot "NUL.usda"
Invoke-Usdconvert -Name "failed-export-cleanup" `
    -Arguments @($sourceUsd, "-o", $failedDeviceOutput, "--force") `
    -ExpectedExitCode 5
Assert-NoTransactionDirectories -Path $smokeRoot

Invoke-Usdconvert -Name "same-input-output" -Arguments @($sourceUsd, "-o", $sourceUsd) -ExpectedExitCode 2
if ((Get-Item -LiteralPath $sourceUsd).Length -le 16) {
    throw "The same-file rejection damaged the input file."
}

Invoke-Usdconvert -Name "unsupported-output" `
    -Arguments @($sourceUsd, "-o", (Join-Path $smokeRoot "unsupported.invalid")) `
    -ExpectedExitCode 5

$batchInputRoot = Join-Path $smokeRoot "batch-input"
$batchNestedRoot = Join-Path $batchInputRoot "nested"
New-Item -ItemType Directory -Force $batchNestedRoot | Out-Null
$batchAlpha = Join-Path $batchInputRoot "alpha.usda"
$batchBeta = Join-Path $batchNestedRoot "beta.usda"
Copy-Item -LiteralPath $sourceUsd -Destination $batchAlpha -Force
Copy-Item -LiteralPath $sourceUsd -Destination $batchBeta -Force

Invoke-Usdconvert -Name "directory-requires-output-dir" `
    -Arguments @($batchInputRoot) `
    -ExpectedExitCode 2
Invoke-Usdconvert -Name "recursive-requires-directory" `
    -Arguments @($batchAlpha, "--recursive", "--output-dir", (Join-Path $smokeRoot "invalid-recursive")) `
    -ExpectedExitCode 2

$batchTopOutput = Join-Path $smokeRoot "batch-top-output"
Invoke-Usdconvert -Name "batch-directory-top" `
    -Arguments @($batchInputRoot, "--output-dir", $batchTopOutput, "--output-format", ".USDC")
if (-not (Test-Path -LiteralPath (Join-Path $batchTopOutput "alpha_converted.usdc") -PathType Leaf)) {
    throw "Non-recursive directory conversion did not create the top-level output."
}
if (Test-Path -LiteralPath (Join-Path $batchTopOutput "nested/beta_converted.usdc")) {
    throw "Non-recursive directory conversion unexpectedly processed a nested input."
}

$batchRecursiveOutput = Join-Path $smokeRoot "batch-recursive-output"
Invoke-Usdconvert -Name "batch-directory-recursive" `
    -Arguments @($batchInputRoot, "--recursive", "--output-dir", $batchRecursiveOutput, "--output-format", "usdc")
foreach ($expectedBatchPath in @(
    (Join-Path $batchRecursiveOutput "alpha_converted.usdc"),
    (Join-Path $batchRecursiveOutput "nested/beta_converted.usdc")
)) {
    if (-not (Test-Path -LiteralPath $expectedBatchPath -PathType Leaf)) {
        throw "Recursive directory conversion did not create $expectedBatchPath."
    }
}

$batchExplicitOutput = Join-Path $smokeRoot "batch-explicit-output"
Invoke-Usdconvert -Name "batch-explicit-files" `
    -Arguments @($batchAlpha, $batchBeta, "--output-dir", $batchExplicitOutput, "--output-format", "glb")
foreach ($expectedBatchPath in @(
    (Join-Path $batchExplicitOutput "alpha_converted.glb"),
    (Join-Path $batchExplicitOutput "beta_converted.glb")
)) {
    if (-not (Test-Path -LiteralPath $expectedBatchPath -PathType Leaf)) {
        throw "Explicit batch conversion did not create $expectedBatchPath."
    }
}

$batchPartialOutput = Join-Path $smokeRoot "batch-partial-output"
$batchMissing = Join-Path $batchInputRoot "missing.usda"
Invoke-Usdconvert -Name "batch-partial-failure" `
    -Arguments @($batchAlpha, $batchMissing, "--output-dir", $batchPartialOutput, "--output-format", "usdc") `
    -ExpectedExitCode 6
if (-not (Test-Path -LiteralPath (Join-Path $batchPartialOutput "alpha_converted.usdc") -PathType Leaf)) {
    throw "A valid batch item was not converted after another item failed."
}
if ((Get-Content -LiteralPath (Join-Path $diagnosticsRoot "batch-partial-failure.log") -Raw) -notmatch 'Summary: 1 succeeded, 1 failed') {
    throw "The partial batch summary is missing or incorrect."
}

$batchProtectedOutput = Join-Path $smokeRoot "batch-protected-output"
New-Item -ItemType Directory -Force $batchProtectedOutput | Out-Null
$batchProtectedFile = Join-Path $batchProtectedOutput "alpha_converted.usdc"
"preserve batch output" | Set-Content -LiteralPath $batchProtectedFile -Encoding ascii
$batchProtectedHash = (Get-FileHash -LiteralPath $batchProtectedFile -Algorithm SHA256).Hash
Invoke-Usdconvert -Name "batch-existing-output" `
    -Arguments @($batchAlpha, $batchBeta, "--output-dir", $batchProtectedOutput, "--output-format", "usdc") `
    -ExpectedExitCode 6
if ((Get-FileHash -LiteralPath $batchProtectedFile -Algorithm SHA256).Hash -ne $batchProtectedHash) {
    throw "A protected batch output changed without --force."
}
if (-not (Test-Path -LiteralPath (Join-Path $batchProtectedOutput "beta_converted.usdc") -PathType Leaf)) {
    throw "The batch did not continue after an existing-output failure."
}
Invoke-Usdconvert -Name "batch-force" `
    -Arguments @($batchAlpha, $batchBeta, "--output-dir", $batchProtectedOutput, "--output-format", "usdc", "--force")
if ((Get-FileHash -LiteralPath $batchProtectedFile -Algorithm SHA256).Hash -eq $batchProtectedHash) {
    throw "--force did not replace the protected batch output."
}
Assert-NoTransactionDirectories -Path $batchProtectedOutput

$unicodeRoot = Join-Path $smokeRoot "ユニコード"
New-Item -ItemType Directory -Force $unicodeRoot | Out-Null
$unicodeSource = Join-Path $unicodeRoot "三角形.usda"
$unicodeUsdc = Join-Path $unicodeRoot "結果.usdc"
$unicodeRoundTrip = Join-Path $unicodeRoot "再読み込み.usda"
$unicodeInputObj = Join-Path $smokeRoot "unicode-input.obj"
Copy-Item -LiteralPath $sourceUsd -Destination $unicodeSource -Force

Invoke-Usdconvert -Name "unicode-usdc-export" -Arguments @($unicodeSource, "-o", $unicodeUsdc)
Invoke-Usdconvert -Name "unicode-usdc-reimport" -Arguments @($unicodeUsdc, "-o", $unicodeRoundTrip)
Invoke-Usdconvert -Name "unicode-input-obj-export" -Arguments @($unicodeSource, "-o", $unicodeInputObj)
if ((Get-Content -LiteralPath $unicodeRoundTrip -Raw) -notmatch 'def Mesh') {
    throw "The Unicode OpenUSD path round trip did not preserve a mesh."
}
if (-not (Test-Path -LiteralPath $unicodeInputObj -PathType Leaf)) {
    throw "A Unicode input path could not be exported through the OBJ plugin."
}

$malformedFbx = Join-Path $smokeRoot "malformed.fbx"
"This is not a valid FBX file." | Set-Content -LiteralPath $malformedFbx -Encoding ascii
Invoke-Usdconvert -Name "malformed-fbx" `
    -Arguments @($malformedFbx, "-o", (Join-Path $smokeRoot "malformed-fbx.usda")) `
    -ExpectedExitCode 4

$roundTripFormats = @(
    @{ Name = "fbx"; Extension = "fbx" },
    @{ Name = "obj"; Extension = "obj" },
    @{ Name = "stl"; Extension = "stl" },
    @{ Name = "gltf"; Extension = "gltf" },
    @{ Name = "glb"; Extension = "glb" }
)

foreach ($format in $roundTripFormats) {
    $exportedPath = Join-Path $smokeRoot "roundtrip.$($format.Extension)"
    $reimportedPath = Join-Path $smokeRoot "roundtrip-$($format.Name).usda"

    Invoke-Usdconvert -Name "$($format.Name)-export" -Arguments @($sourceUsd, "-o", $exportedPath)
    if (-not (Test-Path -LiteralPath $exportedPath)) {
        throw "$($format.Name) export did not create an output file."
    }
    if ((Get-Item -LiteralPath $exportedPath).Length -le 16) {
        throw "$($format.Name) export produced an unexpectedly small file."
    }

    if ($format.Name -eq "gltf") {
        $gltfText = Get-Content -LiteralPath $exportedPath -Raw
        if ($gltfText -notmatch '"asset"' -or $gltfText -notmatch '"meshes"') {
            throw "glTF export is missing expected asset or mesh data."
        }
    } elseif ($format.Name -eq "glb") {
        $glbBytes = [System.IO.File]::ReadAllBytes($exportedPath)
        $glbMagic = [System.Text.Encoding]::ASCII.GetString($glbBytes, 0, 4)
        if ($glbMagic -ne "glTF") {
            throw "GLB export has an invalid magic header."
        }
    } elseif ($format.Name -eq "fbx") {
        $unicodeFbx = Join-Path $unicodeRoot "人物.fbx"
        $unicodeFbxUsd = Join-Path $unicodeRoot "人物.usda"
        Copy-Item -LiteralPath $exportedPath -Destination $unicodeFbx -Force
        Invoke-Usdconvert -Name "unicode-fbx-input" -Arguments @($unicodeFbx, "-o", $unicodeFbxUsd)
        if ((Get-Content -LiteralPath $unicodeFbxUsd -Raw) -notmatch 'def Mesh') {
            throw "The Unicode FBX input path did not preserve a mesh."
        }
    }

    Invoke-Usdconvert -Name "$($format.Name)-reimport" -Arguments @($exportedPath, "-o", $reimportedPath)
    $reimportedUsd = Get-Content -LiteralPath $reimportedPath -Raw
    if ($reimportedUsd -notmatch 'def Mesh') {
        throw "$($format.Name) round trip did not preserve a USD mesh."
    }
}

$cameraUsd = Join-Path $smokeRoot "camera.usda"
$cameraFbx = Join-Path $smokeRoot "camera.fbx"
$cameraRoundTripUsd = Join-Path $smokeRoot "camera-fbx.usda"
@'
#usda 1.0
(
    defaultPrim = "Camera"
    upAxis = "Y"
)

def Camera "Camera"
{
    float focalLength = 50
    float horizontalAperture = 36
    token projection = "perspective"
    float verticalAperture = 24
}
'@ | Set-Content -LiteralPath $cameraUsd -Encoding ascii
Invoke-Usdconvert -Name "camera-fbx-export" -Arguments @($cameraUsd, "-o", $cameraFbx)
Invoke-Usdconvert -Name "camera-fbx-reimport" -Arguments @($cameraFbx, "-o", $cameraRoundTripUsd)
if ((Get-Content -LiteralPath $cameraRoundTripUsd -Raw) -notmatch 'def Camera') {
    throw "FBX camera round trip did not preserve a USD camera."
}

$skinnedUsd = Join-Path $smokeRoot "skinned-animation.usda"
$skinnedFbx = Join-Path $smokeRoot "skinned-animation.fbx"
$skinnedRoundTripUsd = Join-Path $smokeRoot "skinned-animation-fbx.usda"
@'
#usda 1.0
(
    defaultPrim = "Character"
    endTimeCode = 24
    framesPerSecond = 24
    startTimeCode = 0
    timeCodesPerSecond = 24
    upAxis = "Y"
)

def SkelRoot "Character"
{
    def Skeleton "Skeleton"
    {
        uniform token[] joints = ["Root"]
        matrix4d[] bindTransforms = [((1, 0, 0, 0), (0, 1, 0, 0), (0, 0, 1, 0), (0, 0, 0, 1))]
        matrix4d[] restTransforms = [((1, 0, 0, 0), (0, 1, 0, 0), (0, 0, 1, 0), (0, 0, 0, 1))]
        rel skel:animationSource = </Character/Animation>
    }

    def SkelAnimation "Animation"
    {
        uniform token[] joints = ["Root"]
        quatf[] rotations = [(1, 0, 0, 0)]
        half3[] scales = [(1, 1, 1)]
        float3[] translations.timeSamples = {
            0: [(0, 0, 0)],
            24: [(1, 0, 0)],
        }
    }

    def Mesh "Mesh" (
        prepend apiSchemas = ["SkelBindingAPI"]
    )
    {
        int[] faceVertexCounts = [3]
        int[] faceVertexIndices = [0, 1, 2]
        point3f[] points = [(0, 0, 0), (1, 0, 0), (0, 1, 0)]
        int[] primvars:skel:jointIndices = [0, 0, 0] (
            elementSize = 1
            interpolation = "vertex"
        )
        float[] primvars:skel:jointWeights = [1, 1, 1] (
            elementSize = 1
            interpolation = "vertex"
        )
        rel skel:skeleton = </Character/Skeleton>
        uniform token subdivisionScheme = "none"
    }
}
'@ | Set-Content -LiteralPath $skinnedUsd -Encoding ascii
Invoke-Usdconvert -Name "skinned-fbx-export" -Arguments @($skinnedUsd, "-o", $skinnedFbx)
Invoke-Usdconvert -Name "skinned-fbx-reimport" -Arguments @($skinnedFbx, "-o", $skinnedRoundTripUsd)
$skinnedRoundTripText = Get-Content -LiteralPath $skinnedRoundTripUsd -Raw
if ($skinnedRoundTripText -notmatch 'def Skeleton' -or $skinnedRoundTripText -notmatch 'def Mesh') {
    throw "FBX skinned-mesh round trip did not preserve skeleton and mesh data."
}
if ($skinnedRoundTripText -notmatch 'SkelAnimation' -or $skinnedRoundTripText -notmatch 'timeSamples') {
    Write-Warning "Adobe 2026.07 preserved FBX skinning but did not preserve skeletal animation samples."
}

$texturePath = Join-Path $smokeRoot "texture.png"
$textureBytes = [Convert]::FromBase64String(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9WlZL8sAAAAASUVORK5CYII="
)
[System.IO.File]::WriteAllBytes($texturePath, $textureBytes)

@'
newmtl TexturedMaterial
Kd 1.0 1.0 1.0
map_Kd texture.png
'@ | Set-Content -LiteralPath (Join-Path $smokeRoot "textured.mtl") -Encoding ascii

@'
mtllib textured.mtl
o TexturedTriangle
v 0 0 0
v 1 0 0
v 0 1 0
vt 0 0
vt 1 0
vt 0 1
usemtl TexturedMaterial
f 1/1 2/2 3/3
'@ | Set-Content -LiteralPath (Join-Path $smokeRoot "textured.obj") -Encoding ascii

$texturedUsd = Join-Path $smokeRoot "textured-obj.usda"
Invoke-Usdconvert -Name "textured-obj-import" -Arguments @(
    (Join-Path $smokeRoot "textured.obj"),
    "-o", $texturedUsd
)
$texturedUsdText = Get-Content -LiteralPath $texturedUsd -Raw
if ($texturedUsdText -notmatch 'def Material') {
    throw "Textured OBJ import did not create a USD material."
}
if ($texturedUsdText -notmatch 'texture\.png') {
    throw "Textured OBJ import did not preserve the texture asset path."
}
if ($texturedUsdText -notmatch 'ND_open_pbr_surface_surfaceshader') {
    throw "Textured OBJ import did not author the expected OpenPBR material network."
}
if ($texturedUsdText -notmatch 'UsdPreviewSurface') {
    throw "Textured OBJ import did not preserve the UsdPreviewSurface compatibility network."
}

$texturedFbx = Join-Path $smokeRoot "textured.fbx"
$texturedFbxRoundTripUsd = Join-Path $smokeRoot "textured-fbx.usda"
Invoke-Usdconvert -Name "textured-fbx-export" -Arguments @($texturedUsd, "-o", $texturedFbx)
Invoke-Usdconvert -Name "textured-fbx-reimport" -Arguments @($texturedFbx, "-o", $texturedFbxRoundTripUsd)
$texturedFbxRoundTripText = Get-Content -LiteralPath $texturedFbxRoundTripUsd -Raw
if ($texturedFbxRoundTripText -notmatch 'def Mesh' -or $texturedFbxRoundTripText -notmatch 'def Material') {
    throw "Textured FBX round trip did not preserve mesh and material data."
}
if ($texturedFbxRoundTripText -notmatch 'texture\.png') {
    throw "Textured FBX round trip did not preserve the texture asset path."
}

$texturedGltf = Join-Path $smokeRoot "textured.gltf"
$sidecarSafeGltf = Join-Path $smokeRoot "sidecar-safe.gltf"
$sidecarSafeBin = Join-Path $smokeRoot "sidecar-safe.bin"
"preserve this sidecar" | Set-Content -LiteralPath $sidecarSafeBin -Encoding ascii
$sidecarHash = (Get-FileHash -LiteralPath $sidecarSafeBin -Algorithm SHA256).Hash
Invoke-Usdconvert -Name "existing-sidecar" `
    -Arguments @($sourceUsd, "-o", $sidecarSafeGltf) `
    -ExpectedExitCode 2
if (Test-Path -LiteralPath $sidecarSafeGltf) {
    throw "The main glTF output was committed despite an existing sidecar conflict."
}
if ((Get-FileHash -LiteralPath $sidecarSafeBin -Algorithm SHA256).Hash -ne $sidecarHash) {
    throw "An existing glTF sidecar changed without --force."
}
Assert-NoTransactionDirectories -Path $smokeRoot
Invoke-Usdconvert -Name "force-sidecar-overwrite" `
    -Arguments @($sourceUsd, "-o", $sidecarSafeGltf, "--force")
if (-not (Test-Path -LiteralPath $sidecarSafeGltf -PathType Leaf)) {
    throw "--force did not commit the glTF output."
}
if ((Get-FileHash -LiteralPath $sidecarSafeBin -Algorithm SHA256).Hash -eq $sidecarHash) {
    throw "--force did not replace the existing glTF sidecar."
}

Invoke-Usdconvert -Name "textured-gltf-export" -Arguments @($texturedUsd, "-o", $texturedGltf)
$texturedGltfText = Get-Content -LiteralPath $texturedGltf -Raw
if ($texturedGltfText -notmatch '"materials"' -or
    $texturedGltfText -notmatch '"images"' -or
    $texturedGltfText -notmatch '"textures"') {
    throw "Textured glTF export is missing material or image data."
}

$texturedRoundTripUsd = Join-Path $smokeRoot "textured-gltf.usda"
Invoke-Usdconvert -Name "textured-gltf-reimport" -Arguments @($texturedGltf, "-o", $texturedRoundTripUsd)
$texturedRoundTripText = Get-Content -LiteralPath $texturedRoundTripUsd -Raw
if ($texturedRoundTripText -notmatch 'def Mesh' -or
    $texturedRoundTripText -notmatch 'def Material') {
    throw "Textured glTF round trip did not preserve mesh and material data."
}
if ($texturedRoundTripText -notmatch 'ND_open_pbr_surface_surfaceshader' -or
    $texturedRoundTripText -notmatch 'UsdPreviewSurface') {
    throw "Textured glTF round trip did not preserve both material networks."
}

$zipPath = Join-Path $workRoot "dist/universal-scene-converter-windows-x64.zip"
$cleanExtractRoot = Join-Path $workRoot "clean-extract"
Remove-Item -LiteralPath $cleanExtractRoot -Recurse -Force -ErrorAction SilentlyContinue
Expand-Archive -LiteralPath $zipPath -DestinationPath $cleanExtractRoot -Force

$cleanExecutable = Join-Path $cleanExtractRoot "bin/usdconvert.exe"
$cleanBuildInfo = Join-Path $cleanExtractRoot "BUILD-INFO.txt"
$cleanReadme = Join-Path $cleanExtractRoot "README.md"
$cleanDevelopmentGuide = Join-Path $cleanExtractRoot "DEVELOPMENT.md"
$cleanRootLicense = Join-Path $cleanExtractRoot "LICENSE"
$cleanJsonGuide = Join-Path $cleanExtractRoot "JSON_OUTPUT.md"
$cleanJsonSchema = Join-Path $cleanExtractRoot "schemas/usdconvert-result.schema.json"
$cleanProjectLicense = Join-Path $cleanExtractRoot "licenses/Universal-Scene-Converter-LICENSE.txt"
$cleanExport = Join-Path $smokeRoot "clean-executable.obj"
$cleanReimport = Join-Path $smokeRoot "clean-executable.usda"
foreach ($requiredMetadataPath in @(
    $cleanExecutable,
    $cleanBuildInfo,
    $cleanReadme,
    $cleanDevelopmentGuide,
    $cleanRootLicense,
    $cleanJsonGuide,
    $cleanJsonSchema,
    $cleanProjectLicense
)) {
    if (-not (Test-Path -LiteralPath $requiredMetadataPath -PathType Leaf)) {
        throw "The cleanly extracted ZIP is missing $requiredMetadataPath."
    }
}

$schemaObject = Get-Content -LiteralPath $cleanJsonSchema -Raw | ConvertFrom-Json
$buildInfoText = Get-Content -LiteralPath $cleanBuildInfo -Raw
if ($buildInfoText -match '(?m)^(Repository|Commit|Workflow run):') {
    throw "BUILD-INFO.txt contains unnecessary repository provenance."
}

if ($schemaObject.title -ne "Universal Scene Converter result" -or $schemaObject.properties.schema_version.const -ne 1) {
    throw "The packaged JSON result schema is invalid."
}
$projectLicenseText = Get-Content -LiteralPath $cleanProjectLicense -Raw
if ($projectLicenseText -notmatch 'BSD 3-Clause License' -or $projectLicenseText -notmatch 'Copyright \(c\) 2026 Ahmed Hindy') {
    throw "The packaged Universal Scene Converter license or author attribution is invalid."
}

$systemOnlyPath = "$env:SystemRoot\System32;$env:SystemRoot"
$cleanVersionCommand = @(
    "set `"PATH=$systemOnlyPath`"",
    "set `"PXR_PLUGINPATH_NAME=`"",
    "`"$cleanExecutable`" --version"
) -join " && "
$cleanVersionOutput = & "$env:SystemRoot\System32\cmd.exe" /d /c $cleanVersionCommand 2>&1
$cleanVersionExitCode = $LASTEXITCODE
$cleanVersionOutput | Tee-Object -FilePath (Join-Path $diagnosticsRoot "clean-version.log")
Write-Host "clean-extract-version exit code: $cleanVersionExitCode"
if ($cleanVersionExitCode -ne 0) {
    throw "The cleanly extracted executable could not start directly."
}

$cleanExportCommand = @(
    "set `"PATH=$systemOnlyPath`"",
    "set `"PXR_PLUGINPATH_NAME=`"",
    "`"$cleanExecutable`" `"$sourceUsd`" -o `"$cleanExport`""
) -join " && "
$cleanExportOutput = & "$env:SystemRoot\System32\cmd.exe" /d /c $cleanExportCommand 2>&1
$cleanExportExitCode = $LASTEXITCODE
$cleanExportOutput | Tee-Object -FilePath (Join-Path $diagnosticsRoot "clean-export.log")
Write-Host "clean-extract-export exit code: $cleanExportExitCode"
if ($cleanExportExitCode -ne 0 -or -not (Test-Path -LiteralPath $cleanExport)) {
    throw "The cleanly extracted executable could not export OBJ."
}

$cleanReimportCommand = @(
    "set `"PATH=$systemOnlyPath`"",
    "set `"PXR_PLUGINPATH_NAME=`"",
    "`"$cleanExecutable`" `"$cleanExport`" -o `"$cleanReimport`""
) -join " && "
$cleanReimportOutput = & "$env:SystemRoot\System32\cmd.exe" /d /c $cleanReimportCommand 2>&1
$cleanReimportExitCode = $LASTEXITCODE
$cleanReimportOutput | Tee-Object -FilePath (Join-Path $diagnosticsRoot "clean-reimport.log")
Write-Host "clean-extract-reimport exit code: $cleanReimportExitCode"
if ($cleanReimportExitCode -ne 0 -or -not (Test-Path -LiteralPath $cleanReimport)) {
    throw "The cleanly extracted executable could not re-import OBJ."
}
if ((Get-Content -LiteralPath $cleanReimport -Raw) -notmatch 'def Mesh') {
    throw "The cleanly extracted executable did not preserve a mesh."
}

Write-Host "All imports, exports, round trips, and clean-extraction tests passed."
