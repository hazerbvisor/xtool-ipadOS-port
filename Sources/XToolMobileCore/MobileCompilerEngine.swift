import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Loads the optional compiler engine bundled inside XTool Mobile and invokes
/// Swift, Clang and Mach-O LLD through a small stable C ABI.
///
/// Keeping the heavy compiler implementation behind a dylib means the app, UI
/// and build planner can be rebuilt independently from the compiler itself.
public final class MobileCompilerEngine: MobileProjectCompiler, @unchecked Sendable {
    public static let dylibName = "libXToolCompilerEngine.dylib"

    private typealias NativeRun = @convention(c) (
        Int32,
        UnsafePointer<UnsafePointer<CChar>?>?
    ) -> Int32
    private typealias VersionRead = @convention(c) () -> UnsafePointer<CChar>?

    private let handle: UnsafeMutableRawPointer
    private let runFrontendFunction: NativeRun
    private let runClangFunction: NativeRun?
    private let runLLDMachOFunction: NativeRun?
    public let location: URL
    public let version: String

    private init(
        handle: UnsafeMutableRawPointer,
        runFrontendFunction: @escaping NativeRun,
        runClangFunction: NativeRun?,
        runLLDMachOFunction: NativeRun?,
        location: URL,
        version: String
    ) {
        self.handle = handle
        self.runFrontendFunction = runFrontendFunction
        self.runClangFunction = runClangFunction
        self.runLLDMachOFunction = runLLDMachOFunction
        self.location = location
        self.version = version
    }

    deinit {
        dlclose(handle)
    }

    public var supportsClangFrontend: Bool {
        runClangFunction != nil
    }

    public var supportsMachOLLD: Bool {
        runLLDMachOFunction != nil
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

            var version = "unknown"
            if let versionSymbol = dlsym(handle, "xtool_compiler_engine_version") {
                let readVersion = unsafeBitCast(versionSymbol, to: VersionRead.self)
                if let value = readVersion() {
                    version = String(cString: value)
                }
            }

            return MobileCompilerEngine(
                handle: handle,
                runFrontendFunction: runFrontend,
                runClangFunction: runClang,
                runLLDMachOFunction: runLLDMachO,
                location: location,
                version: version
            )
        } catch {
            dlclose(handle)
            throw error
        }
    }

    /// Executes one already-prepared Swift frontend job in-process.
    ///
    /// `swift::performFrontend` expects the arguments that come *after* the
    /// desktop driver's `-frontend` dispatch marker. Strip that marker here as
    /// a defensive compatibility measure so older cached plans cannot feed a
    /// driver-only option to the embedded frontend.
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

    /// Executes Clang's cc1 frontend in-process.
    ///
    /// Arguments are frontend/cc1 arguments and must not contain an executable
    /// argv[0] entry or the desktop driver's `-cc1` dispatch marker.
    public func runClangFrontend(arguments: [String], diagnosticsURL: URL? = nil) throws -> MobileBuildResult {
        guard let runClangFunction else {
            throw MobileCompilerEngineError.missingSymbol("xtool_clang_frontend_run")
        }

        var frontendArguments = arguments
        if frontendArguments.first == "-cc1" {
            frontendArguments.removeFirst()
        }

        return try runNative(
            arguments: frontendArguments,
            function: runClangFunction,
            diagnosticsURL: diagnosticsURL
        )
    }

    /// Executes LLD's Darwin/Mach-O driver in-process.
    ///
    /// Pass ordinary ld64-style arguments. The native bridge supplies the
    /// synthetic argv[0] entry required by `lldMain`.
    public func runMachOLLD(arguments: [String], diagnosticsURL: URL? = nil) throws -> MobileBuildResult {
        guard let runLLDMachOFunction else {
            throw MobileCompilerEngineError.missingSymbol("xtool_lld_macho_run")
        }

        return try runNative(
            arguments: arguments,
            function: runLLDMachOFunction,
            diagnosticsURL: diagnosticsURL
        )
    }

    public static func bundleCandidates(bundle: Bundle = .main) -> [URL] {
        var result: [URL] = []
        if let frameworks = bundle.privateFrameworksURL {
            result.append(frameworks.appendingPathComponent(dylibName))
        }
        result.append(
            bundle.bundleURL
                .appendingPathComponent("Frameworks", isDirectory: true)
                .appendingPathComponent(dylibName)
        )
        result.append(bundle.bundleURL.appendingPathComponent(dylibName))

        var seen = Set<String>()
        return result.filter { seen.insert($0.standardizedFileURL.path).inserted }
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

    /// The embedded compiler stack writes diagnostics to the process stderr file
    /// descriptor. Capture that descriptor around a single frontend/linker call
    /// so errors can be surfaced inside XTool Mobile instead of disappearing into
    /// the application process console.
    ///
    /// This is intentionally serialized by the current bootstrap UI (one native
    /// job at a time). A future concurrent build scheduler should replace the
    /// process-global descriptor capture with per-engine diagnostic callbacks.
    private func captureStandardError<R>(
        persistingTo diagnosticsURL: URL?,
        _ body: () throws -> R
    ) throws -> (value: R, standardError: Data) {
        let fileManager = FileManager.default
        // Build captures remain on disk even if the native call never returns.
        // Probe calls retain their previous temporary-file behavior.
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
