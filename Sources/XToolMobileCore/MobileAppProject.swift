import Foundation

/// Portable, declarative build graph. It contains no executable package manifest.
public struct MobileAppManifest: Codable, Sendable {
    public var schemaVersion: Int = 1
    public var name: String
    public var bundleIdentifier: String
    public var deploymentTarget: String
    public var executableTarget: String
    public var targets: [Target]
    public var resources: [Resource]?
    public var frameworks: [String]?
    public var libraries: [String]?
    public var linkFiles: [String]?
    public var librarySearchPaths: [String]?
    public var moduleSearchPaths: [String]?
    public var linkerFlags: [String]?
    public var infoPlist: String?
    public var shortVersion: String?
    public var buildVersion: String?
    public var reuseCompilerEngine: Bool?
    public var reuseBundledRuntime: Bool?
    public var extensions: [AppExtension]?
    public var binaryFrameworks: [BinaryFramework]?

    public struct Target: Codable, Sendable {
        public var name: String
        public var sources: [String]
        public var dependencies: [String]?
        public var swiftFlags: [String]?
        public var cFlags: [String]?
        public var headerSearchPaths: [String]?
        public var moduleMap: String?
        public var parseAsLibrary: Bool?
    }

    public struct Resource: Codable, Sendable {
        public var path: String
        public var destination: String
    }

    /// A checksum-pinned remote XCFramework archive. XTool Mobile downloads each
    /// archive once, verifies SHA-256, selects the arm64 iOS device slice, and
    /// adds the contained framework to Swift/Clang and LLD search paths.
    public struct BinaryFramework: Codable, Sendable {
        public var name: String
        public var url: String
        public var checksum: String
    }

    /// One embedded Foundation-style app extension (.appex).
    ///
    /// XTool Mobile links these with Foundation's `_NSExtensionMain`, then embeds
    /// the resulting bundle in `PlugIns/<name>.appex`. Signing remains a separate
    /// step because the mobile builder intentionally emits unsigned IPAs.
    public struct AppExtension: Codable, Sendable {
        public var name: String
        public var bundleIdentifier: String
        public var executableTarget: String
        public var infoPlist: String
        public var resources: [Resource]?
        public var frameworks: [String]?
        public var libraries: [String]?
        public var linkFiles: [String]?
        public var librarySearchPaths: [String]?
        public var moduleSearchPaths: [String]?
        public var linkerFlags: [String]?
    }

    public static let filename = "xtool-mobile.json"

