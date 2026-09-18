import Foundation
#if canImport(Compression)
import Compression
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif

struct ResolvedMobileBinaryFramework: Sendable {
    let name: String
    let frameworkURL: URL

    var searchPath: URL { frameworkURL.deletingLastPathComponent() }
}

enum MobileBinaryFrameworkResolver {
    static func resolve(
        _ specifications: [MobileAppManifest.BinaryFramework],
        cacheDirectory: URL,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) throws -> [ResolvedMobileBinaryFramework] {
        guard !specifications.isEmpty else { return [] }

        let fm = FileManager.default
        let cacheRoot = cacheDirectory.appendingPathComponent("binary-frameworks", isDirectory: true)
        try fm.createDirectory(at: cacheRoot, withIntermediateDirectories: true)

        return try specifications.map { specification in
            let checksum = specification.checksum.lowercased()
            let artifactRoot = cacheRoot.appendingPathComponent(checksum, isDirectory: true)
            let marker = artifactRoot.appendingPathComponent("resolved-framework.txt")

            if let relativePath = try? String(contentsOf: marker, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !relativePath.isEmpty {
                let cached = artifactRoot.appendingPathComponent(relativePath)
                if fm.fileExists(atPath: cached.path) {
                    log("Binary framework cache hit: \(specification.name)")
                    return ResolvedMobileBinaryFramework(name: specification.name, frameworkURL: cached)
                }
            }

            guard let remoteURL = URL(string: specification.url),
                  remoteURL.scheme?.lowercased() == "https" else {
                throw MobileProjectBuildError.invalid(
                    "Binary framework \(specification.name) has an invalid HTTPS URL"
                )
            }

            let temporary = cacheRoot.appendingPathComponent(".\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: temporary) }

            log("Downloading binary framework: \(specification.name)")
            let archiveData: Data
            do {
                archiveData = try Data(contentsOf: remoteURL)
            } catch {
                throw MobileProjectBuildError.invalid(
                    "Could not download \(specification.name): \(error.localizedDescription)"
                )
            }

            let actualChecksum = MobileSHA256.hexDigest(archiveData)
            guard actualChecksum == checksum else {
                throw MobileProjectBuildError.invalid(
                    "SHA-256 mismatch for \(specification.name): expected \(checksum), got \(actualChecksum)"
                )
            }
            log("Verified SHA-256: \(specification.name)")

            let archiveURL = temporary.appendingPathComponent("artifact.zip")
            try archiveData.write(to: archiveURL, options: .atomic)
            let extracted = temporary.appendingPathComponent("extracted", isDirectory: true)
            try fm.createDirectory(at: extracted, withIntermediateDirectories: true)
            try MobileZIPExtractor.extract(archiveData, to: extracted)

            let xcframework = try findXCFramework(in: extracted, fileManager: fm)
            let framework = try selectDeviceFramework(
                in: xcframework,
                expectedName: specification.name,
                fileManager: fm
            )

            // iOS commonly exposes app-container paths through both /var/... and
            // /private/var/.... FileManager enumeration may return the canonical
            // /private/var spelling even when the extraction URL was created from
            // /var, so compare canonical paths while both locations still exist.
            let canonicalExtractedPath = extracted
                .resolvingSymlinksInPath()
                .standardizedFileURL
                .path
            let canonicalFrameworkPath = framework
                .resolvingSymlinksInPath()
                .standardizedFileURL
                .path
            guard canonicalFrameworkPath.hasPrefix(canonicalExtractedPath + "/") else {
                throw MobileProjectBuildError.invalid("Resolved framework escaped extraction root")
            }
            let relative = String(canonicalFrameworkPath.dropFirst(canonicalExtractedPath.count + 1))

            if fm.fileExists(atPath: artifactRoot.path) {
                try fm.removeItem(at: artifactRoot)
            }
            try fm.createDirectory(at: artifactRoot.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: extracted, to: artifactRoot)

            let finalFramework = artifactRoot.appendingPathComponent(relative)
            guard fm.fileExists(atPath: finalFramework.path) else {
                throw MobileProjectBuildError.invalid(
                    "Resolved framework disappeared while caching \(specification.name)"
                )
            }
            try (relative + "\n").write(to: marker, atomically: true, encoding: .utf8)
            log("Resolved arm64 iOS framework: \(specification.name)")
            return ResolvedMobileBinaryFramework(name: specification.name, frameworkURL: finalFramework)
        }
    }

    private static func findXCFramework(in root: URL, fileManager: FileManager) throws -> URL {
        if root.pathExtension.lowercased() == "xcframework" { return root }
        guard let walker = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw MobileProjectBuildError.invalid("Could not inspect extracted binary framework archive")
        }
        var matches: [URL] = []
        for case let item as URL in walker where item.pathExtension.lowercased() == "xcframework" {
            matches.append(item)
            walker.skipDescendants()
        }
        guard matches.count == 1, let result = matches.first else {
            throw MobileProjectBuildError.invalid(
                "Expected exactly one XCFramework in binary archive, found \(matches.count)"
            )
        }
        return result
    }

    private static func selectDeviceFramework(
        in xcframework: URL,
        expectedName: String,
        fileManager: FileManager
    ) throws -> URL {
        let infoURL = xcframework.appendingPathComponent("Info.plist")
        let data = try Data(contentsOf: infoURL)
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let libraries = plist["AvailableLibraries"] as? [[String: Any]] else {
            throw MobileProjectBuildError.invalid("Invalid XCFramework Info.plist for \(expectedName)")
        }

        let candidates = libraries.filter { library in
            guard (library["SupportedPlatform"] as? String) == "ios",
                  let architectures = library["SupportedArchitectures"] as? [String],
                  architectures.contains("arm64") else { return false }
            if let variant = library["SupportedPlatformVariant"] as? String,
               !variant.isEmpty {
                return false
            }
            return true
        }

        guard candidates.count == 1,
              let library = candidates.first,
              let identifier = library["LibraryIdentifier"] as? String,
              let libraryPath = library["LibraryPath"] as? String else {
            throw MobileProjectBuildError.invalid(
                "Could not select one arm64 iOS device slice for \(expectedName)"
            )
        }

        let root = xcframework.standardizedFileURL
        let sliceRoot = xcframework
            .appendingPathComponent(identifier, isDirectory: true)
            .standardizedFileURL
        let libraryURL = sliceRoot
            .appendingPathComponent(libraryPath)
            .standardizedFileURL
        guard libraryURL.path.hasPrefix(root.path + "/"),
              fileManager.fileExists(atPath: libraryURL.path) else {
            throw MobileProjectBuildError.invalid(
                "XCFramework slice for \(expectedName) points to a missing library"
            )
        }

        if libraryURL.pathExtension.lowercased() == "framework" {
            return libraryURL
        }

        // SwiftPM binary targets frequently ship static XCFramework slices as a
        // .a plus HeadersPath (for example CArchive/libarchive). The rest of
        // XTool Mobile already understands framework search/link flags, so wrap
        // the selected static archive in a small framework-shaped directory.
        // The binary remains a static archive; this only supplies the standard
        // Framework/Headers layout expected by Clang and LLD.
        if libraryURL.pathExtension.lowercased() == "a" {
            guard let headersPath = library["HeadersPath"] as? String,
                  !headersPath.isEmpty else {
                throw MobileProjectBuildError.invalid(
                    "Static XCFramework slice for \(expectedName) has no HeadersPath"
                )
            }
            let headersURL = sliceRoot
                .appendingPathComponent(headersPath, isDirectory: true)
                .standardizedFileURL
            guard headersURL.path.hasPrefix(sliceRoot.path + "/") else {
                throw MobileProjectBuildError.invalid(
                    "Static XCFramework headers escaped the selected slice for \(expectedName)"
                )
            }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: headersURL.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw MobileProjectBuildError.invalid(
                    "Static XCFramework headers are missing for \(expectedName)"
                )
            }

            let wrapperRoot = sliceRoot.appendingPathComponent("XToolStaticFrameworks", isDirectory: true)
            let framework = wrapperRoot.appendingPathComponent("\(expectedName).framework", isDirectory: true)
            let frameworkBinary = framework.appendingPathComponent(expectedName)
            let frameworkHeaders = framework.appendingPathComponent("Headers", isDirectory: true)

            try fileManager.createDirectory(at: wrapperRoot, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: framework.path) {
                try fileManager.removeItem(at: framework)
            }
            try fileManager.createDirectory(at: framework, withIntermediateDirectories: true)
            try fileManager.copyItem(at: libraryURL, to: frameworkBinary)
            try fileManager.copyItem(at: headersURL, to: frameworkHeaders)
            return framework
        }

        throw MobileProjectBuildError.invalid(
            "XCFramework slice for \(expectedName) is neither a .framework nor a static .a library"
        )
    }
}

