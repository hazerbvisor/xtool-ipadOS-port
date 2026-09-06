# XTool Mobile Compiler Engine

This directory is the native compiler boundary for the iOS/iPadOS port of xtool.

## Goal

Compile Swift source to arm64 iOS object files **inside the XTool Mobile process** without launching `swift`, `swiftc`, or `swift-frontend` as child processes.

```text
XToolMobileApp
    ↓
XToolMobileCore
    ↓ C ABI
libXToolCompilerEngine.dylib
    ↓
swift::performFrontend(...)
    ↓
arm64 iOS .o
```

The dylib is intentionally separate from the app executable. Swift/LLVM is expensive to build, while XTool Mobile UI/planning code is cheap. Once the engine has been produced it can be reused across normal app rebuilds.

## ABI

`include/XToolCompilerEngine.h` exports only:

```c
int32_t xtool_swift_frontend_run(int32_t argc, const char *const *argv);
const char *xtool_compiler_engine_version(void);
```

`XToolMobileCore.MobileCompilerEngine` loads these symbols from `Frameworks/libXToolCompilerEngine.dylib` with `dlopen`/`dlsym`.

## Build shape

The engine is configured as the last LLVM external project:

```text
cmark → swift → xtoolcompiler
```

`XToolCompilerEngine` links against the CMake target `swiftFrontendTool`. CMake therefore resolves the Swift, Clang and LLVM static dependency closure into the final dylib for us.

The mobile configuration deliberately disables:

- tests, docs, examples and benchmarks
- SourceKit
- Swift standard-library rebuilding
- compiler command-line executables
- immediate mode / REPL / JIT libraries
- non-AArch64 LLVM backends

This engine is for AOT compilation only.

## Output

```text
.build/mobile-compiler-engine/package/libXToolCompilerEngine.dylib
```

`scripts/package-mobile-app.sh` automatically places that file in:

```text
Payload/XToolMobileApp.app/Frameworks/libXToolCompilerEngine.dylib
```

The resulting IPA remains unsigned and is intended to be signed afterward by the user's normal iOS signing workflow.

## One-command bootstrap

```bash
bash scripts/build-xtool-mobile-one-shot.sh
```

This configures/builds the compiler engine when necessary, builds XTool Mobile, prepares the bundled Darwin runtime if missing, and creates the unsigned IPA.

On failure it saves one combined log at:

```text
.build/xtool-mobile-one-shot.log
```
