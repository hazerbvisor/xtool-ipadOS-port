import Foundation

/// A tiny C -> COFF object -> PE64 bootstrap used to prove that the embedded
/// Clang frontend and Windows COFF LLD driver can execute inside XTool Mobile.
///
/// The probe deliberately avoids Windows SDK headers, the CRT, and default
/// libraries. Its optimized entry point should be only `mov eax, 42; ret`,
/// which is also a useful compiler-produced input for WinPad.
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
        // Keep the existing toolchain gate because the bootstrap UI already
        // prepares the bundled compiler runtime through it. This Windows probe
        // itself does not consume Apple SDK headers or libraries.
        try toolchain.validate(fileManager: fileManager)
        let sdk = try toolchain.iPhoneOSSDK(fileManager: fileManager)
        try fileManager.createDirectory(
            at: workspace,
            withIntermediateDirectories: true
        )

        let source = workspace.appendingPathComponent("HelloWin.c")
        let object = workspace.appendingPathComponent("HelloWin.obj")
        let executable = workspace.appendingPathComponent("HelloWin.exe")
        let target = "x86_64-pc-windows-msvc"

        let sourceText = """
        int main(void) {
            return 42;
        }
        """
        try Data(sourceText.utf8).write(to: source, options: .atomic)
        try? fileManager.removeItem(at: object)
        try? fileManager.removeItem(at: executable)

        // CompilerInvocation::CreateFromArgs consumes cc1-style arguments; the
        // native bridge supplies no argv[0] and callers must not pass `-cc1`.
        // -O2 keeps this test intentionally tiny: `mov eax,42; ret` on x86-64.
        let clangArguments = [
            "-triple", target,
            "-emit-obj",
            "-O2",
            "-ffreestanding",
            "-fno-stack-protector",
            "-x", "c",
            source.path,
            "-o", object.path,
        ]

        // No Windows SDK, CRT, import libraries, or startup objects are needed.
        // lld-link enters `main` directly and emits a fixed AMD64 console PE64.
        let lldArguments = [
            "/machine:x64",
            "/subsystem:console",
            "/entry:main",
            "/nodefaultlib",
            "/fixed",
            "/out:\(executable.path)",
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
}