private enum MobileZIPExtractor {
    private struct Entry {
        let path: String
        let method: UInt16
        let flags: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
        let externalAttributes: UInt32
    }

    static func extract(_ archive: Data, to destination: URL) throws {
        let bytes = [UInt8](archive)
        guard let eocd = findEOCD(bytes) else {
            throw MobileProjectBuildError.invalid("Binary framework archive is not a supported ZIP file")
        }

        let disk = Int(read16(bytes, eocd + 4))
        let centralDisk = Int(read16(bytes, eocd + 6))
        let entriesOnDisk = Int(read16(bytes, eocd + 8))
        let entryCount = Int(read16(bytes, eocd + 10))
        let centralSize = Int(read32(bytes, eocd + 12))
        let centralOffset = Int(read32(bytes, eocd + 16))
        guard disk == 0, centralDisk == 0, entriesOnDisk == entryCount,
              centralOffset >= 0, centralSize >= 0,
              centralOffset + centralSize <= bytes.count else {
            throw MobileProjectBuildError.invalid("Multi-disk or ZIP64 binary archives are not supported")
        }

        var entries: [Entry] = []
        entries.reserveCapacity(entryCount)
        var cursor = centralOffset
        for _ in 0..<entryCount {
            guard cursor + 46 <= bytes.count, read32(bytes, cursor) == 0x02014b50 else {
                throw MobileProjectBuildError.invalid("Corrupt ZIP central directory")
            }
            let flags = read16(bytes, cursor + 8)
            let method = read16(bytes, cursor + 10)
            let compressed = read32(bytes, cursor + 20)
            let uncompressed = read32(bytes, cursor + 24)
            let nameLength = Int(read16(bytes, cursor + 28))
            let extraLength = Int(read16(bytes, cursor + 30))
            let commentLength = Int(read16(bytes, cursor + 32))
            let externalAttributes = read32(bytes, cursor + 38)
            let localOffset = read32(bytes, cursor + 42)
            guard compressed != UInt32.max, uncompressed != UInt32.max, localOffset != UInt32.max else {
                throw MobileProjectBuildError.invalid("ZIP64 binary archives are not supported")
            }
            let end = cursor + 46 + nameLength + extraLength + commentLength
            guard nameLength > 0, end <= bytes.count else {
                throw MobileProjectBuildError.invalid("Corrupt ZIP entry metadata")
            }
            let nameData = Data(bytes[(cursor + 46)..<(cursor + 46 + nameLength)])
            guard let name = String(data: nameData, encoding: .utf8) else {
                throw MobileProjectBuildError.invalid("Binary archive contains a non-UTF8 path")
            }
            entries.append(
                Entry(
                    path: name,
                    method: method,
                    flags: flags,
                    compressedSize: Int(compressed),
                    uncompressedSize: Int(uncompressed),
                    localHeaderOffset: Int(localOffset),
                    externalAttributes: externalAttributes
                )
            )
            cursor = end
        }

        let fm = FileManager.default
        let root = destination.standardizedFileURL
        for entry in entries {
            guard (entry.flags & 0x0001) == 0 else {
                throw MobileProjectBuildError.invalid("Encrypted ZIP entries are not supported")
            }
            let components = entry.path.split(separator: "/", omittingEmptySubsequences: false)
            guard !entry.path.hasPrefix("/"), !entry.path.contains("\\"),
                  !components.contains(where: { $0 == ".." || $0 == "." }) else {
                throw MobileProjectBuildError.invalid("Unsafe path in binary archive: \(entry.path)")
            }

            let unixMode = UInt16((entry.externalAttributes >> 16) & 0xffff)
            let fileType = unixMode & 0o170000
            guard fileType != 0o120000 else {
                throw MobileProjectBuildError.invalid("Symlinks are not allowed in binary framework archives")
            }

            let output = root.appendingPathComponent(entry.path).standardizedFileURL
            guard output.path == root.path || output.path.hasPrefix(root.path + "/") else {
                throw MobileProjectBuildError.invalid("Unsafe path in binary archive: \(entry.path)")
            }
            let isDirectory = entry.path.hasSuffix("/") || fileType == 0o040000
            if isDirectory {
                try fm.createDirectory(at: output, withIntermediateDirectories: true)
                continue
            }

            let local = entry.localHeaderOffset
            guard local + 30 <= bytes.count, read32(bytes, local) == 0x04034b50 else {
                throw MobileProjectBuildError.invalid("Corrupt ZIP local header for \(entry.path)")
            }
            let localNameLength = Int(read16(bytes, local + 26))
            let localExtraLength = Int(read16(bytes, local + 28))
            let dataStart = local + 30 + localNameLength + localExtraLength
            let dataEnd = dataStart + entry.compressedSize
            guard dataStart >= 0, dataEnd <= bytes.count else {
                throw MobileProjectBuildError.invalid("Corrupt ZIP payload for \(entry.path)")
            }

            let compressedData = Data(bytes[dataStart..<dataEnd])
            let decoded: Data
            switch entry.method {
            case 0:
                decoded = compressedData
            case 8:
                decoded = try inflate(compressedData, expectedSize: entry.uncompressedSize, path: entry.path)
            default:
                throw MobileProjectBuildError.invalid(
                    "Unsupported ZIP compression method \(entry.method) for \(entry.path)"
                )
            }
            guard decoded.count == entry.uncompressedSize else {
                throw MobileProjectBuildError.invalid("ZIP size mismatch for \(entry.path)")
            }
            try fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try decoded.write(to: output, options: .atomic)
        }
    }

