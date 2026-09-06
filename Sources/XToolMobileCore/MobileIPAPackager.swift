import Foundation
#if canImport(Compression)
import Compression
#endif

public struct MobileIPAFile: Sendable {
    public let sourceURL: URL
    public let relativePath: String
    public let isExecutable: Bool

    public init(sourceURL: URL, relativePath: String, isExecutable: Bool = false) {
        self.sourceURL = sourceURL
        self.relativePath = relativePath
        self.isExecutable = isExecutable
    }
}

public struct MobileIPAConfiguration: Sendable {
    public let productName: String
    public let executableName: String
    public let bundleIdentifier: String
    public let displayName: String
    public let shortVersion: String
    public let buildVersion: String
    public let minimumOSVersion: String

    public init(
        productName: String,
        executableName: String,
        bundleIdentifier: String,
        displayName: String,
        shortVersion: String = "0.3",
        buildVersion: String = "3",
        minimumOSVersion: String = "16.0"
    ) {
        self.productName = productName
        self.executableName = executableName
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.shortVersion = shortVersion
        self.buildVersion = buildVersion
        self.minimumOSVersion = minimumOSVersion
    }
}

public enum MobileIPAPackager {
    public static func packageUnsignedIPA(
        executableURL: URL,
        configuration: MobileIPAConfiguration,
        additionalFiles: [MobileIPAFile] = [],
        additionalInfoPlist: [String: Any] = [:],
        outputURL: URL
    ) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: executableURL.path) else {
            throw PackagerError.missingInput(executableURL.path)
        }

        try MobileAppManifest.validateName(configuration.productName)
        try MobileAppManifest.validateName(configuration.executableName)

        let appRoot = "Payload/\(configuration.productName).app"
        let infoPlist = try makeInfoPlist(configuration: configuration, additional: additionalInfoPlist)
        var names: Set<String> = [configuration.executableName.lowercased(), "info.plist"]

        var entries: [VerifiedZIP.Entry] = [
            .file(
                sourceURL: executableURL,
                archivePath: "\(appRoot)/\(configuration.executableName)",
                unixMode: 0o100755
            ),
            .data(
                infoPlist,
                archivePath: "\(appRoot)/Info.plist",
                unixMode: 0o100644
            ),
        ]

        for file in additionalFiles {
            guard fm.fileExists(atPath: file.sourceURL.path) else {
                throw PackagerError.missingInput(file.sourceURL.path)
            }

            let relative = file.relativePath
            let key = relative.lowercased()
            guard !relative.isEmpty,
                  !relative.hasPrefix("/"),
                  !relative.contains("\\"),
                  !relative.split(separator: "/", omittingEmptySubsequences: false)
                    .contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
                  !names.contains(where: {
                      $0 == key || $0.hasPrefix(key + "/") || key.hasPrefix($0 + "/")
                  }) else {
                throw PackagerError.invalidArchivePath(file.relativePath)
            }

            names.insert(key)
            entries.append(
                .file(
                    sourceURL: file.sourceURL,
                    archivePath: "\(appRoot)/\(relative)",
                    unixMode: file.isExecutable ? 0o100755 : 0o100644
                )
            )
        }

        try fm.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = outputURL.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).ipa")
        defer { try? fm.removeItem(at: temporary) }

        try VerifiedZIP.write(entries: entries, to: temporary)

        let archiveSize = ((try fm.attributesOfItem(atPath: temporary.path)[.size]) as? NSNumber)?
            .uint64Value ?? 0
        guard archiveSize > 1024 else {
            throw PackagerError.invalidArchive("packager produced an implausibly small IPA (\(archiveSize) bytes)")
        }

        if fm.fileExists(atPath: outputURL.path) {
            _ = try fm.replaceItemAt(outputURL, withItemAt: temporary)
        } else {
            try fm.moveItem(at: temporary, to: outputURL)
        }
    }

    private static func makeInfoPlist(
        configuration: MobileIPAConfiguration,
        additional: [String: Any]
    ) throws -> Data {
        var plist: [String: Any] = [
            "CFBundleDevelopmentRegion": "en",
            "CFBundleDisplayName": configuration.displayName,
            "CFBundleExecutable": configuration.executableName,
            "CFBundleIdentifier": configuration.bundleIdentifier,
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": configuration.productName,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": configuration.shortVersion,
            "CFBundleVersion": configuration.buildVersion,
            "LSRequiresIPhoneOS": true,
            "MinimumOSVersion": configuration.minimumOSVersion,
            "UIDeviceFamily": [1, 2],
            "UILaunchScreen": [:] as [String: Any],
            "UISupportedInterfaceOrientations": [
                "UIInterfaceOrientationPortrait",
                "UIInterfaceOrientationLandscapeLeft",
                "UIInterfaceOrientationLandscapeRight",
            ],
            "UISupportedInterfaceOrientations~ipad": [
                "UIInterfaceOrientationPortrait",
                "UIInterfaceOrientationPortraitUpsideDown",
                "UIInterfaceOrientationLandscapeLeft",
                "UIInterfaceOrientationLandscapeRight",
            ],
        ]

        plist.merge(additional) { _, custom in custom }
        plist["CFBundleExecutable"] = configuration.executableName
        plist["CFBundleIdentifier"] = configuration.bundleIdentifier
        plist["CFBundlePackageType"] = "APPL"
        plist["MinimumOSVersion"] = configuration.minimumOSVersion

        return try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
    }

    public enum PackagerError: Error, CustomStringConvertible {
        case missingInput(String)
        case invalidArchivePath(String)
        case fileTooLarge(String)
        case archiveTooLarge
        case compressionFailed(String)
        case invalidArchive(String)

        public var description: String {
            switch self {
            case .missingInput(let path):
                return "missing IPA input: \(path)"
            case .invalidArchivePath(let path):
                return "invalid IPA archive path: \(path)"
            case .fileTooLarge(let path):
                return "ZIP32 cannot package a file larger than 4 GiB: \(path)"
            case .archiveTooLarge:
                return "ZIP32 archive exceeded 4 GiB"
            case .compressionFailed(let path):
                return "failed to deflate IPA input: \(path)"
            case .invalidArchive(let reason):
                return "invalid IPA archive: \(reason)"
            }
        }
    }
}

