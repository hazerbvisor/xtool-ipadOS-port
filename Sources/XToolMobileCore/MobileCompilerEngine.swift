import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Loads the main XTool compiler engine and, when bundled, the isolated Windows
/// backend. Swift and Clang stay in the existing engine. Windows C/C++ jobs are
/// first emitted as LLVM bitcode by that already-built Clang, then the optional
/// backend lowers the bitcode with LLVM X86 and links COFF/PE with lldCOFF.
public final class MobileCompilerEngine: MobileProjectCompiler, @unchecked Sendable {
    public static let dylibName = "libXToolCompilerEngine.dylib"
    public static let windowsDylibName = "libXToolWindowsBackend.dylib"

    private typealias NativeRun = @convention(c) (
        Int32,
        UnsafePointer<UnsafePointer<CChar>?>?
    ) -> Int32
    private typealias VersionRead = @convention(c) () -> UnsafePointer<CChar>?

    private let handle: UnsafeMutableRawPointer
    private let windowsHandle: UnsafeMutableRawPointer?
    private let runFrontendFunction: NativeRun
    private let runClangFunction: NativeRun?
    private let runWindowsCodegenFunction: NativeRun?
    private let runLLDMachOFunction: NativeRun?
    private let runLLDCOFFFunction: NativeRun?
    public let location: URL
    public let windowsLocation: URL?
    public let version: String
    public let windowsVersion: String?

    private init(
        handle: UnsafeMutableRawPointer,
        windowsHandle: UnsafeMutableRawPointer?,
        runFrontendFunction: @escaping NativeRun,
        runClangFunction: NativeRun?,
        runWindowsCodegenFunction: NativeRun?,
        runLLDMachOFunction: NativeRun?,
        runLLDCOFFFunction: NativeRun?,
        location: URL,
        windowsLocation: URL?,
        version: String,
        windowsVersion: String?
    ) {
        self.handle = handle
        self.windowsHandle = windowsHandle
        self.runFrontendFunction = runFrontendFunction
        self.runClangFunction = runClangFunction
        self.runWindowsCodegenFunction = runWindowsCodegenFunction
        self.runLLDMachOFunction = runLLDMachOFunction
        self.runLLDCOFFFunction = runLLDCOFFFunction
        self.location = location
        self.windowsLocation = windowsLocation
        self.version = version
        self.windowsVersion = windowsVersion
    }

    deinit {
        if let windowsHandle {
            dlclose(windowsHandle)
        }
        dlclose(handle)
    }

    public var supportsClangFrontend: Bool {
        runClangFunction != nil
    }

    /// Compatibility name retained for callers added during the first Phase 20
    /// split. Windows compilation now means main-engine Clang + X86 codegen.
    public var supportsWindowsClang: Bool {
        runClangFunction != nil && runWindowsCodegenFunction != nil
    }

    public var supportsWindowsCodegen: Bool {
        runWindowsCodegenFunction != nil
    }

    public var supportsMachOLLD: Bool {
        runLLDMachOFunction != nil
    }

    public var supportsCOFFLLD: Bool {
        runLLDCOFFFunction != nil
    }

