# Developing Universal Scene Converter

Universal Scene Converter is a Windows-first, CI-built distribution that combines a minimal OpenUSD runtime, selected Adobe file-format plugins, and a focused C++ converter.

## Current toolchain

| Component | Version or configuration |
|---|---|
| OpenUSD | `v25.11` |
| Adobe USD Fileformat Plugins | `2026.07` |
| Autodesk FBX SDK | `2020.3.9`, VS2022 |
| Universal Scene Converter | `0.6.4` |
| C++ | C++17 |
| Compiler | Visual Studio 2022, x64 |
| CMake | 3.27 or newer |
| Python | 3.11 for a cold OpenUSD build only |
| Target | Windows x64, Release |

The upstream versions are pinned in `.github/workflows/build-universal-scene-converter.yml`. The application version is defined by `project(... VERSION ...)` in `CMakeLists.txt`.

## Architecture

`usdconvert.exe` is a thin frontend over the internal static `converter_core` library. The core handles command parsing, deterministic job planning, packaged-runtime initialization, conversion execution, generated-file reporting, and human or JSON result rendering.

The implementation is split by responsibility:

- `src/arguments.cpp` parses UTF-16 Windows arguments and output modes;
- `src/job_plan.cpp` resolves files, directories, recursive layouts, duplicates, and collisions;
- `src/plugin_runtime.cpp` locates and registers the packaged OpenUSD and Adobe plugin trees;
- `src/converter.cpp` opens layers and executes planned conversions;
- `src/output_transaction.cpp` stages main files and sidecars, then commits or rolls back replacements;
- `src/result_output.cpp` owns human-readable, quiet, and versioned JSON output;
- `src/usdconvert.cpp` only handles process-level orchestration.

The converter does not provide a second conversion layer or fallback parser. File-format behavior and fidelity come from OpenUSD and Adobe USD Fileformat Plugins.

The portable package relocates the required OpenUSD DLLs and registry metadata beside the executable. `usdconvert.exe` registers:

```text
bin/usd/plugInfo.json
plugin/usd/plugInfo.json
```

This allows the extracted application to run without `PXR_PLUGINPATH_NAME`, an installed OpenUSD SDK, or modified system paths.

## Repository layout

```text
.github/workflows/
  build-universal-scene-converter.yml  Native build, packaging, smoke tests, artifact upload
  public-assets.yml        Public regression matrix

scripts/ci/
  Common.ps1               Shared paths, sizes, and step-summary helpers
  Enable-Msvc.ps1          Visual Studio environment setup for GitHub Actions
  Get-Sources.ps1          Pinned shallow upstream clones
  Get-FbxSdk.ps1           Signed Autodesk SDK download, extraction, notices
  Build-OpenUsd.ps1        Minimal OpenUSD SDK/runtime build
  Build-AdobePlugins.ps1   FBX, OBJ, STL, and glTF plugin build
  Build-Converter.ps1      Focused usdconvert.exe build
  Package-Runtime.ps1      DLL closure, pruning, metadata, and ZIP packaging
  Test-Runtime.ps1         CLI, format, material, Unicode, and isolation tests

src/                        Internal core implementation and thin executable frontend
tests/native/               Focused C++ parser, planner, JSON, and transaction tests
schemas/                    Versioned machine-readable result schema
licenses/                   Third-party notices included in the portable package
LICENSE                     BSD-3-Clause terms and Ahmed Hindy attribution
CMakeLists.txt               Core library, CLI, and native test targets
tests/public-assets.json     Pinned public asset manifest
tests/Test-PublicAsset.ps1   Per-asset conversion and regression validation
```

## Prerequisites for local builds

Use Windows 10 or 11 with:

- Visual Studio 2022 and the Desktop development with C++ workload;
- CMake 3.27 or newer;
- Git;
- Python 3.11 for a cold OpenUSD build;
- PowerShell 7 (`pwsh`). The scripts use PowerShell 7 language features and are not supported under Windows PowerShell 5.1;
- 7-Zip available as `7z` for extracting the Autodesk FBX SDK installer;
- internet access for the pinned OpenUSD, Adobe, and Autodesk downloads.

A cold OpenUSD build downloads and compiles substantial third-party dependencies and can take a long time. GitHub Actions caches are the preferred development path when changing only Universal Scene Converter, packaging, or tests.

## Local build sequence

