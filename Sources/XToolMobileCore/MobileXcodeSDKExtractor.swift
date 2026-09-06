import Compression
import Foundation

public struct MobileSDKExtractionUpdate: Sendable, Hashable {
    public let progress: Double
    public let message: String

    public init(progress: Double, message: String) {
        self.progress = progress
        self.message = message
    }
}

public struct MobileSDKImportResult: Sendable, Hashable {
    public let installedSDKNames: [String]
    public let activeSDKName: String?
    public let filesWritten: Int
    public let activationMessage: String

    public init(
        installedSDKNames: [String],
        activeSDKName: String?,
        filesWritten: Int,
        activationMessage: String
    ) {
        self.installedSDKNames = installedSDKNames
        self.activeSDKName = activeSDKName
        self.filesWritten = filesWritten
        self.activationMessage = activationMessage
    }
}

public enum MobileSDKImportError: Error, LocalizedError, Sendable {
    case invalidXIP(String)
    case malformedArchive(String)
    case decompressionFailed(String)
    case noSDKFound
    case runtimeUnavailable(String)
    case invalidSDK(String)

    public var errorDescription: String? {
        switch self {
        case .invalidXIP(let reason):
            return "Invalid Xcode XIP: \(reason)"
        case .malformedArchive(let reason):
            return "Malformed Xcode archive: \(reason)"
        case .decompressionFailed(let reason):
            return "Xcode archive decompression failed: \(reason)"
        case .noSDKFound:
            return "No iPhoneOS SDK was found in this Xcode archive."
        case .runtimeUnavailable(let reason):
            return "XTool runtime is unavailable: \(reason)"
        case .invalidSDK(let reason):
            return "Extracted iPhoneOS SDK is invalid: \(reason)"
        }
    }
}

/// Installs the iPhoneOS SDK embedded in an Apple Xcode `.xip` into XTool's
/// Application Support runtime without expanding the rest of Xcode.
///
/// Xcode XIPs are XAR containers whose `Content` entry is PBZX-framed XZ/LZMA
/// data containing an ODC CPIO stream. PBZX has no per-file index, so the input
/// must be decoded sequentially, but non-SDK files are discarded before they
/// touch disk.
public enum MobileXcodeSDKInstaller {
    public typealias ProgressHandler = @Sendable (MobileSDKExtractionUpdate) async -> Void