    public static func loadFromApplicationBundle(
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) throws -> MobileCompilerEngine {
        let candidates = bundleCandidates(bundle: bundle)
        guard let location = candidates.first(where: {
            fileManager.fileExists(atPath: $0.path)
        }) else {
            throw MobileCompilerEngineError.notBundled(candidates)
        }

        dlerror()
        guard let handle = dlopen(location.path, RTLD_NOW | RTLD_LOCAL) else {
            let message = dlerror().map { String(cString: $0) } ?? "unknown dlopen error"
            throw MobileCompilerEngineError.loadFailed(location, message)
        }

        var loadedWindowsHandle: UnsafeMutableRawPointer?
        do {
            guard let runSymbol = dlsym(handle, "xtool_swift_frontend_run") else {
                throw MobileCompilerEngineError.missingSymbol("xtool_swift_frontend_run")
            }
            let runFrontend = unsafeBitCast(runSymbol, to: NativeRun.self)

            let runClang: NativeRun? = dlsym(handle, "xtool_clang_frontend_run").map {
                unsafeBitCast($0, to: NativeRun.self)
            }
            let runLLDMachO: NativeRun? = dlsym(handle, "xtool_lld_macho_run").map {
                unsafeBitCast($0, to: NativeRun.self)
            }

            // Backward compatibility: older combined engines may still export
            // xtool_lld_coff_run. Prefer the separate Windows backend when it is
            // present, but keeping this fallback lets older packaged engines run.
            var runLLDCOFF: NativeRun? = dlsym(handle, "xtool_lld_coff_run").map {
                unsafeBitCast($0, to: NativeRun.self)
            }
            var runWindowsCodegen: NativeRun?
            var windowsLocation: URL?
            var windowsVersion: String?

            let windowsCandidates = windowsBundleCandidates(bundle: bundle)
            if let candidate = windowsCandidates.first(where: {
                fileManager.fileExists(atPath: $0.path)
            }) {
                dlerror()
                guard let candidateHandle = dlopen(candidate.path, RTLD_NOW | RTLD_LOCAL) else {
                    let message = dlerror().map { String(cString: $0) } ?? "unknown dlopen error"
                    throw MobileCompilerEngineError.loadFailed(candidate, message)
                }
                loadedWindowsHandle = candidateHandle
                windowsLocation = candidate

                guard let codegenSymbol = dlsym(candidateHandle, "xtool_windows_codegen_run") else {
                    throw MobileCompilerEngineError.missingSymbol("xtool_windows_codegen_run")
                }
                guard let windowsCOFFSymbol = dlsym(candidateHandle, "xtool_windows_lld_coff_run") else {
                    throw MobileCompilerEngineError.missingSymbol("xtool_windows_lld_coff_run")
                }
                runWindowsCodegen = unsafeBitCast(codegenSymbol, to: NativeRun.self)
                runLLDCOFF = unsafeBitCast(windowsCOFFSymbol, to: NativeRun.self)

                if let versionSymbol = dlsym(candidateHandle, "xtool_windows_backend_version") {
                    let readVersion = unsafeBitCast(versionSymbol, to: VersionRead.self)
                    if let value = readVersion() {
                        windowsVersion = String(cString: value)
                    }
                }
            }

            var version = "unknown"
            if let versionSymbol = dlsym(handle, "xtool_compiler_engine_version") {
                let readVersion = unsafeBitCast(versionSymbol, to: VersionRead.self)
                if let value = readVersion() {
                    version = String(cString: value)
                }
            }

            return MobileCompilerEngine(
                handle: handle,
                windowsHandle: loadedWindowsHandle,
                runFrontendFunction: runFrontend,
                runClangFunction: runClang,
                runWindowsCodegenFunction: runWindowsCodegen,
                runLLDMachOFunction: runLLDMachO,
                runLLDCOFFFunction: runLLDCOFF,
                location: location,
                windowsLocation: windowsLocation,
                version: version,
                windowsVersion: windowsVersion
            )
        } catch {
            if let loadedWindowsHandle {
                dlclose(loadedWindowsHandle)
            }
            dlclose(handle)
            throw error
        }
    }

    public func run(_ plan: MobileCompilerPlan) throws -> MobileBuildResult {
        try runSwiftFrontend(arguments: plan.arguments)
    }

    public func runSwiftFrontend(arguments: [String], diagnosticsURL: URL? = nil) throws -> MobileBuildResult {
        var frontendArguments = arguments
        if frontendArguments.first == "-frontend" {
            frontendArguments.removeFirst()
        }

        return try runNative(
            arguments: frontendArguments,
            function: runFrontendFunction,
            diagnosticsURL: diagnosticsURL
        )
    }