The scripts under `scripts/ci` are CI-oriented. They expect `GITHUB_WORKSPACE` and the pinned version variables, but they can be run locally from an x64 Visual Studio developer shell.

Open **x64 Native Tools Command Prompt for VS 2022**, start `pwsh` so it inherits the MSVC environment, then run from the repository root:

```powershell
$env:GITHUB_WORKSPACE = (Get-Location).Path
$env:OPENUSD_REF = "v25.11"
$env:ADOBE_REF = "2026.07"
$env:FBX_SDK_VERSION = "2020.3.9"
$env:BUILD_JOBS = "4"
$env:GITHUB_ENV = Join-Path $env:GITHUB_WORKSPACE "work/local-github-env"

.\scripts\ci\Get-Sources.ps1
.\scripts\ci\Build-OpenUsd.ps1
.\scripts\ci\Get-FbxSdk.ps1
Get-Content $env:GITHUB_ENV | ForEach-Object {
    $name, $value = $_ -split '=', 2
    Set-Item -Path "Env:$name" -Value $value
}
.\scripts\ci\Build-AdobePlugins.ps1
.\scripts\ci\Build-Converter.ps1
.\scripts\ci\Package-Runtime.ps1
.\scripts\ci\Test-Runtime.ps1
```

Do not run `Enable-Msvc.ps1` directly for a local shell. It writes the discovered environment to GitHub Actions' `GITHUB_ENV` file. Use a Visual Studio developer shell instead.

Build output is placed under `work/`:

```text
work/usd-install/                 Combined SDK/runtime staging area
work/usdconvert-build/            Converter build tree
work/dist/universal-scene-converter-windows-x64/   Extracted portable runtime
work/dist/universal-scene-converter-windows-x64.zip
```

### Rebuild only the converter

After `work/usd-install` contains the matching OpenUSD and Adobe SDK/runtime:

```powershell
$env:GITHUB_WORKSPACE = (Get-Location).Path
$env:BUILD_JOBS = "4"

.\scripts\ci\Build-Converter.ps1
.\scripts\ci\Package-Runtime.ps1
.\scripts\ci\Test-Runtime.ps1
```

The converter must be linked against the same OpenUSD SDK used by the packaged runtime.

## Build configuration

The OpenUSD build enables shared libraries, imaging, OpenImageIO, tools, and oneTBB. It disables Python bindings and unrelated heavy integrations such as MaterialX, OpenVDB, Alembic, Vulkan, Embree, RenderMan, Ptex, OpenColorIO, and Draco.

The Adobe build enables only:

- FBX;
- OBJ;
- STL;
- glTF and GLB.

FBX is compiled against Autodesk FBX SDK 2020.3.9 using Adobe's static `/MD` integration. The SDK installer is not added to the portable package. Autodesk license and notice files captured from the SDK distribution are included under `licenses/`.

PLY, SPZ, SBSAR, Draco, MaterialX integration, and ASM are disabled.

## Packaging

`Package-Runtime.ps1` assembles the consumer ZIP from the combined install tree. It:

1. copies runtime binaries and plugin metadata;
2. identifies the recursive PE dependency closure with `dumpbin /DEPENDENTS`;
3. removes unused DLLs, executables, registries, import libraries, debug files, and development files;
4. adds the Universal Scene Converter BSD-3-Clause license, third-party notices, `JSON_OUTPUT.md`, and the versioned JSON Schema;
5. writes `BUILD-INFO.txt`;
6. creates the ZIP artifact.

The dependency closure is deliberate. Avoid replacing it with a hard-coded DLL allowlist unless the resulting package is tested against dependency changes in both upstream projects.

## Tests

### Portable runtime tests

`Build-Converter.ps1` first runs the native CTest target, which covers parser semantics, job planning, duplicate and collision handling, recursive layout preservation, JSON escaping, and transactional sidecar commits.

`Test-Runtime.ps1` then runs after packaging and verifies:

