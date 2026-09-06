import Foundation

/// A concrete Swift frontend invocation prepared for the in-process compiler bridge.
///
/// The normal mobile path is now planned by SwiftDriver. XTool no longer tries
/// to reproduce the driver's frontend argument synthesis by hand.
public struct MobileCompilerPlan: Sendable, Hashable {
    public let sourceURL: URL
    public let objectURL: URL
    public let sdkURL: URL
    public let swiftResourceDirectory: URL
    public let targetTriple: String
    public let arguments: [String]

    public init(
        sourceURL: URL,
        objectURL: URL,
        sdkURL: URL,
        swiftResourceDirectory: URL,
        targetTriple: String,
        arguments: [String]
    ) {
        self.sourceURL = sourceURL
        self.objectURL = objectURL
        self.sdkURL = sdkURL
        self.swiftResourceDirectory = swiftResourceDirectory
        self.targetTriple = targetTriple
        self.arguments = arguments
    }

    /// Writes the normal-SDK Swift probe used by the iPad IDE and asks the real
    /// Swift 6.3.2 driver to create the frontend job.
    ///
    /// This mirrors the host `swiftc` route that already compiles successfully
    /// against the same iPhoneOS 26.5 SDK. SwiftDriver performs all frontend
    /// option synthesis; XTool then executes that job through performFrontend().
    public static func helloWorld(
        toolchain: PreparedToolchain,
        workspace: URL,
        deploymentTarget: String = "16.0",
        fileManager: FileManager = .default
    ) throws -> Self {
        let configuration = try toolchain.mobileSwiftSDKConfiguration(
            fileManager: fileManager
        )

        try fileManager.createDirectory(
            at: workspace,
            withIntermediateDirectories: true
        )

        let source = workspace.appendingPathComponent("Hello.swift")
        let object = workspace.appendingPathComponent("Hello.o")
        let target = "arm64-apple-ios\(deploymentTarget)"

        let sourceText = """
        public func xtoolHello() -> Int {
            return 42
        }
        """
        try Data(sourceText.utf8).write(to: source, options: .atomic)
        try? fileManager.removeItem(at: object)

        let arguments = try MobileSwiftDriverPlanner.frontendArguments(
            sourceURL: source,
            objectURL: object,
            sdkURL: configuration.sdkURL,
            swiftResourceDirectory: configuration.swiftResourceDirectory,
            targetTriple: target,
            includeSearchPaths: configuration.includeSearchPaths,
            clangBuiltinHeaders: configuration.clangBuiltinHeaders
        )

        return Self(
            sourceURL: source,
            objectURL: object,
            sdkURL: configuration.sdkURL,
            swiftResourceDirectory: configuration.swiftResourceDirectory,
            targetTriple: target,
            arguments: arguments
        )
    }

    /// Keeps the original stdlib-free probe available as a low-level diagnostic.
    public static func stdlibFreeBootstrap(
        toolchain: PreparedToolchain,
        workspace: URL,
        deploymentTarget: String = "16.0",
        fileManager: FileManager = .default
    ) throws -> Self {
        try toolchain.validate(fileManager: fileManager)
        let sdk = try toolchain.iPhoneOSSDK(fileManager: fileManager)

        try fileManager.createDirectory(
            at: workspace,
            withIntermediateDirectories: true
        )
        let moduleCache = workspace.appendingPathComponent("ModuleCache", isDirectory: true)
        let sdkModuleCache = workspace.appendingPathComponent("SDKModuleCache", isDirectory: true)
        try fileManager.createDirectory(at: moduleCache, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: sdkModuleCache, withIntermediateDirectories: true)

        let source = workspace.appendingPathComponent("Bootstrap.swift")
        let object = workspace.appendingPathComponent("Bootstrap.o")
        let resourceDirectory = toolchain.toolchainDirectory
            .appendingPathComponent("usr/lib/swift", isDirectory: true)
        let target = "arm64-apple-ios\(deploymentTarget)"

        try Data("public func xtoolCompilerBootstrapProbe() {}\n".utf8)
            .write(to: source, options: .atomic)
        try? fileManager.removeItem(at: object)

        let arguments = [
            "-c",
            "-parse-stdlib",
            "-primary-file", source.path,
            "-target", target,
            "-sdk", sdk.path,
            "-resource-dir", resourceDirectory.path,
            "-module-cache-path", moduleCache.path,
            "-sdk-module-cache-path", sdkModuleCache.path,
            "-module-name", "XToolCompilerBootstrapProbe",
            "-o", object.path,
        ]

        return Self(
            sourceURL: source,
            objectURL: object,
            sdkURL: sdk,
            swiftResourceDirectory: resourceDirectory,
            targetTriple: target,
            arguments: arguments
        )
    }
}

public enum MobileCompilerBridgeContract {
    public static let backendName = "SwiftDriver -> FrontendTool / performFrontend"
    public static let executionModel = "driver-planned in-process AOT"
}
