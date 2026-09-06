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
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: executableURL.path) else {
            throw PackagerError.missingInput(executableURL.path)
        }

        try MobileAppManifest.validateName(configuration.productName)
        try MobileAppManifest.validateName(configuration.executableName)
        let appRoot = "Payload/\(configuration.productName).app"
        let infoPlist = try makeInfoPlist(configuration: configuration, additional: additionalInfoPlist)
        var names: Set<String> = [configuration.executableName.lowercased(), "info.plist"]

        var entries: [StoreZIP.Entry] = [
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
            guard fileManager.fileExists(atPath: file.sourceURL.path) else {
                throw PackagerError.missingInput(file.sourceURL.path)
            }
            let relative = file.relativePath
            let key = relative.lowercased()
            guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.contains("\\"),
                  !relative.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
                  !names.contains(where: { $0 == key || $0.hasPrefix(key + "/") || key.hasPrefix($0 + "/") }) else {
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

        try fileManager.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Write alongside the destination; failures never expose a partial IPA.
        let temporary = outputURL.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).ipa")
        defer { try? fileManager.removeItem(at: temporary) }
        try StoreZIP.write(entries: entries, to: temporary)
        if fileManager.fileExists(atPath: outputURL.path) {
            _ = try fileManager.replaceItemAt(outputURL, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: outputURL)
        }
    }

    private static func makeInfoPlist(configuration: MobileIPAConfiguration, additional: [String: Any]) throws -> Data {
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
        // Identity and executable paths must agree with what was actually packaged.
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
            }
        }
    }
}