    public static func canonicalRuntimeRoot(
        fileManager: FileManager = .default
    ) throws -> URL {
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw MobileSDKImportError.runtimeUnavailable("Application Support directory is missing")
        }
        return applicationSupport.appendingPathComponent("XToolMobileRuntime", isDirectory: true)
    }

    public static func importFromXcodeXIP(
        _ xipURL: URL,
        fileManager: FileManager = .default,
        progress: @escaping ProgressHandler
    ) async throws -> MobileSDKImportResult {
        try Task.checkCancellation()

        let runtimeRoot = try canonicalRuntimeRoot(fileManager: fileManager)
        let toolchain = PreparedToolchain(root: runtimeRoot)
        let sdkDirectory = toolchain.iPhoneOSPlatform
            .appendingPathComponent("Developer/SDKs", isDirectory: true)

        guard fileManager.fileExists(atPath: toolchain.developerDirectory.path) else {
            throw MobileSDKImportError.runtimeUnavailable(
                "install or prepare the XTool compiler runtime before importing an SDK"
            )
        }
        try fileManager.createDirectory(at: sdkDirectory, withIntermediateDirectories: true)

        // Pin the currently selected SDK before introducing another directory.
        // PreparedToolchain historically selected the lexicographically newest
        // SDK, which could otherwise switch builds to an incompatible SDK simply
        // because extraction finished.
        let oldSelected = try? toolchain.iPhoneOSSDK(fileManager: fileManager)
        if toolchain.preferrediPhoneOSSDKName(fileManager: fileManager) == nil,
           let oldSelected {
            try toolchain.setPreferrediPhoneOSSDK(
                named: oldSelected.lastPathComponent,
                fileManager: fileManager
            )
        }

        let stagingRoot = runtimeRoot
            .deletingLastPathComponent()
            .appendingPathComponent("XToolSDKImport-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: stagingRoot) }
        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)

        let extractor = MobileXcodeXIPSDKExtractor(fileManager: fileManager)
        let extraction = try await extractor.extractSDKs(
            from: xipURL,
            to: stagingRoot,
            progress: progress
        )

        var installed: [String] = []
        for name in extraction.sdkNames.sorted(by: sdkNameLessThan) {
            try Task.checkCancellation()
            let staged = stagingRoot.appendingPathComponent(name, isDirectory: true)
            try validateSDK(at: staged, name: name, fileManager: fileManager)
            let destination = sdkDirectory.appendingPathComponent(name, isDirectory: true)
            try replaceDirectoryAtomically(
                staged,
                destination: destination,
                fileManager: fileManager
            )
            installed.append(name)
        }

        guard !installed.isEmpty else {
            throw MobileSDKImportError.noSDKFound
        }

        // Activate the newest imported SDK only when the matching prebuilt Swift
        // stdlib cache is available. A full Apple SDK alone does not replace the
        // version-matched upstream Swift module XTool's embedded frontend needs.
        let activationCandidate = installed.sorted(by: sdkNameLessThan).last!
        let activationURL = sdkDirectory.appendingPathComponent(activationCandidate, isDirectory: true)
        let canActivate = toolchain.hasPrebuiltSwiftModule(
            for: activationURL,
            fileManager: fileManager
        )

        let activeName: String?
        let activationMessage: String
        if canActivate {
            try toolchain.setPreferrediPhoneOSSDK(
                named: activationCandidate,
                fileManager: fileManager
            )
            activeName = activationCandidate
            activationMessage = "Installed and activated \(activationCandidate)."
        } else if let oldSelected {
            try toolchain.setPreferrediPhoneOSSDK(
                named: oldSelected.lastPathComponent,
                fileManager: fileManager
            )
            activeName = oldSelected.lastPathComponent
            activationMessage = "Installed \(activationCandidate), but kept \(oldSelected.lastPathComponent) active because XTool does not have a matching prebuilt Swift stdlib module for the imported SDK yet."
        } else {
            activeName = nil
            activationMessage = "Installed \(activationCandidate), but it cannot be activated until XTool has a matching prebuilt Swift stdlib module."
        }

        await progress(.init(progress: 1, message: activationMessage))
        return MobileSDKImportResult(
            installedSDKNames: installed,
            activeSDKName: activeName,
            filesWritten: extraction.filesWritten,
            activationMessage: activationMessage
        )
    }

    private static func validateSDK(
        at url: URL,
        name: String,
        fileManager: FileManager
    ) throws {
        var isDirectory: ObjCBool = false
        guard name.hasPrefix("iPhoneOS"), name.hasSuffix(".sdk"),
              fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw MobileSDKImportError.invalidSDK(name)
        }

        let settings = url.appendingPathComponent("SDKSettings.json")
        let frameworks = url.appendingPathComponent("System/Library/Frameworks", isDirectory: true)
        let usrLib = url.appendingPathComponent("usr/lib", isDirectory: true)
        guard fileManager.fileExists(atPath: settings.path),
              fileManager.fileExists(atPath: frameworks.path),
              fileManager.fileExists(atPath: usrLib.path) else {
            throw MobileSDKImportError.invalidSDK(
                "\(name) is missing SDKSettings.json, System/Library/Frameworks, or usr/lib"
            )
        }
    }

    private static func replaceDirectoryAtomically(
        _ source: URL,
        destination: URL,
        fileManager: FileManager
    ) throws {
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        guard fileManager.fileExists(atPath: destination.path) else {
            try fileManager.moveItem(at: source, to: destination)
            return
        }

        let backup = parent.appendingPathComponent(
            ".\(destination.lastPathComponent).xtool-backup-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.moveItem(at: destination, to: backup)
        do {
            try fileManager.moveItem(at: source, to: destination)
            try? fileManager.removeItem(at: backup)
        } catch {
            try? fileManager.removeItem(at: destination)
            try? fileManager.moveItem(at: backup, to: destination)
            throw error
        }
    }

    private static func sdkNameLessThan(_ lhs: String, _ rhs: String) -> Bool {
        sdkVersionComponents(lhs).lexicographicallyPrecedes(sdkVersionComponents(rhs))
    }

    private static func sdkVersionComponents(_ name: String) -> [Int] {
        let stem = String(name.dropFirst("iPhoneOS".count).dropLast(".sdk".count))
        return stem.split(separator: ".").map { Int($0) ?? 0 }
    }
}

private final class MobileXcodeXIPSDKExtractor: @unchecked Sendable {
    private let fileManager: FileManager

