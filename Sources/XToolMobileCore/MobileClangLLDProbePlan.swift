import Foundation

/// A tiny C -> object -> Mach-O bootstrap used to prove that the embedded
/// Clang frontend and Mach-O LLD driver can both execute inside XTool Mobile.
///
/// The probe deliberately avoids SDK headers and libc calls. That keeps it
/// independent from the Swift standard-library compatibility work and exercises
/// only native C code generation plus Darwin linking.
public struct MobileClangLLDProbePlan: Sendable, Hashable {
    public let sourceURL: URL
    public let objectURL: URL
    public let executableURL: URL
    public let sdkURL: URL
    public let targetTriple: String
    public let clangArguments: [String]
    public let lldArguments: [String]

    public static func helloC(
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

        let source = workspace.appendingPathComponent("Hello.c")
        let object = workspace.appendingPathComponent("HelloC.o")
        let executable = workspace.appendingPathComponent("HelloC")
        let target = "arm64-apple-ios\(deploymentTarget)"
        let sdkVersion = parsedSDKVersion(from: sdk) ?? deploymentTarget

        let sourceText = """
        int main(void) {
            return 0;
        }
        """
        try Data(sourceText.utf8).write(to: source, options: .atomic)
        try? fileManager.removeItem(at: object)
        try? fileManager.removeItem(at: executable)

        // CompilerInvocation::CreateFromArgs consumes cc1-style arguments; the
        // native bridge supplies no argv[0] and callers must not pass `-cc1`.
        let clangArguments = [
            "-triple", target,
            "-emit-obj",
            "-x", "c",
            source.path,
            "-o", object.path,
        ]

        // The native LLD bridge supplies argv[0] (`ld64.lld`). This object has
        // no external references, so the link does not need libSystem or any
        // startup object; an explicit _main entry point is sufficient to prove
        // that LLD can emit an arm64 iOS Mach-O executable.
        let lldArguments = [
            "-arch", "arm64",
            "-platform_version", "ios", deploymentTarget, sdkVersion,
            "-syslibroot", sdk.path,
            "-e", "_main",
            "-o", executable.path,
            object.path,
        ]

        return Self(
            sourceURL: source,
            objectURL: object,
            executableURL: executable,
            sdkURL: sdk,
            targetTriple: target,
            clangArguments: clangArguments,
            lldArguments: lldArguments
        )
    }

    private static func parsedSDKVersion(from sdkURL: URL) -> String? {
        let base = sdkURL.deletingPathExtension().lastPathComponent
        let prefix = "iPhoneOS"
        guard base.hasPrefix(prefix) else { return nil }
        let version = String(base.dropFirst(prefix.count))
        return version.isEmpty ? nil : version
    }
}
