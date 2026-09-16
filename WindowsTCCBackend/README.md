# XTool Windows TinyCC backend

This Phase 20 backend is deliberately separate from the main XTool Swift/Clang compiler engine.

It builds an **arm64 iOS dylib** that embeds TinyCC configured with the **x86_64 PE** code generator. The first bootstrap program uses `-nostdlib -Wl,-e,main`, so it needs no Windows SDK, CRT, import library, LLVM X86 backend, or lldCOFF.

Pinned upstream source:

- Repository: `https://github.com/TinyCC/tinycc`
- Commit: `0fb54300b56512754221d80adda85ddb9815bceb`
- Upstream library API: `libtcc.h`
- Upstream license: LGPL-2.1-or-later (see the upstream repository for the complete license text)

The build script clones the upstream source rather than copying TinyCC source into this repository.

Build:

```sh
bash scripts/build-mobile-windows-tcc.sh build
```

Expected expensive work is intentionally tiny: one TinyCC `ONE_SOURCE` C translation unit, one XTool bridge C translation unit, and one arm64 iOS dylib link.

The resulting library is:

```text
.build/mobile-windows-tcc/package/libXToolWindowsTCC.dylib
```

The initial runtime API compiles a UTF-8 C source string straight to an x86_64 PE64 executable. A later phase will load this dylib from XTool Mobile and export the resulting `HelloWin.exe` to Files for WinPad testing.