private enum VerifiedZIP {
    private static let utf8Flag: UInt16 = 0x0800
    private static let storedMethod: UInt16 = 0
    private static let deflateMethod: UInt16 = 8
    private static let ioBufferSize = 1024 * 1024

    enum Entry {
        case file(sourceURL: URL, archivePath: String, unixMode: UInt32)
        case data(Data, archivePath: String, unixMode: UInt32)

        var archivePath: String {
            switch self {
            case .file(_, let path, _), .data(_, let path, _): return path
            }
        }

        var unixMode: UInt32 {
            switch self {
            case .file(_, _, let mode), .data(_, _, let mode): return mode
            }
        }
    }

    private struct PreparedEntry {
        let sourceURL: URL?
        let inlineData: Data?
        let archivePath: String
        let unixMode: UInt32
        let method: UInt16
        let crc32: UInt32
        let compressedSize: UInt32
        let uncompressedSize: UInt32
        let dosTime: UInt16
        let dosDate: UInt16
        var localHeaderOffset: UInt32 = 0
    }

    private struct Digest {
        let crc32: UInt32
        let size: UInt64
    }

    static func write(entries: [Entry], to outputURL: URL) throws {
        guard entries.count <= Int(UInt16.max) else {
            throw MobileIPAPackager.PackagerError.archiveTooLarge
        }

        let fm = FileManager.default
        let staging = outputURL.deletingLastPathComponent()
            .appendingPathComponent(".xtool-zip-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        var prepared: [PreparedEntry] = []
        prepared.reserveCapacity(entries.count)

        for (index, entry) in entries.enumerated() {
            let (dosTime, dosDate) = dosTimestamp(Date())

            switch entry {
            case .data(let data, let archivePath, let unixMode):
                guard data.count <= Int(UInt32.max) else {
                    throw MobileIPAPackager.PackagerError.archiveTooLarge
                }
                let size = UInt32(data.count)
                prepared.append(
                    PreparedEntry(
                        sourceURL: nil,
                        inlineData: data,
                        archivePath: archivePath,
                        unixMode: unixMode,
                        method: storedMethod,
                        crc32: CRC32.checksum(data),
                        compressedSize: size,
                        uncompressedSize: size,
                        dosTime: dosTime,
                        dosDate: dosDate
                    )
                )

            case .file(let sourceURL, let archivePath, let unixMode):
                let attributes = try fm.attributesOfItem(atPath: sourceURL.path)
                let fileSize = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
                guard fileSize <= UInt64(UInt32.max) else {
                    throw MobileIPAPackager.PackagerError.fileTooLarge(sourceURL.path)
                }

                let sourceDigest = try digestFile(sourceURL)
                guard sourceDigest.size == fileSize else {
                    throw MobileIPAPackager.PackagerError.invalidArchive(
                        "source changed while packaging: \(sourceURL.lastPathComponent)"
                    )
                }

                #if canImport(Compression)
                if shouldDeflate(sourceURL, size: fileSize) {
                    let compressedURL = staging.appendingPathComponent("entry-\(index).deflate")
                    do {
                        let encoded = try encodeDeflate(sourceURL, to: compressedURL, expectedSize: fileSize)
                        let decoded = try decodeDigest(compressedURL)
                        let compressedSize = ((try fm.attributesOfItem(atPath: compressedURL.path)[.size]) as? NSNumber)?
                            .uint64Value ?? 0

                        if encoded.size == fileSize,
                           encoded.crc32 == sourceDigest.crc32,
                           decoded.size == fileSize,
                           decoded.crc32 == sourceDigest.crc32,
                           compressedSize > 0,
                           compressedSize <= UInt64(UInt32.max) {
                            prepared.append(
                                PreparedEntry(
                                    sourceURL: compressedURL,
                                    inlineData: nil,
                                    archivePath: archivePath,
                                    unixMode: unixMode,
                                    method: deflateMethod,
                                    crc32: sourceDigest.crc32,
                                    compressedSize: UInt32(compressedSize),
                                    uncompressedSize: UInt32(fileSize),
                                    dosTime: dosTime,
                                    dosDate: dosDate
                                )
                            )
                            continue
                        }
                    } catch {
                        // Compression is an optimization, not a correctness requirement.
                        // If encoding or verification fails, store this entry verbatim.
                        try? fm.removeItem(at: compressedURL)
                    }
                }
                #endif

                prepared.append(
                    PreparedEntry(
                        sourceURL: sourceURL,
                        inlineData: nil,
                        archivePath: archivePath,
                        unixMode: unixMode,
                        method: storedMethod,
                        crc32: sourceDigest.crc32,
                        compressedSize: UInt32(fileSize),
                        uncompressedSize: UInt32(fileSize),
                        dosTime: dosTime,
                        dosDate: dosDate
                    )
                )
            }
        }

        _ = fm.createFile(atPath: outputURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }

        var offset: UInt64 = 0
        for index in prepared.indices {
            guard offset <= UInt64(UInt32.max) else {
                throw MobileIPAPackager.PackagerError.archiveTooLarge
            }
            prepared[index].localHeaderOffset = UInt32(offset)
            let nameData = Data(prepared[index].archivePath.utf8)
            guard nameData.count <= Int(UInt16.max) else {
                throw MobileIPAPackager.PackagerError.invalidArchivePath(prepared[index].archivePath)
            }

            let header = localHeader(entry: prepared[index], nameData: nameData)
            try output.write(contentsOf: header)
            offset += UInt64(header.count)

            if let data = prepared[index].inlineData {
                try output.write(contentsOf: data)
                offset += UInt64(data.count)
            } else if let sourceURL = prepared[index].sourceURL {
                let written = try copyFile(sourceURL, to: output)
                guard written == UInt64(prepared[index].compressedSize) else {
                    throw MobileIPAPackager.PackagerError.invalidArchive(
                        "archive input changed while writing: \(prepared[index].archivePath)"
                    )
                }
                offset += written
            }
        }

        guard offset <= UInt64(UInt32.max) else {
            throw MobileIPAPackager.PackagerError.archiveTooLarge
        }
        let centralStart = UInt32(offset)

        for entry in prepared {
            let nameData = Data(entry.archivePath.utf8)
            var header = Data()
            header.appendLE(UInt32(0x02014b50))
            header.appendLE(UInt16(0x031E))
            header.appendLE(UInt16(20))
            header.appendLE(utf8Flag)
            header.appendLE(entry.method)
            header.appendLE(entry.dosTime)
            header.appendLE(entry.dosDate)
            header.appendLE(entry.crc32)
            header.appendLE(entry.compressedSize)
            header.appendLE(entry.uncompressedSize)
            header.appendLE(UInt16(nameData.count))
            header.appendLE(UInt16(0))
            header.appendLE(UInt16(0))
            header.appendLE(UInt16(0))
            header.appendLE(UInt16(0))
            header.appendLE(entry.unixMode << 16)
            header.appendLE(entry.localHeaderOffset)
            header.append(nameData)
            try output.write(contentsOf: header)
            offset += UInt64(header.count)
        }

        guard offset <= UInt64(UInt32.max) else {
            throw MobileIPAPackager.PackagerError.archiveTooLarge
        }
        let centralSize = UInt32(offset) - centralStart

        var end = Data()
        end.appendLE(UInt32(0x06054b50))
        end.appendLE(UInt16(0))
        end.appendLE(UInt16(0))
        end.appendLE(UInt16(prepared.count))
        end.appendLE(UInt16(prepared.count))
        end.appendLE(centralSize)
        end.appendLE(centralStart)
        end.appendLE(UInt16(0))
        try output.write(contentsOf: end)
        try output.synchronize()
    }

    private static func localHeader(entry: PreparedEntry, nameData: Data) -> Data {
        var header = Data()
        header.appendLE(UInt32(0x04034b50))
        header.appendLE(UInt16(20))
        header.appendLE(utf8Flag)
        header.appendLE(entry.method)
        header.appendLE(entry.dosTime)
        header.appendLE(entry.dosDate)
        header.appendLE(entry.crc32)
        header.appendLE(entry.compressedSize)
        header.appendLE(entry.uncompressedSize)
        header.appendLE(UInt16(nameData.count))
        header.appendLE(UInt16(0))
        header.append(nameData)
        return header
    }

    private static func copyFile(_ url: URL, to output: FileHandle) throws -> UInt64 {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var total: UInt64 = 0
        while true {
            let chunk = try input.read(upToCount: ioBufferSize) ?? Data()
            if chunk.isEmpty { break }
            try output.write(contentsOf: chunk)
            total += UInt64(chunk.count)
        }
        return total
    }

    private static func digestFile(_ url: URL) throws -> Digest {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var crc = CRC32.initial
        var size: UInt64 = 0
        while true {
            let chunk = try input.read(upToCount: ioBufferSize) ?? Data()
            if chunk.isEmpty { break }
            crc = CRC32.update(crc, with: chunk)
            size += UInt64(chunk.count)
            guard size <= UInt64(UInt32.max) else {
                throw MobileIPAPackager.PackagerError.fileTooLarge(url.path)
            }
        }
        return Digest(crc32: CRC32.finalize(crc), size: size)
    }

    private static func shouldDeflate(_ url: URL, size: UInt64) -> Bool {
        guard size >= 4 * 1024 else { return false }
        let alreadyCompressed = Set([
            "7z", "aac", "bz2", "gif", "gz", "heic", "heif", "ipa", "jpeg", "jpg",
            "lz4", "m4a", "mov", "mp3", "mp4", "pdf", "png", "webp", "xz", "zip",
        ])
        return !alreadyCompressed.contains(url.pathExtension.lowercased())
    }

    #if canImport(Compression)
    private static func encodeDeflate(
        _ sourceURL: URL,
        to destinationURL: URL,
        expectedSize: UInt64
    ) throws -> Digest {
        let fm = FileManager.default
        _ = fm.createFile(atPath: destinationURL.path, contents: nil)
        let input = try FileHandle(forReadingFrom: sourceURL)
        let output = try FileHandle(forWritingTo: destinationURL)
        defer {
            try? input.close()
            try? output.close()
        }

        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: ioBufferSize)
        defer { destination.deallocate() }

        var stream = compression_stream(
            dst_ptr: destination,
            dst_size: ioBufferSize,
            src_ptr: UnsafePointer(destination),
            src_size: 0,
            state: nil
        )
        guard compression_stream_init(&stream, COMPRESSION_STREAM_ENCODE, COMPRESSION_ZLIB)
                != COMPRESSION_STATUS_ERROR else {
            throw MobileIPAPackager.PackagerError.compressionFailed(sourceURL.path)
        }
        defer { compression_stream_destroy(&stream) }

        var sourceData = Data()
        var status = COMPRESSION_STATUS_OK
        var flags: Int32 = 0
        var totalRead: UInt64 = 0
        var crc = CRC32.initial

        while status == COMPRESSION_STATUS_OK {
            if stream.src_size == 0 {
                sourceData = try input.read(upToCount: ioBufferSize) ?? Data()
                if !sourceData.isEmpty {
                    crc = CRC32.update(crc, with: sourceData)
                    totalRead += UInt64(sourceData.count)
                    guard totalRead <= expectedSize else {
                        throw MobileIPAPackager.PackagerError.invalidArchive(
                            "source grew while compressing: \(sourceURL.lastPathComponent)"
                        )
                    }
                }
                stream.src_size = sourceData.count
                flags = totalRead == expectedSize
                    ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
                    : 0
            }

            sourceData.withUnsafeBytes { rawBuffer in
                if let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress {
                    stream.src_ptr = base.advanced(by: sourceData.count - stream.src_size)
                } else {
                    stream.src_ptr = UnsafePointer(destination)
                }
                status = compression_stream_process(&stream, flags)
            }

            switch status {
            case COMPRESSION_STATUS_OK, COMPRESSION_STATUS_END:
                let produced = ioBufferSize - stream.dst_size
                if produced > 0 {
                    try output.write(contentsOf: Data(bytes: destination, count: produced))
                }
                stream.dst_ptr = destination
                stream.dst_size = ioBufferSize
            default:
                throw MobileIPAPackager.PackagerError.compressionFailed(sourceURL.path)
            }
        }

        guard status == COMPRESSION_STATUS_END, totalRead == expectedSize else {
            throw MobileIPAPackager.PackagerError.compressionFailed(sourceURL.path)
        }
        try output.synchronize()
        return Digest(crc32: CRC32.finalize(crc), size: totalRead)
    }