    public static func load(from root: URL) throws -> Self {
        let url = root.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MobileProjectBuildError.invalid(
                "This project needs xtool-mobile.json. For SwiftPM projects, prepare it with scripts/prepare-mobile-project.py on your build host first."
            )
        }
        let manifest = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        _ = try manifest.allOrderedTargets()
        return manifest
    }

    /// Dependency closure for the host app, with missing dependencies and cycles rejected.
    public func orderedTargets() throws -> [Target] {
        let byName = try validatedTargetTable()
        return try orderedTargets(root: executableTarget, byName: byName)
    }

    /// Dependency closure for a specific executable product root.
    public func orderedTargets(for root: String) throws -> [Target] {
        let byName = try validatedTargetTable()
        return try orderedTargets(root: root, byName: byName)
    }

    /// All targets required by the host app and every embedded extension, in a
    /// stable dependency-first order with shared targets compiled only once.
    public func allOrderedTargets() throws -> [Target] {
        let byName = try validatedTargetTable()
        let roots = [executableTarget] + (extensions ?? []).map(\.executableTarget)
        var seen: Set<String> = []
        var result: [Target] = []
        for root in roots {
            for target in try orderedTargets(root: root, byName: byName) where seen.insert(target.name).inserted {
                result.append(target)
            }
        }
        return result
    }

    private func validatedTargetTable() throws -> [String: Target] {
        guard schemaVersion == 1 else {
            throw MobileProjectBuildError.invalid("Unsupported project schema \(schemaVersion)")
        }
        try Self.validateName(name)
        try Self.validateBundleIdentifier(bundleIdentifier)

        let versionParts = deploymentTarget.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(versionParts.count),
              versionParts.allSatisfy({ UInt($0) != nil }),
              (UInt(versionParts[0]) ?? 0) >= 16 else {
            throw MobileProjectBuildError.invalid("Deployment target must be iOS 16.0 or newer")
        }

        var byName: [String: Target] = [:]
        for target in targets {
            try Self.validateName(target.name)
            guard byName.updateValue(target, forKey: target.name) == nil else {
                throw MobileProjectBuildError.invalid("Duplicate target: \(target.name)")
            }
        }
        guard byName[executableTarget] != nil else {
            throw MobileProjectBuildError.invalid("Missing executable target: \(executableTarget)")
        }

        var frameworkNames: Set<String> = []
        for framework in binaryFrameworks ?? [] {
            try Self.validateName(framework.name)
            guard frameworkNames.insert(framework.name).inserted else {
                throw MobileProjectBuildError.invalid("Duplicate binary framework: \(framework.name)")
            }
            guard let remoteURL = URL(string: framework.url),
                  remoteURL.scheme?.lowercased() == "https",
                  remoteURL.host != nil else {
                throw MobileProjectBuildError.invalid("Binary framework \(framework.name) needs an HTTPS URL")
            }
            let checksum = framework.checksum.lowercased()
            guard checksum.count == 64,
                  checksum.allSatisfy({ $0.isHexDigit }) else {
                throw MobileProjectBuildError.invalid("Binary framework \(framework.name) needs a 64-character SHA-256 checksum")
            }
        }

        var productNames: Set<String> = [name]
        var bundleIDs: Set<String> = [bundleIdentifier.lowercased()]
        for appExtension in extensions ?? [] {
            try Self.validateName(appExtension.name)
            try Self.validateBundleIdentifier(appExtension.bundleIdentifier)
            guard productNames.insert(appExtension.name).inserted else {
                throw MobileProjectBuildError.invalid("Duplicate product name: \(appExtension.name)")
            }
            guard bundleIDs.insert(appExtension.bundleIdentifier.lowercased()).inserted else {
                throw MobileProjectBuildError.invalid("Duplicate bundle identifier: \(appExtension.bundleIdentifier)")
            }
            guard byName[appExtension.executableTarget] != nil else {
                throw MobileProjectBuildError.invalid(
                    "Missing extension executable target \(appExtension.executableTarget) for \(appExtension.name)"
                )
            }
            guard !appExtension.infoPlist.isEmpty else {
                throw MobileProjectBuildError.invalid("Extension \(appExtension.name) needs infoPlist")
            }
        }
        return byName
    }

    private func orderedTargets(root: String, byName: [String: Target]) throws -> [Target] {
        var active: Set<String> = []
        var visited: Set<String> = []
        var result: [Target] = []
        func visit(_ targetName: String) throws {
            if visited.contains(targetName) { return }
            guard let target = byName[targetName] else {
                throw MobileProjectBuildError.invalid("Missing target dependency: \(targetName)")
            }
            guard active.insert(targetName).inserted else {
                throw MobileProjectBuildError.invalid("Dependency cycle at \(targetName)")
            }
            for dependency in target.dependencies ?? [] { try visit(dependency) }
            active.remove(targetName)
            visited.insert(targetName)
            result.append(target)
        }
        try visit(root)
        return result
    }

    static func validateName(_ name: String) throws {
        guard let first = name.first, first.isASCII, first.isLetter || first == "_",
              name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else {
            throw MobileProjectBuildError.invalid("Use letters, digits and underscores for product and module names: \(name)")
        }
    }

    static func validateBundleIdentifier(_ bundleIdentifier: String) throws {
        guard bundleIdentifier.split(separator: ".").count >= 2,
              bundleIdentifier.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }),
              !bundleIdentifier.contains(".."),
              !bundleIdentifier.hasPrefix("."),
              !bundleIdentifier.hasSuffix(".") else {
            throw MobileProjectBuildError.invalid("Invalid bundle identifier: \(bundleIdentifier)")
        }
    }
}

public enum MobileProjectBuildError: Error, CustomStringConvertible, Sendable {
    case invalid(String)
    case failed(String, Int32)
    public var description: String {
        switch self {
        case .invalid(let message): return message
        case .failed(let job, let code): return "\(job) failed (exit \(code)); see build.log"
        }
    }
}

enum MobileProjectPaths {
    static func input(_ path: String, root: URL) throws -> URL {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"),
              !path.split(separator: "/").contains("..") else {
            throw MobileProjectBuildError.invalid("Expected a project-relative path: \(path)")
        }
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        let url = root.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
        guard url.path.hasPrefix(base.path + "/"), FileManager.default.fileExists(atPath: url.path) else {
            throw MobileProjectBuildError.invalid("Missing input or symlink outside project: \(path)")
        }
        return url
    }

    static func files(_ path: String, root: URL) throws -> [URL] {
        let url = try input(path, root: root)
        let values = try url.resourceValues(forKeys: [.isDirectoryKey])
        if values.isDirectory != true { return [url] }
        guard let walker = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw MobileProjectBuildError.invalid("Cannot read directory: \(path)")
        }
        var files: [URL] = []
        for case let file as URL in walker {
            let info = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard info.isSymbolicLink != true else {
                throw MobileProjectBuildError.invalid("Resource/source symlinks must be materialized: \(file.path)")
            }
            if info.isRegularFile == true { files.append(file) }
        }
        return files.sorted { $0.path < $1.path }
    }
}
