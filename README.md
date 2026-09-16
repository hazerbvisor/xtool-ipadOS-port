# XTool Mobile — xtool for iOS & iPadOS

An experimental port of [xtool](https://github.com/xtool-org/xtool) that moves a real iOS app build pipeline **onto iPhone and iPad**.

This repository is no longer just the upstream desktop xtool project. Its main focus is **XTool Mobile**: a SwiftUI IDE and build environment that can edit projects, invoke an embedded Swift/Clang compiler stack in-process, link arm64 iOS applications, and export unsigned IPAs without launching Xcode or desktop compiler subprocesses on the device.

> [!IMPORTANT]
> XTool Mobile is an experimental developer tool, not a complete Xcode replacement. The on-device build path works from an explicit `xtool-mobile.json` build graph. Arbitrary SwiftPM resolution, code signing, several Apple build tools, and some advanced project types still require a host or an external tool.

## Project status

| Area | Current state |
| --- | --- |
| Swift editing / project workspace | Implemented |
| On-device Swift compilation | Implemented through the embedded compiler engine |
| On-device C / Objective-C / C++ compilation | Implemented through the embedded Clang frontend |
| arm64 iOS Mach-O linking | Implemented with in-process LLD |
| Multi-target mobile project graph | Implemented |
| Resources / custom Info.plist / frameworks / libraries | Supported by the mobile project format |
| Unsigned `.app` + `.ipa` packaging | Implemented |
| Persistent build logs / interrupted-build recovery | Implemented |
| Module cache | Implemented |
| GitHub repository import / pull | Implemented as snapshot-based sync, not a full Git client |
| ChatGPT / Codex assistant UI | Implemented as a client for a separately hosted Codex app-server |
| On-device code signing / provisioning | **Not performed by the mobile build pipeline** |
| Arbitrary `Package.swift` evaluation and dependency fetching | **Not yet available on-device** |
| SwiftPM plugins / macro executables | **Not yet available on-device** |
| Rebuilding Swift/LLVM itself on iPad | **Not supported** |
| Full Xcode project compatibility | **Not supported** |

## What XTool Mobile actually does

The mobile build path does not shell out to `swift`, `swiftc`, `swift-frontend`, Clang, or LLD executables. Normal iOS applications cannot rely on the desktop subprocess model used by upstream xtool, so this fork introduces an in-process compiler boundary.

```text
XToolMobileApp
      │
      ▼
XToolMobileCore
      │
      ├── project graph / build planning
      ├── SDK + runtime configuration
      ├── build logs + module cache
      └── IPA packaging
      │
      ▼
libXToolCompilerEngine.dylib
      │
      ├── Swift frontend
      ├── Clang frontend
      └── Mach-O LLD
      │
      ▼
arm64 iOS objects → linked app → Payload/<App>.app → unsigned IPA
```

The native compiler engine is deliberately separate from the SwiftUI app. Swift/LLVM is expensive to build, so a working `libXToolCompilerEngine.dylib` can be reused while the IDE and build-planning code are rebuilt much more quickly.

## On-device workflow

A normal mobile project workflow is:

1. Open or import a project containing `xtool-mobile.json`.
2. Edit Swift or supported native source files in the XTool Mobile workspace.
3. Choose **Build Unsigned IPA** or use `Command-B`.
4. XTool compiles targets in dependency order, links the executable, assembles the app bundle, copies resources, and packages `Payload/` as an IPA.
5. Export the unsigned IPA through Files/share sheet.
6. Sign/install it using your existing iOS signing workflow.

Each build gets its own output directory and persistent `build.log`. Compiler and linker stderr are captured to disk so an interrupted build can show the last recorded stage after XTool is reopened. Failed builds do not publish an IPA.

## Mobile project format

XTool Mobile currently builds a declared graph instead of evaluating arbitrary SwiftPM manifests on-device.

Example `xtool-mobile.json`:

```json
{
  "schemaVersion": 1,
  "name": "MyApp",
  "bundleIdentifier": "com.example.myapp",
  "deploymentTarget": "16.0",
  "executableTarget": "MyApp",
  "frameworks": ["SwiftUI", "UIKit", "Foundation"],
  "targets": [
    {
      "name": "Utilities",
      "sources": ["Sources/Utilities"],
      "parseAsLibrary": true
    },
    {
      "name": "MyApp",
      "sources": ["Sources/MyApp"],
      "dependencies": ["Utilities"]
    }
  ],
  "resources": [
    {
      "path": "Resources/message.txt",
      "destination": "message.txt"
    }
  ]
}
```

The mobile format also supports project-relative header search paths, Clang module maps, frontend Swift/Clang flags, extra link files, library/module search paths, frameworks, libraries, resources, a custom Info.plist, and app version metadata.

Swift targets emit a module and object file. Native `.c`, `.m`, `.mm`, `.cc`, `.cpp`, and `.cxx` files are compiled as separate objects. Dependency objects are then linked into the final application.

## SwiftPM projects

XTool Mobile does **not** currently evaluate arbitrary `Package.swift` files, download dependency graphs, execute build-tool plugins, or run macro executables on-device.

For an existing SwiftPM app, the supported path is to resolve/build it on a compatible host and export the real build graph into the mobile project format:

```bash
python3 scripts/prepare-mobile-project.py \
  --project /path/to/project \
  --product MyApp \
  --bundle-id com.example.myapp \
  --output /path/to/MyApp-Mobile \
  --zip
```

The exporter uses information from a successful host build instead of pretending to parse the SwiftPM manifest language itself. Swift modules can then be rebuilt on iPad while prepared native dependency objects and generated inputs remain frozen until the project is prepared again.

See [`docs/mobile-project-builds.md`](docs/mobile-project-builds.md) for the detailed project schema, SwiftPM export flow, runtime requirements, and current limitations.

## IDE features

XTool Mobile includes more than the compiler pipeline. The current workspace contains:

- Swift-oriented code editing with syntax highlighting, lexical suggestions, find/replace, project search, diagnostic underlines, split editors, and keyboard shortcuts.
- Project file/folder creation, rename/move, project trash with undo, build history, issue navigation, cache management, and IPA/log export.
- GitHub public repository import plus authenticated access using a fine-grained token or an optional OAuth device-flow configuration.
- Snapshot-based pulls that preserve local edits when possible and stop on detected local/remote conflicts.
- A ChatGPT/Codex assistant panel that can review selected project files and propose changes for local approval.

The GitHub integration is **not a full Git client**: it does not push, merge branches, resolve submodules, or materialize Git LFS content.

The assistant also does **not** embed Codex inside the iPad app. It speaks the Codex app-server protocol to a separately running trusted host. Proposed edits are reviewed and applied locally by XTool Mobile.

See [`docs/mobile-ide-features.md`](docs/mobile-ide-features.md) for connection setup, security boundaries, GitHub behavior, and UI limits.

## Compiler engine

The native compiler engine lives under [`CompilerEngine/`](CompilerEngine/).

Its purpose is to compile inside the XTool Mobile process through a small C ABI. The mobile build deliberately excludes desktop-only or unnecessary compiler components such as SourceKit, REPL/JIT support, tests, documentation, examples, and non-AArch64 LLVM backends.

A host-side one-shot build is available:

```bash
bash scripts/build-xtool-mobile-one-shot.sh
```

The script prepares/builds the compiler engine when needed, builds XTool Mobile, prepares the bundled Darwin runtime, runs the mobile project checks, and packages an **unsigned** IPA.

The combined host build log is written to:

```text
.build/xtool-mobile-one-shot.log
```

More compiler-engine details are in [`CompilerEngine/README.md`](CompilerEngine/README.md).

## SDK and runtime

The mobile compiler requires a prepared Darwin/iPhoneOS SDK and Swift runtime layout. `XToolMobileCore` contains the SDK/runtime configuration, validation, import/extraction, and path relocation logic needed by the on-device compiler.

The project intentionally treats SDK/runtime preparation separately from compiling user source. An installed compiler engine and prepared mobile runtime can be reused between normal XTool Mobile rebuilds.

## Experimental Windows backend

This repository also contains a **separate experimental Windows toolchain path** under [`WindowsTCCBackend/`](WindowsTCCBackend/).

That backend embeds TinyCC in an arm64 iOS dylib while using TinyCC's x86-64 PE code generator. Its bootstrap path is designed to compile a small UTF-8 C source string into an x86-64 PE64 executable without requiring a Windows SDK, CRT, LLVM X86 backend, or `lldCOFF`.

This is not the main iOS app compiler and should not be confused with the Swift/Clang/LLD mobile build engine. It is an experimental subsystem intended for interoperability/testing work such as WinPad.

## What is still host-side or external?

The important current boundaries are:

- **Signing:** XTool Mobile exports an unsigned IPA. It does not call `codesign` or provision the generated app in the mobile build path.
- **SwiftPM resolution:** dependency fetching, arbitrary manifest evaluation, build-tool plugins, and macro executables still need host preparation.
- **Apple build tools:** asset catalogs, storyboards, Metal shader compilation, and similar Xcode toolchain steps must currently be prepared externally when required.
- **Compiler-engine rebuilds:** the iPad app reuses the installed engine; it does not build Swift/LLVM with CMake/Ninja on-device.
- **Full self-hosting:** the repo contains an experimental path for rebuilding XTool's Swift app layer on-device with prepared native dependencies, but that is not the same as rebuilding the compiler toolchain itself.

## Repository layout

```text
Sources/XToolMobileApp/     SwiftUI IDE and workspace UI
Sources/XToolMobileCore/    mobile build graph, compiler bridge, SDK/runtime,
                            packaging, recovery and workspace support
CompilerEngine/             embedded Swift/Clang/LLVM compiler boundary
Artifacts/compiler-engine/  reusable packaged compiler-engine artifact
WindowsTCCBackend/          experimental TinyCC x86-64 PE backend
WindowsBackend/             experimental Windows-related native backend work
docs/                       mobile build + IDE documentation
Documentation/              upstream/DocC documentation and port notes
scripts/                    host bootstrap, runtime, compiler and packaging tools
xtool-mobile.json           XTool Mobile's own mobile build manifest
```

## Validation

Portable project/build checks can be run with:

```bash
bash scripts/test-mobile-project.sh
```

These checks cover build graph behavior, packaging, linker/runtime discovery, failure handling, path relocation, and project preparation logic. They do **not** replace real device validation of SwiftUI/UIKit compilation, authentication flows, external signing, installation, and launch.

## Relationship to upstream xtool

This fork keeps significant parts of upstream xtool, including reusable packaging, signing/provisioning and Apple Developer Services code, while developing a separate mobile architecture for work that desktop xtool normally performs through subprocesses.

The long-term direction is to make more of xtool's project/build functionality usable directly on iOS/iPadOS without pretending that iOS exposes the same host environment as Linux or macOS.

For the original desktop project and its documentation, see [xtool-org/xtool](https://github.com/xtool-org/xtool).

## License

See [`LICENSE.md`](LICENSE.md). Third-party components retain their own licenses; for example, the experimental TinyCC backend uses TinyCC under its upstream LGPL-2.1-or-later license.