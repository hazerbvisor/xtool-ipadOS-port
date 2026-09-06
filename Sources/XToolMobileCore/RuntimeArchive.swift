import Foundation

public enum MobileRuntimeArchiveError: Error, CustomStringConvertible, Sendable {
    case malformedArchive(String)
    case unsafePath(String)

    public var description: String {
        switch self {
        case .malformedArchive(let reason):
            return "Malformed runtime archive: \(reason)"
        case .unsafePath(let path):
            return "Unsafe runtime archive path: \(path)"
        }
    }
}

/// Minimal TAR extractor used by the mobile port so the app can unpack its
/// bundled Darwin SDK without depending on an external archive package.
/// Supports regular files, directories, symbolic links, USTAR paths, and PAX
/// extended headers (`path` / `linkpath`) used by Apple SDKs with long names.
public enum MobileRuntimeArchive {
    private static let blockSize = 512

    public static func extractTar(
        at archiveURL: URL,
        to destinationURL: URL,
        fileManager: FileManager = .default
    ) throws {
        let data = try Data(contentsOf: archiveURL, options: [.mappedIfSafe])
        try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)

        var offset = 0
        var globalPAX: [String: String] = [:]
        var pendingPAX: [String: String] = [:]

        while offset + blockSize <= data.count {
            let header = data.subdata(in: offset..<(offset + blockSize))
            if header.allSatisfy({ $0 == 0 }) { break }

            let name = stringField(header, range: 0..<100)
            let prefix = stringField(header, range: 345..<500)
            let headerPath = prefix.isEmpty ? name : "\(prefix)/\(name)"
            let size = tarOctalField(header, range: 124..<136)
            let typeFlag = header[156]
            let headerLinkName = stringField(header, range: 157..<257)
            let contentStart = offset + blockSize
            let contentEnd = contentStart + size

            guard contentEnd <= data.count else {
                throw MobileRuntimeArchiveError.malformedArchive("truncated entry: \(headerPath)")
            }

            if typeFlag == 120 || typeFlag == 103 { // x = per-file PAX, g = global PAX
                let attributes = try parsePAX(data.subdata(in: contentStart..<contentEnd))
                if typeFlag == 103 {
                    globalPAX.merge(attributes) { _, new in new }
                } else {
                    pendingPAX = attributes
                }
                offset += blockSize + padded(size)
                continue
            }

            var attributes = globalPAX
            attributes.merge(pendingPAX) { _, new in new }
            pendingPAX.removeAll(keepingCapacity: true)

            let relativePath = attributes["path"] ?? headerPath
            guard !relativePath.isEmpty else {
                throw MobileRuntimeArchiveError.malformedArchive("empty entry name")
            }
            let linkName = attributes["linkpath"] ?? headerLinkName

            let outputURL = try safeDestination(for: relativePath, under: destinationURL)
            let parent = outputURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)

            switch typeFlag {
            case 0, 48: // regular file
                let contents = data.subdata(in: contentStart..<contentEnd)
                if fileManager.fileExists(atPath: outputURL.path) {
                    try fileManager.removeItem(at: outputURL)
                }
                try contents.write(to: outputURL, options: .atomic)

            case 53: // directory
                try fileManager.createDirectory(at: outputURL, withIntermediateDirectories: true)

            case 50: // symbolic link
                if fileManager.fileExists(atPath: outputURL.path) {
                    try fileManager.removeItem(at: outputURL)
                }
                try fileManager.createSymbolicLink(
                    atPath: outputURL.path,
                    withDestinationPath: linkName
                )

            default:
                // Ignore metadata/special entries that are not needed for the SDK tree.
                break
            }

            offset += blockSize + padded(size)
        }
    }

    private static func padded(_ size: Int) -> Int {
        ((size + blockSize - 1) / blockSize) * blockSize
    }

    private static func stringField(_ header: Data, range: Range<Int>) -> String {
        let bytes = header.subdata(in: range)
        let trimmed = bytes.prefix { $0 != 0 }
        return String(decoding: trimmed, as: UTF8.self)
    }

    private static func tarOctalField(_ header: Data, range: Range<Int>) -> Int {
        let value = stringField(header, range: range)
            .trimmingCharacters(in: CharacterSet(charactersIn: " \0\n\r\t"))
        return Int(value, radix: 8) ?? 0
    }

    /// PAX records are encoded as: `<decimal length> <key>=<value>\n`, where
    /// the decimal length includes the digits, space, payload, and newline.
    private static func parsePAX(_ data: Data) throws -> [String: String] {
        let bytes = [UInt8](data)
        var index = 0
        var result: [String: String] = [:]

        while index < bytes.count {
            guard let space = bytes[index...].firstIndex(of: 32) else {
                throw MobileRuntimeArchiveError.malformedArchive("invalid PAX record length")
            }

            let lengthText = String(decoding: bytes[index..<space], as: UTF8.self)
            guard let recordLength = Int(lengthText), recordLength > 0 else {
                throw MobileRuntimeArchiveError.malformedArchive("invalid PAX record length: \(lengthText)")
            }

            let end = index + recordLength
            guard end <= bytes.count, space + 1 < end else {
                throw MobileRuntimeArchiveError.malformedArchive("truncated PAX record")
            }

            var payloadEnd = end
            if bytes[payloadEnd - 1] == 10 { payloadEnd -= 1 }
            let payload = String(decoding: bytes[(space + 1)..<payloadEnd], as: UTF8.self)

            if let equals = payload.firstIndex(of: "=") {
                let key = String(payload[..<equals])
                let value = String(payload[payload.index(after: equals)...])
                result[key] = value
            }

            index = end
        }

        return result
    }

    private static func safeDestination(for relativePath: String, under root: URL) throws -> URL {
        guard !relativePath.hasPrefix("/") else {
            throw MobileRuntimeArchiveError.unsafePath(relativePath)
        }
        let normalized = NSString(string: relativePath).standardizingPath
        guard normalized != "..", !normalized.hasPrefix("../") else {
            throw MobileRuntimeArchiveError.unsafePath(relativePath)
        }
        return root.appendingPathComponent(normalized)
    }
}