    /// Runs ordinary iOS Clang jobs directly. Windows jobs use the same already
    /// bundled Clang frontend to emit LLVM bitcode, then hand that bitcode to the
    /// much smaller X86-only Windows backend for machine-code emission.
    public func runClangFrontend(arguments: [String], diagnosticsURL: URL? = nil) throws -> MobileBuildResult {
        var frontendArguments = arguments
        if frontendArguments.first == "-cc1" {
            frontendArguments.removeFirst()
        }

        guard let runClangFunction else {
            throw MobileCompilerEngineError.missingSymbol("xtool_clang_frontend_run")
        }

        guard Self.isWindowsClangJob(frontendArguments) else {
            return try runNative(
                arguments: frontendArguments,
                function: runClangFunction,
                diagnosticsURL: diagnosticsURL
            )
        }

        guard let runWindowsCodegenFunction else {
            throw MobileCompilerEngineError.missingSymbol("xtool_windows_codegen_run")
        }
        guard let objectPath = Self.argumentValue(after: "-o", in: frontendArguments) else {
            throw MobileCompilerEngineError.invalidWindowsJob("missing -o output path")
        }

        let triple = Self.windowsTriple(in: frontendArguments) ?? "x86_64-pc-windows-msvc"
        let bitcodePath = objectPath + ".xtool.bc"
        var bitcodeArguments = frontendArguments

        // The existing Clang frontend does not need an X86 machine backend to
        // parse C/C++ and produce LLVM IR. Avoid target-specific optimization
        // passes here; the isolated X86 TargetMachine performs final lowering.
        bitcodeArguments.removeAll { argument in
            argument == "-emit-obj" ||
            argument == "-emit-llvm" ||
            argument == "-emit-llvm-bc" ||
            argument.hasPrefix("-O")
        }
        bitcodeArguments.append("-emit-llvm-bc")
        bitcodeArguments.append("-disable-llvm-passes")

        if let outputIndex = bitcodeArguments.firstIndex(of: "-o"),
           bitcodeArguments.indices.contains(outputIndex + 1) {
            bitcodeArguments[outputIndex + 1] = bitcodePath
        } else {
            bitcodeArguments.append(contentsOf: ["-o", bitcodePath])
        }

        let clangResult = try runNative(
            arguments: bitcodeArguments,
            function: runClangFunction,
            diagnosticsURL: diagnosticsURL
        )
        guard clangResult.succeeded else {
            return clangResult
        }

        defer { try? FileManager.default.removeItem(atPath: bitcodePath) }
        let codegenResult = try runNative(
            arguments: [bitcodePath, objectPath, triple],
            function: runWindowsCodegenFunction,
            diagnosticsURL: diagnosticsURL
        )

        var combinedError = clangResult.standardError
        if !combinedError.isEmpty && !codegenResult.standardError.isEmpty {
            combinedError.append(Data("\n".utf8))
        }
        combinedError.append(codegenResult.standardError)

        return MobileBuildResult(
            standardOutput: clangResult.standardOutput + codegenResult.standardOutput,
            standardError: combinedError,
            exitCode: codegenResult.exitCode
        )
    }

    /// Existing callers historically use this method for the native linker
    /// probe. Preserve that API: slash-prefixed lld-link arguments route to the
    /// optional COFF backend, while ordinary dash-prefixed arguments use Mach-O.
    public func runMachOLLD(arguments: [String], diagnosticsURL: URL? = nil) throws -> MobileBuildResult {
        if Self.looksLikeCOFFLink(arguments) {
            return try runCOFFLLD(arguments: arguments, diagnosticsURL: diagnosticsURL)
        }

        guard let runLLDMachOFunction else {
            throw MobileCompilerEngineError.missingSymbol("xtool_lld_macho_run")
        }

        return try runNative(
            arguments: arguments,
            function: runLLDMachOFunction,
            diagnosticsURL: diagnosticsURL
        )
    }

    public func runCOFFLLD(arguments: [String], diagnosticsURL: URL? = nil) throws -> MobileBuildResult {
        guard let runLLDCOFFFunction else {
            throw MobileCompilerEngineError.missingSymbol("xtool_windows_lld_coff_run")
        }

        return try runNative(
            arguments: arguments,
            function: runLLDCOFFFunction,
            diagnosticsURL: diagnosticsURL
        )
    }

    public static func bundleCandidates(bundle: Bundle = .main) -> [URL] {
        dylibCandidates(named: dylibName, bundle: bundle)
    }

    public static func windowsBundleCandidates(bundle: Bundle = .main) -> [URL] {
        dylibCandidates(named: windowsDylibName, bundle: bundle)
    }

    private static func dylibCandidates(named name: String, bundle: Bundle) -> [URL] {
        var result: [URL] = []
        if let frameworks = bundle.privateFrameworksURL {
            result.append(frameworks.appendingPathComponent(name))
        }
        result.append(
            bundle.bundleURL
                .appendingPathComponent("Frameworks", isDirectory: true)
                .appendingPathComponent(name)
        )
        result.append(bundle.bundleURL.appendingPathComponent(name))

        var seen = Set<String>()
        return result.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private static func argumentValue(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag) else { return nil }
        let valueIndex = index + 1
        guard arguments.indices.contains(valueIndex) else { return nil }
        return arguments[valueIndex]
    }

    private static func windowsTriple(in arguments: [String]) -> String? {
        argumentValue(after: "-triple", in: arguments) ??
        argumentValue(after: "-target", in: arguments)
    }

