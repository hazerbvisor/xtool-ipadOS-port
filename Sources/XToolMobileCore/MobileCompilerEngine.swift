import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Loads the main XTool compiler engine and, when bundled, the isolated Windows
/// backend. Swift/iOS work stays in the main dylib while x86_64 Windows Clang
/// and COFF LLD calls are routed to libXToolWindowsBackend.dylib.
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
    private let runWindowsClangFunction: NativeRun?
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
        runWindowsClangFunction: NativeRun?,
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
        self.runWindowsClangFunction = runWindowsClangFunction
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

    public var supportsWindowsClang: Bool {
        runWindowsClangFunction != nil
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
            var runWindowsClang: NativeRun?
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

                guard let windowsClangSymbol = dlsym(candidateHandle, "xtool_windows_clang_run") else {
                    throw MobileCompilerEngineError.missingSymbol("xtool_windows_clang_run")
                }
                guard let windowsCOFFSymbol = dlsym(candidateHandle, "xtool_windows_lld_coff_run") else {
                    throw MobileCompilerEngineError.missingSymbol("xtool_windows_lld_coff_run")
                }
                runWindowsClang = unsafeBitCast(windowsClangSymbol, to: NativeRun.self)
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
                runWindowsClangFunction: runWindowsClang,
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

    /// Routes Windows triples to the isolated X86 backend while ordinary iOS
    /// Clang jobs continue through the main compiler engine.
    public func runClangFrontend(arguments: [String], diagnosticsURL: URL? = nil) throws -> MobileBuildResult {
        var frontendArguments = arguments
        if frontendArguments.first == "-cc1" {
            frontendArguments.removeFirst()
        }

        let function: NativeRun
        if Self.isWindowsClangJob(frontendArguments) {
            guard let runWindowsClangFunction else {
                throw MobileCompilerEngineError.missingSymbol("xtool_windows_clang_run")
            }
            function = runWindowsClangFunction
        } else {
            guard let runClangFunction else {
                throw MobileCompilerEngineError.missingSymbol("xtool_clang_frontend_run")
            }
            function = runClangFunction
        }

        return try runNative(
            arguments: frontendArguments,
            function: function,
            diagnosticsURL: diagnosticsURL
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

    private static func isWindowsClangJob(_ arguments: [String]) -> Bool {
        for (index, argument) in arguments.enumerated() where argument == "-triple" || argument == "-target" {
            let targetIndex = arguments.index(arguments.startIndex, offsetBy: index + 1, limitedBy: arguments.endIndex)
            if let targetIndex, targetIndex < arguments.endIndex {
                let target = arguments[targetIndex].lowercased()
                if target.contains("windows") || target.contains("mingw") {
                    return true
                }
            }
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
        }
    }
}