    init(fileManager: FileManager) {
        self.fileManager = fileManager
    }

    struct ExtractionResult: Sendable {
        let sdkNames: [String]
        let filesWritten: Int
    }

    func extractSDKs(
        from xipURL: URL,
        to destinationURL: URL,
        progress: @escaping MobileXcodeSDKInstaller.ProgressHandler
    ) async throws -> ExtractionResult {
        try Task.checkCancellation()
        let handle = try FileHandle(forReadingFrom: xipURL)
        defer { try? handle.close() }

        await progress(.init(progress: 0, message: "Reading Xcode XIP table of contents…"))
        let xar = try readXARContentLocation(from: handle)

        try handle.seek(toOffset: xar.contentOffset)
        let pbzxMagic = try readExactly(4, from: handle)
        guard String(decoding: pbzxMagic, as: UTF8.self) == "pbzx" else {
            throw MobileSDKImportError.invalidXIP("the XAR Content entry is not PBZX")
        }

        let chunkSize = try readUInt64BE(from: handle)
        guard chunkSize > 0, chunkSize <= 1 << 31 else {
            throw MobileSDKImportError.malformedArchive("invalid PBZX chunk size \(chunkSize)")
        }

        let cpio = try MobileSelectiveSDKCPIOExtractor(
            destinationRoot: destinationURL,
            fileManager: fileManager
        )
        var consumedInContent: UInt64 = 12
        var chunkIndex = 0
        var decompressedSize: UInt64

        repeat {
            try Task.checkCancellation()
            decompressedSize = try readUInt64BE(from: handle)
            let compressedSize = try readUInt64BE(from: handle)
            consumedInContent += 16

            guard decompressedSize <= 1 << 31, compressedSize <= 1 << 31 else {
                throw MobileSDKImportError.malformedArchive("PBZX chunk is unreasonably large")
            }

            let compressed = try readExactly(Int(compressedSize), from: handle)
            consumedInContent += compressedSize
            chunkIndex += 1

            let decoded: Data
            let xzMagic: [UInt8] = [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]
            if compressed.starts(with: xzMagic) {
                decoded = try decode(
                    compressed,
                    expectedSize: Int(decompressedSize),
                    algorithm: COMPRESSION_LZMA
                )
            } else if compressedSize == decompressedSize || compressedSize == chunkSize {
                decoded = compressed
            } else {
                throw MobileSDKImportError.malformedArchive(
                    "PBZX chunk \(chunkIndex) is neither XZ nor raw data"
                )
            }

            try cpio.feed(decoded)
            let fraction = xar.contentLength == 0
                ? 0
                : min(0.995, Double(consumedInContent) / Double(xar.contentLength))
            let found = cpio.sdkNames.sorted().joined(separator: ", ")
            let status = found.isEmpty ? "Scanning for iPhoneOS SDK…" : "Extracting \(found)…"
            await progress(.init(progress: fraction, message: "Chunk \(chunkIndex): \(status)"))
        } while decompressedSize == chunkSize

        try cpio.finish()
        guard !cpio.sdkNames.isEmpty else {
            throw MobileSDKImportError.noSDKFound
        }
        return ExtractionResult(
            sdkNames: cpio.sdkNames.sorted(),
            filesWritten: cpio.filesWritten
        )
    }

    private struct XARContentLocation {
        let contentOffset: UInt64
        let contentLength: UInt64
    }

    private func readXARContentLocation(from handle: FileHandle) throws -> XARContentLocation {
        try handle.seek(toOffset: 0)
        let fixed = try readExactly(28, from: handle)
        guard String(decoding: fixed.prefix(4), as: UTF8.self) == "xar!" else {
            throw MobileSDKImportError.invalidXIP("missing xar! header")
        }

        let headerSize = UInt64(fixed.readUInt16BE(at: 4))
        let version = fixed.readUInt16BE(at: 6)
        let tocCompressedSize = fixed.readUInt64BE(at: 8)
        let tocDecompressedSize = fixed.readUInt64BE(at: 16)
        guard version == 1 else {
            throw MobileSDKImportError.invalidXIP("unsupported XAR version \(version)")
        }
        guard headerSize >= 28, tocCompressedSize > 2, tocDecompressedSize > 0,
              tocCompressedSize <= 64 * 1024 * 1024,
              tocDecompressedSize <= 256 * 1024 * 1024 else {
            throw MobileSDKImportError.malformedArchive("invalid XAR table-of-contents sizes")
        }

        try handle.seek(toOffset: headerSize)
        let compressedTOC = try readExactly(Int(tocCompressedSize), from: handle)
        // Apple's Compression zlib decoder expects the deflate stream without
        // RFC 1950 CMF/FLG. This matches the approach used by unxip on Apple OSes.
        let tocData = try decode(
            Data(compressedTOC.dropFirst(2)),
            expectedSize: Int(tocDecompressedSize),
            algorithm: COMPRESSION_ZLIB
        )

        guard let tocText = String(data: tocData, encoding: .utf8),
              let record = parseContentRecord(in: tocText) else {
            throw MobileSDKImportError.malformedArchive("Content entry is missing from the XAR table of contents")
        }

        let heapStart = headerSize + tocCompressedSize
        return XARContentLocation(
            contentOffset: heapStart + record.offset,
            contentLength: record.length
        )
    }

