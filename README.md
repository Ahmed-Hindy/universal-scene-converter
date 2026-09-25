# Universal Scene Converter

A standalone CLI tool for converting OpenUSD, FBX, OBJ, STL, and glTF files, built on [Adobe's USD conversion plugins](https://github.com/adobe/USD-Fileformat-plugins).

<p align="center">
  <img src="docs/images/universal-scene-converter-format-cycle.png" alt="USD conversion cycle between FBX, PLY, OBJ, and glTF" width="220">
</p>

https://github.com/user-attachments/assets/ef95c886-8797-4bf7-aa7c-daea22022acd

## Documentation

- **[USAGE.md](USAGE.md)** — Command examples, batch conversion, exit codes, and known limitations
- **[JSON_OUTPUT.md](JSON_OUTPUT.md)** — JSON output contract for automation
- **[DEVELOPMENT.md](DEVELOPMENT.md)** — Build instructions, CI, and development workflows

## Supported formats

All listed formats can be used as input or output:

| Format | Extensions |
|---|---|
| OpenUSD | `.usd`, `.usda`, `.usdc`, `.usdz` |
| Autodesk FBX | `.fbx` |
| Wavefront OBJ | `.obj` |
| STL | `.stl` |
| glTF | `.gltf`, `.glb` |

## License

[BSD 3-Clause License](LICENSE)