    private static func decodeDigest(_ compressedURL: URL) throws -> Digest {
        let input = try FileHandle(forReadingFrom: compressedURL)
        defer { try? input.close() }

        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: ioBufferSize)
        defer { destination.deallocate() }

        var stream = compression_stream(
            dst_ptr: destination,
            dst_size: ioBufferSize,
            src_ptr: UnsafePointer(destination),
            src_size: 0,
            state: nil
        )
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
                != COMPRESSION_STATUS_ERROR else {
            throw MobileIPAPackager.PackagerError.compressionFailed(compressedURL.path)
        }
        defer { compression_stream_destroy(&stream) }

        let compressedSize = ((try FileManager.default.attributesOfItem(atPath: compressedURL.path)[.size]) as? NSNumber)?
            .uint64Value ?? 0
        var sourceData = Data()
        var status = COMPRESSION_STATUS_OK
        var totalInput: UInt64 = 0
        var decodedSize: UInt64 = 0
        var crc = CRC32.initial

        while status == COMPRESSION_STATUS_OK {
            if stream.src_size == 0 {
                sourceData = try input.read(upToCount: ioBufferSize) ?? Data()
                totalInput += UInt64(sourceData.count)
                stream.src_size = sourceData.count
            }

            sourceData.withUnsafeBytes { rawBuffer in
                if let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress {
                    stream.src_ptr = base.advanced(by: sourceData.count - stream.src_size)
                } else {
                    stream.src_ptr = UnsafePointer(destination)
                }
                let flags = totalInput == compressedSize
                    ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
                    : 0
                status = compression_stream_process(&stream, flags)
            }

            switch status {
            case COMPRESSION_STATUS_OK, COMPRESSION_STATUS_END:
                let produced = ioBufferSize - stream.dst_size
                if produced > 0 {
                    let data = Data(bytes: destination, count: produced)
                    crc = CRC32.update(crc, with: data)
                    decodedSize += UInt64(produced)
                    guard decodedSize <= UInt64(UInt32.max) else {
                        throw MobileIPAPackager.PackagerError.archiveTooLarge
                    }
                }
                stream.dst_ptr = destination
                stream.dst_size = ioBufferSize
            default:
                throw MobileIPAPackager.PackagerError.compressionFailed(compressedURL.path)
            }

            if sourceData.isEmpty && status == COMPRESSION_STATUS_OK {
                throw MobileIPAPackager.PackagerError.compressionFailed(compressedURL.path)
            }
        }