    /// Tiny purpose-built SAX-style parser for the XAR TOC. It avoids pulling
    /// FoundationXML/libxml2 into the mobile compiler target and only records the
    /// `<file>` whose `<name>` is exactly `Content`.
    private func parseContentRecord(in xml: String) -> (offset: UInt64, length: UInt64)? {
        struct Record {
            var name = ""
            var offset: UInt64?
            var length: UInt64?
            var dataDepth = 0
        }

        var stack: [Record] = []
        var currentTag = ""
        var text = ""
        var cursor = xml.startIndex

        func normalizedTag(_ raw: Substring) -> (name: String, closing: Bool, selfClosing: Bool) {
            var tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let closing = tag.hasPrefix("/")
            if closing { tag.removeFirst() }
            let selfClosing = tag.hasSuffix("/")
            if selfClosing { tag.removeLast() }
            let name = tag.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
            return (name, closing, selfClosing)
        }

        while cursor < xml.endIndex {
            guard let open = xml[cursor...].firstIndex(of: "<") else { break }
            if open > cursor, !currentTag.isEmpty {
                text += xml[cursor..<open]
            }
            guard let close = xml[open...].firstIndex(of: ">") else { break }
            let info = normalizedTag(xml[xml.index(after: open)..<close])
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)

            if info.closing {
                if !stack.isEmpty {
                    switch info.name {
                    case "name" where currentTag == "name":
                        stack[stack.count - 1].name = value
                    case "offset" where currentTag == "offset" && stack[stack.count - 1].dataDepth > 0:
                        stack[stack.count - 1].offset = UInt64(value)
                    case "length" where currentTag == "length" && stack[stack.count - 1].dataDepth > 0:
                        stack[stack.count - 1].length = UInt64(value)
                    case "data":
                        stack[stack.count - 1].dataDepth = max(0, stack[stack.count - 1].dataDepth - 1)
                    case "file":
                        let record = stack.removeLast()
                        if record.name == "Content", let offset = record.offset, let length = record.length {
                            return (offset, length)
                        }
                    default:
                        break
                    }
                }
                currentTag = ""
                text = ""
            } else {
                if info.name == "file" { stack.append(Record()) }
                if info.name == "data", !stack.isEmpty { stack[stack.count - 1].dataDepth += 1 }
                currentTag = info.name
                text = ""
                if info.selfClosing { currentTag = "" }
            }
            cursor = xml.index(after: close)
        }
        return nil
    }

    private func decode(
        _ input: Data,
        expectedSize: Int,
        algorithm: compression_algorithm
    ) throws -> Data {
        guard expectedSize >= 0 else {
            throw MobileSDKImportError.decompressionFailed("negative output size")
        }
        var output = Data(count: expectedSize)
        let count = output.withUnsafeMutableBytes { destination in
            input.withUnsafeBytes { source in
                guard let destinationBase = destination.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let sourceBase = source.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return 0
                }
                return compression_decode_buffer(
                    destinationBase,
                    expectedSize,
                    sourceBase,
                    input.count,
                    nil,
                    algorithm
                )
            }
        }
        guard count == expectedSize else {
            throw MobileSDKImportError.decompressionFailed(
                "expected \(expectedSize) bytes but decoded \(count)"
            )
        }
        return output
    }

    private func readExactly(_ count: Int, from handle: FileHandle) throws -> Data {
        guard count >= 0 else {
            throw MobileSDKImportError.malformedArchive("negative read length")
        }
        guard let data = try handle.read(upToCount: count), data.count == count else {
            throw MobileSDKImportError.malformedArchive("unexpected end of XIP")
        }
        return data
    }

    private func readUInt64BE(from handle: FileHandle) throws -> UInt64 {
        try readExactly(8, from: handle).readUInt64BE(at: 0)
    }
}

