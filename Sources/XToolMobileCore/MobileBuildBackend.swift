import Foundation

/// A platform-neutral description of a build tool invocation.
///
/// Desktop xtool currently executes SwiftPM and compiler tools as subprocesses.
/// iOS/iPadOS cannot assume that model, so the mobile port talks to a backend
/// that executes compiler and linker functionality in-process instead.
public struct MobileBuildRequest: Sendable, Hashable {
    public enum Tool: String, Sendable, Hashable {
        case swiftPackage
        case swiftBuild
        case swiftFrontend
        case clang
        case linker
    }

    public var tool: Tool
    public var arguments: [String]
    public var workingDirectory: URL
    public var environment: [String: String]

    public init(
        tool: Tool,
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String] = [:]
    ) {
        self.tool = tool
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
    }
}

public struct MobileBuildResult: Sendable, Hashable {
    public var standardOutput: Data
    public var standardError: Data
    public var exitCode: Int32

    public init(
        standardOutput: Data = Data(),
        standardError: Data = Data(),
        exitCode: Int32 = 0
    ) {
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.exitCode = exitCode
    }

    public var succeeded: Bool { exitCode == 0 }
}

/// Compiler/build execution boundary for the iOS/iPadOS port.
///
/// Implementations are generic XTool Mobile backends. The first backend uses
/// the bundled Swift FrontendTool bridge; later backends add Clang, linking and
/// SwiftPM-compatible planning without changing the UI or packaging layers.
public protocol MobileBuildBackend: Sendable {
    func run(_ request: MobileBuildRequest) async throws -> MobileBuildResult
}

public enum MobileBuildBackendError: Error, CustomStringConvertible, Sendable {
    case backendUnavailable(String)
    case toolchainInvalid(String)
    case buildFailed(tool: MobileBuildRequest.Tool, exitCode: Int32)

    public var description: String {
        switch self {
        case .backendUnavailable(let reason):
            "Mobile build backend unavailable: \(reason)"
        case .toolchainInvalid(let reason):
            "Invalid mobile toolchain: \(reason)"
        case .buildFailed(let tool, let exitCode):
            "\(tool.rawValue) failed with exit code \(exitCode)"
        }
    }
}
