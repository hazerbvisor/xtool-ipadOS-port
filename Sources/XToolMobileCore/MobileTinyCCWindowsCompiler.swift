import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Lightweight optional Windows compiler bundled with XTool Mobile.
///
/// The dylib itself runs as arm64 iOS code while TinyCC emits x86_64 PE64
/// executables for WinPad testing. It is deliberately separate from the main
/// Swift/Clang compiler engine so Windows fixture generation stays tiny and
/// cannot interfere with normal iOS builds.
public final class MobileTinyCCWindowsCompiler: @unchecked Sendable {
    public static let dylibName = "libXToolWindowsTCC.dylib"

    private typealias CompileString = @convention(c) (
        UnsafePointer<CChar>?,
        UnsafePointer<CChar>?
    ) -> Int32
    private typealias ReadString = @convention(c) () -> UnsafePointer<CChar>?

    private let handle: UnsafeMutableRawPointer
    private let compileStringFunction: CompileString
    private let lastErrorFunction: ReadString?

    public let location: URL
    public let version: String
    public let target: String

    private init(
        handle: UnsafeMutableRawPointer,
        compileStringFunction: @escaping CompileString,
        lastErrorFunction: ReadString?,
        location: URL,
        version: String,
        target: String
    ) {
        self.handle = handle
        self.compileStringFunction = compileStringFunction
        self.lastErrorFunction = lastErrorFunction
        self.location = location
        self.version = version
        self.target = target
    }

    deinit {
        dlclose(handle)
    }

    public static func loadFromApplicationBundle(
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) throws -> MobileTinyCCWindowsCompiler {
        let candidates = bundleCandidates(bundle: bundle)
        guard let location = candidates.first(where: {
            fileManager.fileExists(atPath: $0.path)
        }) else {
            throw MobileTinyCCWindowsCompilerError.notBundled(candidates)
        }

        dlerror()
        guard let handle = dlopen(location.path, RTLD_NOW | RTLD_LOCAL) else {
            let message = dlerror().map { String(cString: $0) } ?? "unknown dlopen error"
            throw MobileTinyCCWindowsCompilerError.loadFailed(location, message)
        }

        do {
            guard let compileSymbol = dlsym(handle, "xtool_windows_tcc_compile_string") else {
                throw MobileTinyCCWindowsCompilerError.missingSymbol(
                    "xtool_windows_tcc_compile_string"
                )
            }
            let compileString = unsafeBitCast(compileSymbol, to: CompileString.self)
            let lastError = dlsym(handle, "xtool_windows_tcc_last_error").map {
                unsafeBitCast($0, to: ReadString.self)
            }

            let version = readStringSymbol(
                named: "xtool_windows_tcc_version",
                handle: handle
            ) ?? "unknown"
            let target = readStringSymbol(
                named: "xtool_windows_tcc_target",
                handle: handle
            ) ?? "x86_64-pc-windows-pe64"

            return MobileTinyCCWindowsCompiler(
                handle: handle,
                compileStringFunction: compileString,
                lastErrorFunction: lastError,
                location: location,
                version: version,
                target: target
            )
        } catch {
            dlclose(handle)
            throw error
        }
    }

    @discardableResult
    public func compile(source: String, outputURL: URL) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? fileManager.removeItem(at: outputURL)

        let status = source.withCString { sourcePointer in
            outputURL.path.withCString { outputPointer in
                compileStringFunction(sourcePointer, outputPointer)
            }
        }

        guard status == 0 else {
            let diagnostic: String?
            if let lastErrorFunction,
               let value = lastErrorFunction(),
               value.pointee != 0 {
                diagnostic = String(cString: value)
            } else {
                diagnostic = nil
            }
            throw MobileTinyCCWindowsCompilerError.compileFailed(status, diagnostic)
        }
        guard fileManager.fileExists(atPath: outputURL.path) else {
            throw MobileTinyCCWindowsCompilerError.outputMissing(outputURL)
        }
        return outputURL
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

    private static func readStringSymbol(
        named name: String,
        handle: UnsafeMutableRawPointer
    ) -> String? {
        guard let symbol = dlsym(handle, name) else { return nil }
        let read = unsafeBitCast(symbol, to: ReadString.self)
        guard let value = read() else { return nil }
        return String(cString: value)
    }
}

public enum MobileTinyCCWindowsCompilerError: Error, CustomStringConvertible, Sendable {
    case notBundled([URL])
    case loadFailed(URL, String)
    case missingSymbol(String)
    case compileFailed(Int32, String?)
    case outputMissing(URL)

    public var description: String {
        switch self {
        case .notBundled(let candidates):
            let paths = candidates.map(\.path).joined(separator: ", ")
            return "TinyCC Windows backend is not bundled. Searched: \(paths)"
        case .loadFailed(let url, let message):
            return "Could not load TinyCC Windows backend at \(url.path): \(message)"
        case .missingSymbol(let symbol):
            return "TinyCC Windows backend is missing required symbol: \(symbol)"
        case .compileFailed(let status, let diagnostic):
            if let diagnostic, !diagnostic.isEmpty {
                return "TinyCC Windows compilation failed at stage \(status): \(diagnostic)"
            }
            return "TinyCC Windows compilation failed at stage \(status)."
        case .outputMissing(let url):
            return "TinyCC reported success but did not create \(url.lastPathComponent)."
        }
    }
}