private final class MobileSelectiveSDKCPIOExtractor {
    private static let headerLength = 76
    private static let modeMask = 0o170000
    private static let modeRegular = 0o100000
    private static let modeDirectory = 0o040000
    private static let modeSymlink = 0o120000

    private struct Header {
        let dev: Int
        let ino: Int
        let mode: Int
        let nlink: Int
        let nameSize: Int
        let fileSize: Int
    }

    private struct EntryContext {
        let outputURL: URL?
        let mode: Int
        let dev: Int
        let ino: Int
        let nlink: Int
        var remaining: Int
        var fileHandle: FileHandle?
        var symlinkData = Data()
    }

    private enum State {
        case header
        case name(Header)
        case body(EntryContext)
        case done
    }

    private let destinationRoot: URL
    private let fileManager: FileManager
    private var buffer = Data()
    private var cursor = 0
    private var state: State = .header
    private var hardlinks: [String: URL] = [:]

    private(set) var sdkNames = Set<String>()
    private(set) var filesWritten = 0

    init(destinationRoot: URL, fileManager: FileManager) throws {
        self.destinationRoot = destinationRoot.standardizedFileURL
        self.fileManager = fileManager
        try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
    }

    func feed(_ data: Data) throws {
        if case .done = state { return }
        buffer.append(data)
        try parseAvailable()
        compactBufferIfNeeded()
    }

    func finish() throws {
        try parseAvailable()
        if case .done = state { return }
        if availableBytes == 0, case .header = state { return }
        throw MobileSDKImportError.malformedArchive("CPIO stream ended mid-entry")
    }

    private var availableBytes: Int { buffer.count - cursor }

