import Foundation

/// Produces the Swift frontend command line used by the on-device compiler.
///
/// XTool Mobile executes `swift-frontend` in-process, so the iPad build must not
/// depend on the SwiftDriver/TSCBasic SwiftPM products just to synthesize one
/// compile job. Keep this planner limited to frontend options that are already
/// exercised by `MobileProjectBuilder` on-device.
enum MobileSwiftDriverPlanner {
    static func frontendArguments(
        sourceURL: URL,
        objectURL: URL,
        sdkURL: URL,
        swiftResourceDirectory: URL,
        targetTriple: String,
        includeSearchPaths: [URL],
        clangBuiltinHeaders: URL?,
        moduleLoadMode: String = "prefer-serialized"
    ) throws -> [String] {
        let fm = FileManager.default
        let platformResources = swiftResourceDirectory
            .appendingPathComponent("iphoneos", isDirectory: true)

        let sdkVersion = try resolvedSDKVersion(sdkURL: sdkURL)
        let prebuiltModuleCache = platformResources
            .appendingPathComponent("xtool-prebuilt-modules", isDirectory: true)
            .appendingPathComponent(sdkVersion, isDirectory: true)
        let swiftModuleDirectory = prebuiltModuleCache
            .appendingPathComponent("Swift.swiftmodule", isDirectory: true)
        let swiftModuleCandidates = [
            swiftModuleDirectory.appendingPathComponent("arm64e-apple-ios.swiftmodule"),
            swiftModuleDirectory.appendingPathComponent("arm64-apple-ios.swiftmodule"),
        ]
        guard swiftModuleCandidates.contains(where: { fm.fileExists(atPath: $0.path) }) else {
            throw MobileSwiftDriverPlannerError.missingPrebuiltSwiftModule(swiftModuleCandidates)
        }

        // Never allow compiler caches to fall back to a home-directory path on
        // iOS. Keep them beside the probe output and namespace them by SDK/runtime.
        let cacheRoot = objectURL.deletingLastPathComponent()
        let cacheNamespace = "\(sdkVersion)-\(PreparedToolchain.expectedBundledRuntimeRevision)"
        let moduleCache = cacheRoot.appendingPathComponent(
            "ModuleCache-Frontend-\(cacheNamespace)",
            isDirectory: true
        )
        let sdkModuleCache = cacheRoot.appendingPathComponent(
            "SDKModuleCache-Frontend-\(cacheNamespace)",
            isDirectory: true
        )
        try fm.createDirectory(at: moduleCache, withIntermediateDirectories: true)
        try fm.createDirectory(at: sdkModuleCache, withIntermediateDirectories: true)

        // These arguments are consumed directly by the embedded frontend. They
        // intentionally mirror the successful project-build path rather than
        // relying on the Swift driver library at runtime.
        var arguments = [
            "-c",
            sourceURL.path,
            "-target", targetTriple,
            "-enable-objc-interop",
            "-enable-cross-import-overlays",
            "-Xllvm", "-aarch64-use-tbi",
            "-sdk", sdkURL.path,
            "-resource-dir", swiftResourceDirectory.path,
            "-module-cache-path", moduleCache.path,
            "-sdk-module-cache-path", sdkModuleCache.path,
            "-module-load-mode", moduleLoadMode,
            "-disable-modules-validate-system-headers",
            "-Rmodule-loading",
            "-Rmodule-interface-rebuild",
            "-prebuilt-module-cache-path", prebuiltModuleCache.path,
            "-I", platformResources.path,
        ]

        for path in includeSearchPaths {
            arguments += ["-I", path.path]
        }

        arguments += [
            "-Xcc", "-isysroot",
            "-Xcc", sdkURL.path,
            "-Xcc", "-fmodules-cache-path=\(moduleCache.path)",
        ]
        if let clangBuiltinHeaders {
            arguments += [
                "-Xcc", "-isystem",
                "-Xcc", clangBuiltinHeaders.path,
            ]
        }

        arguments += [
            "-parse-as-library",
            "-Onone",
            "-no-color-diagnostics",
            "-module-name", "XToolCompilerProbe",
            "-o", objectURL.path,
        ]
        return arguments
    }

    private static func resolvedSDKVersion(sdkURL: URL) throws -> String {
        let stem = sdkURL.deletingPathExtension().lastPathComponent
        let prefix = "iPhoneOS"
        if stem.hasPrefix(prefix) {
            let suffix = String(stem.dropFirst(prefix.count))
            if !suffix.isEmpty { return suffix }
        }

        let settingsURL = sdkURL.appendingPathComponent("SDKSettings.json")
        if let data = try? Data(contentsOf: settingsURL),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let version = object["Version"] as? String,
           !version.isEmpty {
            return version
        }
        throw MobileSwiftDriverPlannerError.missingSDKVersion(sdkURL)
    }
}

enum MobileSwiftDriverPlannerError: Error, CustomStringConvertible {
    // Retain the historical cases so diagnostics/call sites remain source-compatible.
    case compilerEngineNotBundled([URL])
    case compilerEngineLoadFailed(URL, String)
    case missingFrontendSymbol
    case noCompileJob
    case emptyCommandLine
    case unsupportedTool(String)
    case frontendFailed(Int32, String)
    case streamCaptureFailed(Int32)
    case missingSDKVersion(URL)
    case missingPrebuiltSwiftModule([URL])

    var description: String {
        switch self {
        case .compilerEngineNotBundled(let urls):
            return "Compiler planner could not find compiler engine: \(urls.map(\.path).joined(separator: ", "))"
        case .compilerEngineLoadFailed(let url, let message):
            return "Compiler planner could not load \(url.path): \(message)"
        case .missingFrontendSymbol:
            return "Compiler planner could not find xtool_swift_frontend_run"
        case .noCompileJob:
            return "Compiler planner did not produce a compile job"
        case .emptyCommandLine:
            return "Compiler planner produced an empty command line"
        case .unsupportedTool(let tool):
            return "Compiler planning requested unsupported tool: \(tool)"
        case .frontendFailed(let code, let diagnostics):
            return "Swift frontend planning query failed with exit \(code): \(diagnostics)"
        case .streamCaptureFailed(let value):
            return "Could not capture compiler frontend output (errno \(value))"
        case .missingSDKVersion(let sdkURL):
            return "Could not determine SDK version for prebuilt modules: \(sdkURL.path)"
        case .missingPrebuiltSwiftModule(let urls):
            return "Prepared runtime is missing XTool's upstream Swift module. Searched: \(urls.map(\.path).joined(separator: ", "))"
        }
    }
}
