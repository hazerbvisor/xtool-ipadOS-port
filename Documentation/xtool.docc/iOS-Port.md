# iOS/iPadOS Port Bootstrap

This fork is experimenting with running a stripped-down xtool build pipeline directly on iOS/iPadOS, with iPadOS as the primary development target.

## Goal

The first milestone is intentionally smaller than desktop xtool:

1. Import a prepared Darwin SDK/toolchain into the app container.
2. Open a SwiftPM project such as Haze.
3. Build an arm64 iOS executable using a mobile build backend.
4. Reuse xtool's portable packaging and signing logic where possible.
5. Produce an `.app`/`.ipa` on-device.

Once this works reliably for Haze, the backend can be expanded toward full SwiftPM/xtool compatibility.

## Why a build backend abstraction?

Desktop xtool currently uses `swift-subprocess` in `PackLib` and `XToolSupport` to run commands including `swift package`, `swift build`, `tar`, and other host tools. Normal iOS/iPadOS applications cannot assume the same arbitrary subprocess model.

`XToolMobileCore` therefore introduces `MobileBuildBackend`. Packaging/UI code can submit build requests without caring whether they are executed by:

- a desktop subprocess backend,
- an Haze-specific in-process compiler prototype, or
- a future complete in-process Swift/LLVM/SwiftPM backend.

This keeps the first prototype useful for the later full port instead of creating a separate throwaway build system.

## Prepared toolchain

`PreparedToolchain` models a pre-extracted Xcode/Darwin toolchain. The first prototype does not need to reproduce `xtool sdk` on the iPad. A toolchain prepared externally can be imported through the Files UI and copied into the application container.

The validator currently checks for:

- `Developer/Toolchains/XcodeDefault.xctoolchain`
- `usr/bin/swift-frontend`
- `Platforms/iPhoneOS.platform`
- an installed `iPhoneOS*.sdk`

## Runtime capability diagnostics

`MobilePlatformCapabilities` records basic process/device information and includes a harmless virtual-address-space reservation test. This is deliberately a runtime capability probe rather than an assumption that a particular provisioning entitlement is present.

## Porting sequence

### Stage 1: bootstrap

- Build `XToolMobileCore` for generic iOS in CI.
- Add an iPad SwiftUI shell.
- Import and validate a prepared toolchain.
- Add build logs and project selection.

### Stage 2: Haze compiler proof

- Implement the first `MobileBuildBackend`.
- Compile one Swift source file to arm64 object code.
- Link a minimal iOS Mach-O.
- Build Haze without invoking desktop `Process`/`swift-subprocess` APIs.

### Stage 3: packaging and signing

- Adapt reusable `PackLib` planning/packing code to depend on the backend abstraction instead of directly on `Subprocess`.
- Reuse `XKit` signing/provisioning code where it is iOS-compatible.
- Produce a signed IPA.

### Stage 4: full xtool port

- Replace `swift package describe/show-dependencies` subprocess calls with an in-process package graph provider.
- Support SwiftPM dependencies, resources, dynamic libraries, binary targets, and app extensions/widgets.
- Port remaining setup/install/launch flows where iOS permits them.

## Current known boundary

The largest remaining technical problem is compiler/tool execution. `PackLib/BuildSettings.swift`, `Planner.swift`, `Packer.swift`, and `ToolRegistry.swift` are currently tied directly to `swift-subprocess`. `XToolSupport/SDKBuilder.swift` also uses subprocess execution for SDK preparation.

Those files should not simply be copied into the mobile app unchanged. The next refactor is to move their tool execution behind a platform-neutral interface and keep the desktop subprocess implementation as one backend.