    private func parseAvailable() throws {
        while true {
            switch state {
            case .done:
                return
            case .header:
                guard availableBytes >= Self.headerLength else { return }
                let headerData = take(Self.headerLength)
                guard String(decoding: headerData.prefix(6), as: UTF8.self) == "070707" else {
                    throw MobileSDKImportError.malformedArchive("unsupported CPIO format; expected odc 070707")
                }
                let header = Header(
                    dev: try octal(headerData, 6, 6),
                    ino: try octal(headerData, 12, 6),
                    mode: try octal(headerData, 18, 6),
                    nlink: try octal(headerData, 36, 6),
                    nameSize: try octal(headerData, 59, 6),
                    fileSize: try octal(headerData, 65, 11)
                )
                guard header.nameSize > 0, header.nameSize <= 1 << 20, header.fileSize >= 0 else {
                    throw MobileSDKImportError.malformedArchive("invalid CPIO entry sizes")
                }
                state = .name(header)

            case .name(let header):
                guard availableBytes >= header.nameSize else { return }
                var nameData = take(header.nameSize)
                if nameData.last == 0 { nameData.removeLast() }
                let name = String(decoding: nameData, as: UTF8.self)
                if name == "TRAILER!!!" {
                    state = .done
                    return
                }

                let output = try outputURL(forArchivePath: name)
                if let output {
                    let relativeComponents = output.pathComponents.dropFirst(destinationRoot.pathComponents.count)
                    if let sdk = relativeComponents.first { sdkNames.insert(sdk) }
                }

                let type = header.mode & Self.modeMask
                if let output, type == Self.modeDirectory {
                    try fileManager.createDirectory(at: output, withIntermediateDirectories: true)
                    try? applyPermissions(header.mode, to: output)
                }

                var context = EntryContext(
                    outputURL: output,
                    mode: header.mode,
                    dev: header.dev,
                    ino: header.ino,
                    nlink: header.nlink,
                    remaining: header.fileSize,
                    fileHandle: nil
                )

                if let output, type == Self.modeRegular {
                    try fileManager.createDirectory(
                        at: output.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    if header.fileSize == 0, header.nlink > 1,
                       let original = hardlinks[hardlinkKey(dev: header.dev, ino: header.ino)] {
                        try? fileManager.removeItem(at: output)
                        do {
                            try fileManager.linkItem(at: original, to: output)
                            filesWritten += 1
                        } catch {
                            _ = fileManager.createFile(atPath: output.path, contents: Data())
                            filesWritten += 1
                        }
                    } else {
                        try? fileManager.removeItem(at: output)
                        _ = fileManager.createFile(atPath: output.path, contents: nil)
                        context.fileHandle = try FileHandle(forWritingTo: output)
                        if header.nlink > 1 {
                            hardlinks[hardlinkKey(dev: header.dev, ino: header.ino)] = output
                        }
                    }
                }
                state = .body(context)

            case .body(var context):
                let type = context.mode & Self.modeMask
                if context.remaining == 0 {
                    try finalize(&context)
                    state = .header
                    continue
                }
                guard availableBytes > 0 else {
                    state = .body(context)
                    return
                }
                let amount = min(context.remaining, availableBytes)
                let chunk = take(amount)
                if context.outputURL != nil {
                    if type == Self.modeRegular {
                        try context.fileHandle?.write(contentsOf: chunk)
                    } else if type == Self.modeSymlink {
                        context.symlinkData.append(chunk)
                    }
                }
                context.remaining -= amount
                if context.remaining == 0 {
                    try finalize(&context)
                    state = .header
                } else {
                    state = .body(context)
                    return
                }
            }
        }
    }

    private func finalize(_ context: inout EntryContext) throws {
        let type = context.mode & Self.modeMask
        if type == Self.modeRegular {
            try? context.fileHandle?.close()
            if let output = context.outputURL, context.fileHandle != nil {
                try? applyPermissions(context.mode, to: output)
                filesWritten += 1
            }
        } else if type == Self.modeSymlink, let output = context.outputURL {
            try fileManager.createDirectory(
                at: output.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? fileManager.removeItem(at: output)
            let target = String(decoding: context.symlinkData, as: UTF8.self)
            try fileManager.createSymbolicLink(atPath: output.path, withDestinationPath: target)
            filesWritten += 1
        }
    }

    private func outputURL(forArchivePath path: String) throws -> URL? {
        let marker = "/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/"
        guard let range = path.range(of: marker) else { return nil }
        let relative = String(path[range.upperBound...])
        let components = relative.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let sdk = components.first,
              sdk.hasPrefix("iPhoneOS"), sdk.hasSuffix(".sdk") else {
            return nil
        }
        guard !components.contains(".."), !relative.hasPrefix("/") else {
            throw MobileSDKImportError.malformedArchive("unsafe CPIO path")
        }

        var url = destinationRoot
        for component in components {
            guard component != ".", component != "..", !component.contains("\0") else {
                throw MobileSDKImportError.malformedArchive("unsafe CPIO path component")
            }
            url.appendPathComponent(component)
        }

        let rootPath = destinationRoot.standardizedFileURL.path
        let finalPath = url.standardizedFileURL.path
        guard finalPath == rootPath || finalPath.hasPrefix(rootPath + "/") else {
            throw MobileSDKImportError.malformedArchive("CPIO path escaped destination")
        }
        return url
    }

    private func octal(_ data: Data, _ offset: Int, _ length: Int) throws -> Int {
        let text = String(decoding: data[offset..<(offset + length)], as: UTF8.self)
            .trimmingCharacters(in: CharacterSet(charactersIn: " \0"))
        guard let value = Int(text.isEmpty ? "0" : text, radix: 8) else {
            throw MobileSDKImportError.malformedArchive("invalid CPIO octal field")
        }
        return value
    }

    private func take(_ count: Int) -> Data {
        let range = cursor..<(cursor + count)
        let result = buffer.subdata(in: range)
        cursor += count
        return result
    }

    private func compactBufferIfNeeded() {
        if cursor > 8 * 1024 * 1024 || (cursor > 0 && cursor == buffer.count) {
            buffer.removeSubrange(0..<cursor)
            cursor = 0
        }
    }

    private func hardlinkKey(dev: Int, ino: Int) -> String { "\(dev):\(ino)" }

    private func applyPermissions(_ mode: Int, to url: URL) throws {
        try fileManager.setAttributes(
            [.posixPermissions: mode & 0o777],
            ofItemAtPath: url.path
        )
    }
}

private extension Data {
    func readUInt16BE(at offset: Int) -> UInt16 {
        (UInt16(self[offset]) << 8) | UInt16(self[offset + 1])
    }

    func readUInt64BE(at offset: Int) -> UInt64 {
        var result: UInt64 = 0
        for index in 0..<8 {
            result = (result << 8) | UInt64(self[offset + index])
        }
        return result
    }
}
