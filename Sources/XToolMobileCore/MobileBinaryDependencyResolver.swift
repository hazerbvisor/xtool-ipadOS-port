import Crypto
import Foundation
import ZIPFoundation

/// Resolves optional prebuilt binary dependencies before XTool Mobile loads a
/// project's build manifest. This keeps mobile projects declarative while still
/// allowing native SDKs distributed as XCFramework ZIPs (for example ad SDKs).
public enum MobileBinaryDependencyResolver {
    public static let filename = "xtool-mobile-dependencies.json"

    public struct Configuration: Codable, Sendable {
        public var schemaVersion: Int
        public var binaryFrameworks: [BinaryFramework]
    }

    public struct BinaryFramework: Codable, Sendable {
        public var name: String
        public var url: String
        public var sha256: String?
    }

    private struct Receipt: Codable, Equatable {
        var url: String
        var sha256: String?
    }

    /// Resolve dependencies only when a sidecar configuration exists. Existing
    /// projects without the sidecar keep exactly the same build path.
    public static func resolveIfPresent(
        at projectRoot: URL,
        fileManager: FileManager = .default
    ) throws {
        let configurationURL = projectRoot.appendingPathComponent(filename)
        guard fileManager.fileExists(atPath: configurationURL.path) else { return }

        let configuration = try JSONDecoder().decode(
            Configuration.self,
            from: Data(contentsOf: configurationURL)
        )
        guard configuration.schemaVersion == 1 else {
            throw MobileProjectBuildError.invalid(
                "Unsupported \(filename) schema \(configuration.schemaVersion)"
            )
        }

        var seen: Set<String> = []
        for dependency in configuration.binaryFrameworks {
            try MobileAppManifest.validateName(dependency.name)
            guard seen.insert(dependency.name).inserted else {
                throw MobileProjectBuildError.invalid(
                    "Duplicate binary framework dependency: \(dependency.name)"
                )
            }
            try resolve(dependency, projectRoot: projectRoot, fileManager: fileManager)
        }
    }