private enum StoreZIP {
    private static let utf8Flag: UInt16 = 0x0800
    private static let dataDescriptorFlag: UInt16 = 0x0008
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
        let unixMode: UInt32
        let nameData: Data
        let flags: UInt16
        let method: UInt16
        let crc32: UInt32
        let compressedSize: UInt32
        let uncompressedSize: UInt32
        let dosTime: UInt16
        let dosDate: UInt16
        let localHeaderOffset: UInt32
    }

    private struct StreamResult {
        let crc32: UInt32
        let compressedSize: UInt32
        let uncompressedSize: UInt32
    }

    static func write(entries: [Entry], to outputURL: URL) throws {
        guard entries.count <= Int(UInt16.max) else {
            throw MobileIPAPackager.PackagerError.archiveTooLarge
        }
        _ = FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: outputURL)
        defer { try? handle.close() }

        var offset: UInt64 = 0
        var prepared: [PreparedEntry] = []
        prepared.reserveCapacity(entries.count)

        for entry in entries {
            guard offset <= UInt64(UInt32.max) else {
                throw MobileIPAPackager.PackagerError.archiveTooLarge
            }
            let localHeaderOffset = UInt32(offset)
            let nameData = Data(entry.archivePath.utf8)
            guard nameData.count <= Int(UInt16.max) else {
                throw MobileIPAPackager.PackagerError.invalidArchivePath(entry.archivePath)
            }
            let (dosTime, dosDate) = dosTimestamp(Date())

            switch entry {
            case .data(let data, _, let unixMode):
                guard data.count <= Int(UInt32.max) else {
                    throw MobileIPAPackager.PackagerError.archiveTooLarge
                }
                let size = UInt32(data.count)
                let crc32 = CRC32.checksum(data)
                let header = localHeader(
                    nameData: nameData,
                    flags: utf8Flag,
                    method: storedMethod,
                    dosTime: dosTime,
                    dosDate: dosDate,
                    crc32: crc32,
                    compressedSize: size,
                    uncompressedSize: size
                )
                try handle.write(contentsOf: header)
                try handle.write(contentsOf: data)
                offset += UInt64(header.count) + UInt64(data.count)
                prepared.append(
                    PreparedEntry(
                        unixMode: unixMode,
                        nameData: nameData,
                        flags: utf8Flag,
                        method: storedMethod,
                        crc32: crc32,
                        compressedSize: size,
                        uncompressedSize: size,
                        dosTime: dosTime,
                        dosDate: dosDate,
                        localHeaderOffset: localHeaderOffset
                    )
                )

            case .file(let sourceURL, _, let unixMode):
                let attributes = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
                let fileSize = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
                guard fileSize <= UInt64(UInt32.max) else {
                    throw MobileIPAPackager.PackagerError.fileTooLarge(sourceURL.path)
                }

                let method = compressionMethod(for: sourceURL, size: fileSize)
                let flags = utf8Flag | dataDescriptorFlag
                let header = localHeader(
                    nameData: nameData,
                    flags: flags,
                    method: method,
                    dosTime: dosTime,
                    dosDate: dosDate,
                    crc32: 0,
                    compressedSize: 0,
                    uncompressedSize: 0
                )
                try handle.write(contentsOf: header)
                offset += UInt64(header.count)

                let result: StreamResult
                if method == deflateMethod {
                    #if canImport(Compression)
                    result = try streamDeflatedFile(sourceURL, to: handle)
                    #else
                    result = try streamStoredFile(sourceURL, to: handle)
                    #endif
                } else {
                    result = try streamStoredFile(sourceURL, to: handle)
                }
                offset += UInt64(result.compressedSize)

                let descriptor = dataDescriptor(
                    crc32: result.crc32,
                    compressedSize: result.compressedSize,
                    uncompressedSize: result.uncompressedSize
                )
                try handle.write(contentsOf: descriptor)
                offset += UInt64(descriptor.count)

                prepared.append(
                    PreparedEntry(
                        unixMode: unixMode,
                        nameData: nameData,
                        flags: flags,
                        method: method,
                        crc32: result.crc32,
                        compressedSize: result.compressedSize,
                        uncompressedSize: result.uncompressedSize,
                        dosTime: dosTime,
                        dosDate: dosDate,
                        localHeaderOffset: localHeaderOffset
                    )
                )
            }
        }

        guard offset <= UInt64(UInt32.max) else {
            throw MobileIPAPackager.PackagerError.archiveTooLarge
        }
        let centralStart = UInt32(offset)

        for item in prepared {
            var header = Data()
            header.appendLE(UInt32(0x02014b50))
            header.appendLE(UInt16(0x031E)) // created by UNIX, ZIP 3.0
            header.appendLE(UInt16(20))
            header.appendLE(item.flags)
            header.appendLE(item.method)
            header.appendLE(item.dosTime)
            header.appendLE(item.dosDate)
            header.appendLE(item.crc32)
            header.appendLE(item.compressedSize)
            header.appendLE(item.uncompressedSize)
            header.appendLE(UInt16(item.nameData.count))
            header.appendLE(UInt16(0))
            header.appendLE(UInt16(0))
            header.appendLE(UInt16(0))
            header.appendLE(UInt16(0))
            header.appendLE(item.unixMode << 16)
            header.appendLE(item.localHeaderOffset)
            header.append(item.nameData)
            try handle.write(contentsOf: header)
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
        try handle.write(contentsOf: end)
    }

    private static func localHeader(
        nameData: Data,
        flags: UInt16,
        method: UInt16,
        dosTime: UInt16,
        dosDate: UInt16,
        crc32: UInt32,
        compressedSize: UInt32,
        uncompressedSize: UInt32
    ) -> Data {
        var header = Data()
        header.appendLE(UInt32(0x04034b50))
        header.appendLE(UInt16(20))
        header.appendLE(flags)
        header.appendLE(method)
        header.appendLE(dosTime)
        header.appendLE(dosDate)
        header.appendLE(crc32)
        header.appendLE(compressedSize)
        header.appendLE(uncompressedSize)
        header.appendLE(UInt16(nameData.count))
        header.appendLE(UInt16(0))
        header.append(nameData)
        return header
    }

    private static func dataDescriptor(
        crc32: UInt32,
        compressedSize: UInt32,
        uncompressedSize: UInt32
    ) -> Data {
        var descriptor = Data()
        descriptor.appendLE(UInt32(0x08074b50))
        descriptor.appendLE(crc32)
        descriptor.appendLE(compressedSize)
        descriptor.appendLE(uncompressedSize)
        return descriptor
    }

    private static func compressionMethod(for url: URL, size: UInt64) -> UInt16 {
        #if canImport(Compression)
        guard size >= 4 * 1024 else { return storedMethod }
        let alreadyCompressed = Set([
            "7z", "aac", "bz2", "gif", "gz", "heic", "heif", "ipa", "jpeg", "jpg",
            "lz4", "m4a", "mov", "mp3", "mp4", "pdf", "png", "webp", "xz", "zip",
        ])
        return alreadyCompressed.contains(url.pathExtension.lowercased()) ? storedMethod : deflateMethod
        #else
        return storedMethod
        #endif
    }

    private static func streamStoredFile(_ url: URL, to output: FileHandle) throws -> StreamResult {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var crc = CRC32.initial
        var total: UInt64 = 0

        while true {
            let chunk = try input.read(upToCount: ioBufferSize) ?? Data()
            if chunk.isEmpty { break }
            crc = CRC32.update(crc, with: chunk)
            try output.write(contentsOf: chunk)
            total += UInt64(chunk.count)
            guard total <= UInt64(UInt32.max) else {
                throw MobileIPAPackager.PackagerError.fileTooLarge(url.path)
            }
        }

        let size = UInt32(total)
        return StreamResult(
            crc32: CRC32.finalize(crc),
            compressedSize: size,
            uncompressedSize: size
        )
    }

    #if canImport(Compression)
    private static func streamDeflatedFile(_ url: URL, to output: FileHandle) throws -> StreamResult {
        let input = try FileHandle(forReadingFrom: url)
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
        var status = compression_stream_init(&stream, COMPRESSION_STREAM_ENCODE, COMPRESSION_ZLIB)
        guard status != COMPRESSION_STATUS_ERROR else {
            throw MobileIPAPackager.PackagerError.compressionFailed(url.path)
        }
        defer { compression_stream_destroy(&stream) }

        stream.src_size = 0
        stream.dst_ptr = destination
        stream.dst_size = ioBufferSize

        var sourceData = Data()
        var crc = CRC32.initial
        var uncompressed: UInt64 = 0
        var compressed: UInt64 = 0

        repeat {
            let needsInput = stream.src_size == 0
            if needsInput {
                sourceData = try input.read(upToCount: ioBufferSize) ?? Data()
                if !sourceData.isEmpty {
                    crc = CRC32.update(crc, with: sourceData)
                    uncompressed += UInt64(sourceData.count)
                    guard uncompressed <= UInt64(UInt32.max) else {
                        throw MobileIPAPackager.PackagerError.fileTooLarge(url.path)
                    }
                }
            }

            sourceData.withUnsafeBytes { rawBuffer in
                if let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress {
                    stream.src_ptr = baseAddress.advanced(by: sourceData.count - stream.src_size)
                } else {
                    stream.src_ptr = UnsafePointer(destination)
                }
                let flags = sourceData.count < ioBufferSize
                    ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
                    : 0
                status = compression_stream_process(&stream, flags)
            }

            switch status {
            case COMPRESSION_STATUS_OK, COMPRESSION_STATUS_END:
                let produced = ioBufferSize - stream.dst_size
                if produced > 0 {
                    let data = Data(bytesNoCopy: destination, count: produced, deallocator: .none)
                    try output.write(contentsOf: data)
                    compressed += UInt64(produced)
                    guard compressed <= UInt64(UInt32.max) else {
                        throw MobileIPAPackager.PackagerError.archiveTooLarge
                    }
                }
                stream.dst_ptr = destination
                stream.dst_size = ioBufferSize
            default:
                throw MobileIPAPackager.PackagerError.compressionFailed(url.path)
            }
        } while status == COMPRESSION_STATUS_OK

        return StreamResult(
            crc32: CRC32.finalize(crc),
            compressedSize: UInt32(compressed),
            uncompressedSize: UInt32(uncompressed)
        )
    }
    #endif

    private static func dosTimestamp(_ date: Date) -> (UInt16, UInt16) {
        let calendar = Calendar(identifier: .gregorian)
        let parts = calendar.dateComponents(
            in: TimeZone.current,
            from: date
        )
        let year = min(max(parts.year ?? 1980, 1980), 2107)
        let month = min(max(parts.month ?? 1, 1), 12)
        let day = min(max(parts.day ?? 1, 1), 31)
        let hour = min(max(parts.hour ?? 0, 0), 23)
        let minute = min(max(parts.minute ?? 0, 0), 59)
        let second = min(max(parts.second ?? 0, 0), 59)

        let dosTime = UInt16((hour << 11) | (minute << 5) | (second / 2))
        let dosDate = UInt16(((year - 1980) << 9) | (month << 5) | day)
        return (dosTime, dosDate)
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