        guard status == COMPRESSION_STATUS_END else {
            throw MobileIPAPackager.PackagerError.compressionFailed(compressedURL.path)
        }
        return Digest(crc32: CRC32.finalize(crc), size: decodedSize)
    }
    #endif

    private static func dosTimestamp(_ date: Date) -> (UInt16, UInt16) {
        let calendar = Calendar(identifier: .gregorian)
        let parts = calendar.dateComponents(in: TimeZone.current, from: date)
        let year = min(max(parts.year ?? 1980, 1980), 2107)
        let month = min(max(parts.month ?? 1, 1), 12)
        let day = min(max(parts.day ?? 1, 1), 31)
        let hour = min(max(parts.hour ?? 0, 0), 23)
        let minute = min(max(parts.minute ?? 0, 0), 59)
        let second = min(max(parts.second ?? 0, 0), 59)
        return (
            UInt16((hour << 11) | (minute << 5) | (second / 2)),
            UInt16(((year - 1980) << 9) | (month << 5) | day)
        )
    }
}

private enum CRC32 {
    static let initial: UInt32 = 0xFFFF_FFFF

    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) != 0
                ? (value >> 1) ^ 0xEDB8_8320
                : value >> 1
        }
        return value
    }

    static func checksum(_ data: Data) -> UInt32 {
        finalize(update(initial, with: data))
    }

    static func update(_ crc: UInt32, with data: Data) -> UInt32 {
        var value = crc
        data.withUnsafeBytes { rawBuffer in
            for byte in rawBuffer.bindMemory(to: UInt8.self) {
                let tableIndex = Int((value ^ UInt32(byte)) & 0xFF)
                value = (value >> 8) ^ table[tableIndex]
            }
        }
        return value
    }

    static func finalize(_ crc: UInt32) -> UInt32 {
        crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { rawBuffer in
            append(contentsOf: rawBuffer)
        }
    }
}
