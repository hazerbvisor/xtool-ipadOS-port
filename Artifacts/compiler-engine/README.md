# Compiler engine backup

The preferred self-contained backup lives at:

`Artifacts/compiler-engine/libXToolCompilerEngine.dylib.zip`

When `.build/mobile-compiler-engine/package/libXToolCompilerEngine.dylib` is missing, `scripts/build-xtool-mobile-one-shot.sh` automatically calls the recovery helper. The helper tries this repository ZIP first, verifies it, restores the dylib and revision stamp, and skips the LLVM/Clang compiler-engine rebuild.

Expected extracted engine:

- file: `libXToolCompilerEngine.dylib`
- revision: `clang-lld-swiftmodules-v6`
- raw size: `159198544` bytes
- SHA-256: `5a5d08891aa712661eb602296e4d64acb41b67c0bbccb12c2cd9d9ab186aabfa`
- format: arm64 Mach-O `MH_DYLIB`

The recovery script refuses to install a backup that fails the Mach-O or SHA-256 checks.

If the repository ZIP is absent, recovery falls back to known-good XTool `.ipa` files under `Artifacts/`.