    private static func findEOCD(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 22 else { return nil }
        let minimum = max(0, bytes.count - 22 - Int(UInt16.max))
        var index = bytes.count - 22
        while index >= minimum {
            if read32(bytes, index) == 0x06054b50 { return index }
            if index == 0 { break }
            index -= 1
        }
        return nil
    }

    private static func inflate(_ data: Data, expectedSize: Int, path: String) throws -> Data {
        guard expectedSize >= 0 else {
            throw MobileProjectBuildError.invalid("Invalid ZIP size for \(path)")
        }
        if expectedSize == 0 { return Data() }
        #if canImport(Compression)
        var output = Data(count: expectedSize)
        let decodedCount: Int = output.withUnsafeMutableBytes { outputBuffer in
            data.withUnsafeBytes { inputBuffer in
                guard let outputBase = outputBuffer.bindMemory(to: UInt8.self).baseAddress,
                      let inputBase = inputBuffer.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(
                    outputBase,
                    expectedSize,
                    inputBase,
                    data.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard decodedCount == expectedSize else {
            throw MobileProjectBuildError.invalid("Could not inflate ZIP entry \(path)")
        }
        return output
        #else
        throw MobileProjectBuildError.invalid(
            "Deflated XCFramework archives require Apple's Compression framework"
        )
        #endif
    }

    private static func read16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func read32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }
}

private enum MobileSHA256 {
    static func hexDigest(_ data: Data) -> String {
        #if canImport(CryptoKit)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #else
        return fallback(data).map { String(format: "%02x", $0) }.joined()
        #endif
    }

    #if !canImport(CryptoKit)
    private static let initial: [UInt32] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    ]
    private static let constants: [UInt32] = [
        0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
        0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
        0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
        0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
        0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
        0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
        0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
        0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2,
    ]

    private static func fallback(_ data: Data) -> [UInt8] {
        var message = [UInt8](data)
        let bitLength = UInt64(message.count) * 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            message.append(UInt8((bitLength >> UInt64(shift)) & 0xff))
        }

        var hash = initial
        var words = [UInt32](repeating: 0, count: 64)
        for chunkStart in stride(from: 0, to: message.count, by: 64) {
            for index in 0..<16 {
                let offset = chunkStart + index * 4
                words[index] = (UInt32(message[offset]) << 24)
                    | (UInt32(message[offset + 1]) << 16)
                    | (UInt32(message[offset + 2]) << 8)
                    | UInt32(message[offset + 3])
            }
            for index in 16..<64 {
                let s0 = rotateRight(words[index - 15], 7) ^ rotateRight(words[index - 15], 18) ^ (words[index - 15] >> 3)
                let s1 = rotateRight(words[index - 2], 17) ^ rotateRight(words[index - 2], 19) ^ (words[index - 2] >> 10)
                words[index] = words[index - 16] &+ s0 &+ words[index - 7] &+ s1
            }

            var a = hash[0], b = hash[1], c = hash[2], d = hash[3]
            var e = hash[4], f = hash[5], g = hash[6], h = hash[7]
            for index in 0..<64 {
                let s1 = rotateRight(e, 6) ^ rotateRight(e, 11) ^ rotateRight(e, 25)
                let ch = (e & f) ^ ((~e) & g)
                let temp1 = h &+ s1 &+ ch &+ constants[index] &+ words[index]
                let s0 = rotateRight(a, 2) ^ rotateRight(a, 13) ^ rotateRight(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = s0 &+ maj
                h = g; g = f; f = e; e = d &+ temp1
                d = c; c = b; b = a; a = temp1 &+ temp2
            }
            hash[0] &+= a; hash[1] &+= b; hash[2] &+= c; hash[3] &+= d
            hash[4] &+= e; hash[5] &+= f; hash[6] &+= g; hash[7] &+= h
        }

        var digest: [UInt8] = []
        digest.reserveCapacity(32)
        for word in hash {
            digest.append(UInt8((word >> 24) & 0xff))
            digest.append(UInt8((word >> 16) & 0xff))
            digest.append(UInt8((word >> 8) & 0xff))
            digest.append(UInt8(word & 0xff))
        }
        return digest
    }

    private static func rotateRight(_ value: UInt32, _ count: UInt32) -> UInt32 {
        (value >> count) | (value << (32 - count))
    }
    #endif
}
