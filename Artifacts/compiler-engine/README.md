# Compiler engine backup

Place the known-good compressed compiler engine at:

`Artifacts/compiler-engine/libXToolCompilerEngine.dylib.zip`

The one-shot XTool Mobile build automatically restores the engine from this ZIP when `.build/mobile-compiler-engine/package/libXToolCompilerEngine.dylib` is missing.

Expected extracted engine:

- file: `libXToolCompilerEngine.dylib`
- revision: `clang-lld-swiftmodules-v6`
- raw size: `159198544` bytes
- SHA-256: `5a5d08891aa712661eb602296e4d64acb41b67c0bbccb12c2cd9d9ab186aabfa`
- format: arm64 Mach-O `MH_DYLIB`

The recovery script refuses to install a backup that fails the Mach-O or SHA-256 checks.