    private static func resolve(
        _ dependency: BinaryFramework,
        projectRoot: URL,
        fileManager: FileManager
    ) throws {
        guard let remoteURL = URL(string: dependency.url),
              remoteURL.scheme?.lowercased() == "https" else {
            throw MobileProjectBuildError.invalid(
                "Binary framework \(dependency.name) must use an https URL"
            )
        }

        let normalizedChecksum = dependency.sha256?.lowercased()
        if let normalizedChecksum,
           normalizedChecksum.count != 64 ||
           !normalizedChecksum.allSatisfy({ $0.isHexDigit }) {
            throw MobileProjectBuildError.invalid(
                "Binary framework \(dependency.name) has an invalid SHA-256"
            )
        }

        let dependencyRoot = projectRoot
            .appendingPathComponent(".xtool-mobile", isDirectory: true)
            .appendingPathComponent("dependencies", isDirectory: true)
            .appendingPathComponent(dependency.name, isDirectory: true)
        let frameworksRoot = dependencyRoot.appendingPathComponent("Frameworks", isDirectory: true)
        let expectedFramework = frameworksRoot.appendingPathComponent("\(dependency.name).framework", isDirectory: true)
        let receiptURL = dependencyRoot.appendingPathComponent("receipt.json")
        let wantedReceipt = Receipt(url: dependency.url, sha256: normalizedChecksum)

        if fileManager.fileExists(atPath: expectedFramework.path),
           let receiptData = try? Data(contentsOf: receiptURL),
           let receipt = try? JSONDecoder().decode(Receipt.self, from: receiptData),
           receipt == wantedReceipt {
            return
        }

        let installRoot = dependencyRoot
            .deletingLastPathComponent()
            .appendingPathComponent(".\(dependency.name)-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: installRoot) }
        try fileManager.createDirectory(at: installRoot, withIntermediateDirectories: true)

        let archiveURL = installRoot.appendingPathComponent("artifact.zip")
        let unpackedURL = installRoot.appendingPathComponent("unpacked", isDirectory: true)
        try fileManager.createDirectory(at: unpackedURL, withIntermediateDirectories: true)

        let archiveData: Data
        do {
            archiveData = try Data(contentsOf: remoteURL)
        } catch {
            throw MobileProjectBuildError.invalid(
                "Could not download \(dependency.name): \(error.localizedDescription)"
            )
        }
        guard !archiveData.isEmpty, archiveData.count <= 250 * 1024 * 1024 else {
            throw MobileProjectBuildError.invalid(
                "Binary framework \(dependency.name) download is empty or unexpectedly large"
            )
        }

        if let normalizedChecksum {
            let digest = SHA256.hash(data: archiveData)
                .map { String(format: "%02x", $0) }
                .joined()
            guard digest == normalizedChecksum else {
                throw MobileProjectBuildError.invalid(
                    "SHA-256 mismatch for \(dependency.name): expected \(normalizedChecksum), got \(digest)"
                )
            }
        }

        try archiveData.write(to: archiveURL, options: .atomic)
        do {
            try fileManager.unzipItem(
                at: archiveURL,
                to: unpackedURL,
                symlinksValidWithin: unpackedURL
            )
        } catch {
            throw MobileProjectBuildError.invalid(
                "Could not extract \(dependency.name): \(error.localizedDescription)"
            )
        }

        let xcframework = try findXCFramework(named: dependency.name, under: unpackedURL, fileManager: fileManager)
        let framework = try selectDeviceFramework(
            named: dependency.name,
            xcframework: xcframework,
            fileManager: fileManager
        )

        let stagedRoot = installRoot.appendingPathComponent("resolved", isDirectory: true)
        let stagedFrameworks = stagedRoot.appendingPathComponent("Frameworks", isDirectory: true)
        try fileManager.createDirectory(at: stagedFrameworks, withIntermediateDirectories: true)
        let stagedFramework = stagedFrameworks.appendingPathComponent(framework.lastPathComponent, isDirectory: true)
        try fileManager.copyItem(at: framework, to: stagedFramework)
        try JSONEncoder().encode(wantedReceipt)
            .write(to: stagedRoot.appendingPathComponent("receipt.json"), options: .atomic)

        if fileManager.fileExists(atPath: dependencyRoot.path) {
            try fileManager.removeItem(at: dependencyRoot)
        }
        try fileManager.moveItem(at: stagedRoot, to: dependencyRoot)

        guard fileManager.fileExists(atPath: expectedFramework.path) else {
            throw MobileProjectBuildError.invalid(
                "Resolved \(dependency.name) but did not produce \(expectedFramework.lastPathComponent)"
            )
        }
    }

    private static func findXCFramework(
        named name: String,
        under root: URL,
        fileManager: FileManager
    ) throws -> URL {
        let preferred = root.appendingPathComponent("\(name).xcframework", isDirectory: true)
        if fileManager.fileExists(atPath: preferred.path) { return preferred }

        guard let walker = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw MobileProjectBuildError.invalid("Could not inspect binary framework archive")
        }
        for case let item as URL in walker where item.pathExtension == "xcframework" {
            walker.skipDescendants()
            return item
        }
        throw MobileProjectBuildError.invalid(
            "Downloaded \(name) archive contains no XCFramework"
        )
    }

    private static func selectDeviceFramework(
        named name: String,
        xcframework: URL,
        fileManager: FileManager
    ) throws -> URL {
        let infoURL = xcframework.appendingPathComponent("Info.plist")
        guard let plist = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: infoURL),
            format: nil
        ) as? [String: Any],
        let libraries = plist["AvailableLibraries"] as? [[String: Any]] else {
            throw MobileProjectBuildError.invalid(
                "\(name).xcframework has no readable AvailableLibraries"
            )
        }

        let candidate = libraries.first { library in
            guard (library["SupportedPlatform"] as? String) == "ios",
                  (library["SupportedArchitectures"] as? [String])?.contains("arm64") == true else {
                return false
            }
            // A missing variant is the physical iPhone/iPad device slice.
            return library["SupportedPlatformVariant"] == nil
        }

        guard let candidate,
              let identifier = candidate["LibraryIdentifier"] as? String,
              let libraryPath = candidate["LibraryPath"] as? String else {
            throw MobileProjectBuildError.invalid(
                "\(name).xcframework has no arm64 iOS device slice"
            )
        }

        let framework = xcframework
            .appendingPathComponent(identifier, isDirectory: true)
            .appendingPathComponent(libraryPath, isDirectory: true)
        guard framework.pathExtension == "framework",
              fileManager.fileExists(atPath: framework.path) else {
            throw MobileProjectBuildError.invalid(
                "\(name) device slice is not a framework bundle"
            )
        }
        return framework
    }
}
