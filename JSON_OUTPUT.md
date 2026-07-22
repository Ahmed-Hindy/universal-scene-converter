# JSON output contract

Use `--json` when another process needs to consume Universal Scene Converter results without parsing human-readable text.

```powershell
.\bin\usdconvert.exe asset.fbx -o asset.usdc --json
```

The command writes exactly one JSON object followed by a newline to standard output. Universal Scene Converter does not mix progress or summary text into JSON output. Standard error may still contain diagnostics emitted directly by OpenUSD or a file-format plugin, so integrations should parse standard output and preserve standard error only for troubleshooting.

The process exit code remains authoritative. The same value is repeated in the top-level `exit_code` field.

## Schema

The portable package includes:

```text
schemas/usdconvert-result.schema.json
```

The current schema version is `1`. New optional fields may be added without changing `schema_version`. Removing a field, changing its type, or changing its meaning requires a new schema version.

## Successful conversion

```json
{
  "schema_version": 1,
  "tool": "usdconvert",
  "version": "0.6.4",
  "openusd_version": "0.25.11",
  "success": true,
  "exit_code": 0,
  "message": "",
  "jobs": [
    {
      "input": "C:/assets/asset.fbx",
      "output": "C:/assets/asset.usdc",
      "status": "success",
      "exit_code": 0,
      "message": "",
      "generated_files": [
        "C:/assets/asset.usdc"
      ]
    }
  ],
  "summary": {
    "succeeded": 1,
    "failed": 0
  }
}
```

Paths are absolute after job planning. `generated_files` contains every committed output, including format sidecars such as `.bin` files produced by glTF export.

## Partial batch failure

```json
{
  "schema_version": 1,
  "tool": "usdconvert",
  "version": "0.6.4",
  "openusd_version": "0.25.11",
  "success": false,
  "exit_code": 6,
  "message": "One or more batch items failed.",
  "jobs": [
    {
      "input": "C:/assets/good.fbx",
      "output": "C:/converted/good_converted.usdc",
      "status": "success",
      "exit_code": 0,
      "message": "",
      "generated_files": [
        "C:/converted/good_converted.usdc"
      ]
    },
    {
      "input": "C:/assets/missing.fbx",
      "output": "C:/converted/missing_converted.usdc",
      "status": "failed",
      "exit_code": 4,
      "message": "Could not open input layer: C:/assets/missing.fbx",
      "generated_files": []
    }
  ],
  "summary": {
    "succeeded": 1,
    "failed": 1
  }
}
```

For a command-line, planning, or runtime initialization error, `jobs` is empty and the top-level `message` explains the failure.

## Quiet mode

Use `--quiet` for a human-mode command that should produce no successful progress or summary output:

```powershell
.\bin\usdconvert.exe asset.fbx -o asset.usdc --quiet
```

Errors still use standard error and the normal exit codes. `--quiet` does not change JSON because `--json` is already non-interactive.

## Integration guidance

- Read the complete standard-output stream before parsing it as JSON.
- Check the process exit code and top-level `success` value.
- Use each job's `generated_files` list instead of predicting sidecar names.
- Treat unknown fields as optional forward-compatible additions.
- Do not parse human-readable error strings to determine error categories; use `exit_code`.