    private static func isWindowsClangJob(_ arguments: [String]) -> Bool {
        if let target = windowsTriple(in: arguments)?.lowercased() {
            return target.contains("windows") || target.contains("mingw")
        }
        return arguments.contains { argument in
            let value = argument.lowercased()
            return value.contains("windows-msvc") || value.contains("windows-gnu") || value.contains("mingw")
        }
    }

    private static func looksLikeCOFFLink(_ arguments: [String]) -> Bool {
        arguments.first?.hasPrefix("/") == true
    }

    private func runNative(
        arguments: [String],
        function: NativeRun,
        diagnosticsURL: URL?
    ) throws -> MobileBuildResult {
        let capture = try captureStandardError(persistingTo: diagnosticsURL) {
            withCStringArray(arguments) { argc, argv in
                function(argc, argv)
            }
        }

        return MobileBuildResult(
            standardError: capture.standardError,
            exitCode: capture.value
        )
    }

    private func captureStandardError<R>(
        persistingTo diagnosticsURL: URL?,
        _ body: () throws -> R
    ) throws -> (value: R, standardError: Data) {
        let fileManager = FileManager.default
        let captureURL = diagnosticsURL ?? fileManager.temporaryDirectory
            .appendingPathComponent("xtool-native-engine-\(UUID().uuidString).stderr")

        let captureFD = captureURL.path.withCString {
            open($0, O_CREAT | O_TRUNC | O_RDWR, S_IRUSR | S_IWUSR)
        }
        guard captureFD >= 0 else {
            throw MobileCompilerEngineError.diagnosticCaptureFailed(errno)
        }

        let savedStderr = dup(STDERR_FILENO)
        guard savedStderr >= 0 else {
            close(captureFD)
            if diagnosticsURL == nil { try? fileManager.removeItem(at: captureURL) }
            throw MobileCompilerEngineError.diagnosticCaptureFailed(errno)
        }

        guard dup2(captureFD, STDERR_FILENO) >= 0 else {
            let capturedErrno = errno
            close(savedStderr)
            close(captureFD)
            if diagnosticsURL == nil { try? fileManager.removeItem(at: captureURL) }
            throw MobileCompilerEngineError.diagnosticCaptureFailed(capturedErrno)
        }

        var bodyResult: Result<R, Error>!
        do {
            bodyResult = .success(try body())
        } catch {
            bodyResult = .failure(error)
        }

        fflush(nil)
        _ = fsync(captureFD)
        _ = dup2(savedStderr, STDERR_FILENO)
        close(savedStderr)

        _ = lseek(captureFD, 0, SEEK_SET)
        let captureHandle = FileHandle(fileDescriptor: captureFD, closeOnDealloc: true)
        let capturedData = (try? captureHandle.readToEnd()) ?? Data()
        try? captureHandle.close()
        if diagnosticsURL == nil { try? fileManager.removeItem(at: captureURL) }

        switch bodyResult! {
        case .success(let value):
            return (value, capturedData)
        case .failure(let error):
            throw error
        }
    }

    private func withCStringArray<R>(
        _ strings: [String],
        body: (Int32, UnsafePointer<UnsafePointer<CChar>?>?) throws -> R
    ) rethrows -> R {
        let storage: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
        defer {
            for pointer in storage {
                free(pointer)
            }
        }

        var argv: [UnsafePointer<CChar>?] = storage.map { pointer in
            pointer.map { UnsafePointer($0) }
        }
        argv.append(nil)

        return try argv.withUnsafeBufferPointer { buffer in
            try body(Int32(strings.count), buffer.baseAddress)
        }
    }
}

public enum MobileCompilerEngineError: Error, CustomStringConvertible, Sendable {
    case notBundled([URL])
    case loadFailed(URL, String)
    case missingSymbol(String)
    case diagnosticCaptureFailed(Int32)
    case invalidWindowsJob(String)

    public var description: String {
        switch self {
        case .notBundled(let candidates):
            let paths = candidates.map(\.path).joined(separator: ", ")
            return "Compiler engine is not bundled. Searched: \(paths)"
        case .loadFailed(let url, let message):
            return "Could not load compiler engine at \(url.path): \(message)"
        case .missingSymbol(let symbol):
            return "Compiler engine is missing required symbol: \(symbol)"
        case .diagnosticCaptureFailed(let errorNumber):
            return "Could not capture compiler diagnostics (errno \(errorNumber))"
        case .invalidWindowsJob(let reason):
            return "Invalid Windows compiler job: \(reason)"
        }
    }
}