- help, version, usage errors, and stable exit codes;
- machine-readable JSON success and failure results, generated-file reporting, and `--quiet` behavior;
- missing input and unsupported output handling;
- automatic `<stem>_converted<extension>` output naming;
- existing-output refusal and explicit `--force` replacement;
- staged export commit, sidecar collision protection, and failed-export cleanup;
- explicit-file and directory batch conversion;
- recursive layout preservation, partial-failure summaries, and batch exit code `6`;
- same-file rejection without damaging the input;
- FBX, OBJ, STL, glTF, and GLB import/export round trips;
- FBX camera, skinned-mesh, textured-material, Unicode-path, and malformed-input behavior;
- the documented Adobe 2026.07 limitation that skeletal animation samples are dropped by FBX round trips;
- USDA and USDC conversion;
- Unicode OpenUSD paths and Unicode input paths;
- textured OBJ to USD to glTF to USD conversion;
- OpenPBR material authoring with a UsdPreviewSurface compatibility network;
- direct execution from a clean extraction with a system-only `PATH` and no plugin environment variables.

### Public asset regression

`.github/workflows/public-assets.yml` runs a matrix generated from `tests/public-assets.json`. Every source file is:

- pinned to an upstream commit;
- verified with SHA-256;
- tested independently with `fail-fast: false`;
- converted to USDA and USDC;
- exported and re-imported;
- published with source and license information.

The public matrix runs after a successful native build, weekly, and manually. It currently covers 14 assets, including four FBX fixtures for hierarchy, materials, vertex colors, and multi-mesh scenes. Optional per-asset USDA token-count assertions detect silent content loss. Large fixtures can disable successful artifact upload while retaining the complete conversion test.

## CI caches

The native workflow uses two deterministic caches:

1. **OpenUSD SDK cache** — keyed by platform, OpenUSD version, and hashes of the OpenUSD build scripts.
2. **Combined native SDK cache** — keyed by platform, OpenUSD version, Adobe version, FBX SDK version, and hashes of all native build layers and notices.

On a combined-cache hit, CI skips Python setup, upstream clones, OpenUSD compilation, and Adobe compilation. It rebuilds the small converter, repackages the runtime, and reruns all portable tests.

Do not add manually incremented cache revision variables. Change the relevant build script when the native build configuration changes; its content hash will invalidate the correct cache.

## Updating dependencies

### Adobe plugins

1. Change `ADOBE_REF` in `.github/workflows/build-universal-scene-converter.yml`.
2. Update the version table in this file.
3. Push to `main` and allow the combined native cache to rebuild.
4. Verify portable runtime tests and all public assets.
5. Compare package size and material output with the previous version.
6. Add or strengthen regression assertions for intentional behavior changes.
7. Bump the Universal Scene Converter version in `CMakeLists.txt` when the shipped behavior changes.

### Autodesk FBX SDK

1. Change `FBX_SDK_VERSION` in `.github/workflows/build-universal-scene-converter.yml`.
2. Update the pinned installer URL and SHA-256 in `scripts/ci/Get-FbxSdk.ps1`.
3. Confirm the installer has a valid Autodesk Authenticode signature.
4. Review the SDK license files captured by the build and update the packaged notice when required.
5. Expect a new combined native cache and a larger portable runtime.
6. Run the FBX round-trip test and pinned public FBX asset before release.

Do not commit or publish the Autodesk SDK installer. Only the compiled plugin and required notices belong in Universal Scene Converter artifacts.

### OpenUSD

An OpenUSD upgrade is broader because it changes the ABI, SDK, runtime libraries, plugin metadata, and converter link target. In addition to the Adobe procedure:

- confirm that the selected Adobe release supports the OpenUSD version;
- expect a full cold OpenUSD build and new base cache;
- inspect installed header and import-library layout;
- revalidate plugin registration and the runtime DLL closure;
- test both ASCII and binary USD formats and USDZ.

## Releases

Releases are tag-driven.

1. Merge or push the validated version commit to `main`.
2. Confirm the build and public-asset workflows pass.
3. Create and push a matching version tag:

```powershell
$version = "v0.6.4"
git tag $version
git push origin $version
```

The tag triggers a fresh runtime build. After the native and portable-runtime tests pass, the build workflow creates or updates the GitHub Release with one asset. The public-asset matrix runs independently after the build:

```text
universal-scene-converter-windows-x64.zip
```

Do not publish release assets manually from an untested local build.

## Development principles

- Keep the frontend focused; format-specific behavior belongs upstream unless a narrow application-level guard is required.
- Fail loudly on missing SDK files, plugin registries, dependencies, or unsupported formats.
- Do not add DCC dependencies or Python to the consumer runtime.
- Preserve portable execution without environment variables.
- Treat runtime size as a tested product property, not merely a build statistic.
- Add a regression test for every compatibility fix or intentional behavior change.
