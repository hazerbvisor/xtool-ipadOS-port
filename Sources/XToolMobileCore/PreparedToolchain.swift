import Foundation

/// A prepared Darwin SDK/runtime tree imported into the app container.
///
/// The mobile port intentionally separates the target SDK from the compiler
/// implementation. Linux-hosted `swift`, `swiftc`, and `swift-frontend`
/// executables cannot run on iOS/iPadOS, so the imported tree only needs to
/// provide the Apple platform SDK and target runtime files. The compiler bridge
/// will be embedded into xtool and invoked in-process.
public struct PreparedToolchain: Sendable, Hashable {
    /// Keep this in sync with scripts/prepare-mobile-runtime.sh and the one-shot
    /// runtime cache stamp. Bundled-runtime discovery uses it to avoid silently
    /// reusing an older extracted SDK/runtime after an app update.
    public static let expectedBundledRuntimeRevision =
        "swift-sdk-v6-validated-prebuilt-stdlib"

    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// Accept either the artifact-bundle root or the Developer folder itself.
    public var developerDirectory: URL {
        if root.lastPathComponent == "Developer" {
            return root
        }
        return root.appendingPathComponent("Developer", isDirectory: true)
    }

    public var toolchainDirectory: URL {
        developerDirectory.appendingPathComponent(
            "Toolchains/XcodeDefault.xctoolchain",
            isDirectory: true
        )
    }

    /// Informational only. A frontend found here must not be assumed runnable on
    /// iOS; the mobile compiler path is an embedded in-process bridge.
    public var swiftFrontend: URL {
        toolchainDirectory.appendingPathComponent("usr/bin/swift-frontend")
    }

    public var hasBundledSwiftFrontend: Bool {
        FileManager.default.fileExists(atPath: swiftFrontend.path)
    }

    public var iPhoneOSPlatform: URL {
        developerDirectory.appendingPathComponent("Platforms/iPhoneOS.platform", isDirectory: true)
    }

    public var runtimeRevisionURL: URL {
        root.appendingPathComponent("XToolRuntimeRevision.txt")
    }

    private var isXToolBundledRuntimeRoot: Bool {
        root.lastPathComponent == "XToolMobileRuntime"
    }

    public func runtimeRevision(fileManager: FileManager = .default) -> String? {
        guard fileManager.fileExists(atPath: runtimeRevisionURL.path),
              let text = try? String(contentsOf: runtimeRevisionURL, encoding: .utf8) else {
            return nil
        }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Validate the imported Darwin target SDK/runtime tree.
    ///
    /// This deliberately does NOT require `swift-frontend`. The Android xtool
    /// Darwin SDK keeps the Linux host compiler under /opt/swift while the
    /// artifact bundle provides the iPhoneOS target SDK/runtime data.
    ///
    /// External SDK folders remain revision-agnostic. XTool's own extracted
    /// Application Support runtime always uses the fixed `XToolMobileRuntime`
    /// directory name, so require both the current revision and the generated
    /// upstream Swift stdlib module. This makes discovery reject an old,
    /// truncated, or partially extracted runtime before SwiftDriver planning.
    public func validate(fileManager: FileManager = .default) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: developerDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw MobileBuildBackendError.toolchainInvalid("Developer directory is missing")
        }

        guard fileManager.fileExists(atPath: iPhoneOSPlatform.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw MobileBuildBackendError.toolchainInvalid("iPhoneOS.platform is missing")
        }

        if isXToolBundledRuntimeRoot {
            guard runtimeRevision(fileManager: fileManager)
                    == Self.expectedBundledRuntimeRevision else {
                throw MobileBuildBackendError.toolchainInvalid(
                    "Bundled runtime revision is stale or missing"
                )
            }
        } else if fileManager.fileExists(atPath: runtimeRevisionURL.path),
                  runtimeRevision(fileManager: fileManager)
                    != Self.expectedBundledRuntimeRevision {
            // A manually imported tree that explicitly carries an XTool stamp
            // should not silently masquerade as a compatible current runtime.
            throw MobileBuildBackendError.toolchainInvalid(
                "XTool runtime revision is stale"
            )
        }

        let sdk = try iPhoneOSSDK(fileManager: fileManager)
        if isXToolBundledRuntimeRoot {
            try validateBundledSwiftModule(
                sdk: sdk,
                fileManager: fileManager
            )
        }
    }

    /// Stronger validation for callers that explicitly know they are handling
    /// XTool's bundled archive. The canonical Application Support runtime is
    /// already fully checked by `validate()`; this method also works for a
    /// bundled runtime staged under a different directory name.
    public func validateBundledRuntime(fileManager: FileManager = .default) throws {
        try validate(fileManager: fileManager)

        guard runtimeRevision(fileManager: fileManager)
                == Self.expectedBundledRuntimeRevision else {
            throw MobileBuildBackendError.toolchainInvalid(
                "Bundled runtime revision is stale or missing"
            )
        }

        let sdk = try iPhoneOSSDK(fileManager: fileManager)
        try validateBundledSwiftModule(
            sdk: sdk,
            fileManager: fileManager
        )
    }

    private func validateBundledSwiftModule(
        sdk: URL,
        fileManager: FileManager
    ) throws {
        let sdkStem = sdk.deletingPathExtension().lastPathComponent
        let sdkPrefix = "iPhoneOS"
        var sdkVersion = sdkStem.hasPrefix(sdkPrefix)
            ? String(sdkStem.dropFirst(sdkPrefix.count))
            : ""

        if sdkVersion.isEmpty,
           let data = try? Data(contentsOf: sdk.appendingPathComponent("SDKSettings.json")),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let value = object["Version"] as? String {
            sdkVersion = value
        }

        guard !sdkVersion.isEmpty else {
            throw MobileBuildBackendError.toolchainInvalid(
                "Bundled runtime SDK version could not be determined"
            )
        }

        let prebuiltSwift = toolchainDirectory
            .appendingPathComponent("usr/lib/swift/iphoneos/xtool-prebuilt-modules", isDirectory: true)
            .appendingPathComponent(sdkVersion, isDirectory: true)
            .appendingPathComponent("Swift.swiftmodule", isDirectory: true)
        let candidates = [
            prebuiltSwift.appendingPathComponent("arm64e-apple-ios.swiftmodule"),
            prebuiltSwift.appendingPathComponent("arm64-apple-ios.swiftmodule"),
        ]
        guard candidates.contains(where: { fileManager.fileExists(atPath: $0.path) }) else {
            throw MobileBuildBackendError.toolchainInvalid(
                "Bundled upstream Swift stdlib module is missing"
            )
        }
    }

    /// Finds the newest installed iPhoneOS SDK in the prepared Darwin tree.
    public func iPhoneOSSDK(fileManager: FileManager = .default) throws -> URL {
        let sdkDirectory = iPhoneOSPlatform.appendingPathComponent("Developer/SDKs", isDirectory: true)
        let contents = try fileManager.contentsOfDirectory(
            at: sdkDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        guard let sdk = contents
            .filter({ $0.pathExtension == "sdk" && $0.lastPathComponent.hasPrefix("iPhoneOS") })
            .sorted(by: { $0.lastPathComponent > $1.lastPathComponent })
            .first else {
            throw MobileBuildBackendError.toolchainInvalid("No iPhoneOS SDK was found")
        }
        return sdk
    }
}
