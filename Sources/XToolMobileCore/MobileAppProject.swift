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
    public var infoPlist: String?
    public var shortVersion: String?
    public var buildVersion: String?
    public var reuseCompilerEngine: Bool?
    public var reuseBundledRuntime: Bool?

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

    public static let filename = "xtool-mobile.json"

    public static func load(from root: URL) throws -> Self {
        let url = root.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MobileProjectBuildError.invalid(
                "This project needs xtool-mobile.json. For SwiftPM projects, prepare it with scripts/prepare-mobile-project.py on your build host first."
            )
        }
        let manifest = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        _ = try manifest.orderedTargets()
        return manifest
    }

    /// Dependency closure for the app, with missing dependencies and cycles rejected.
    public func orderedTargets() throws -> [Target] {
        guard schemaVersion == 1 else { throw MobileProjectBuildError.invalid("Unsupported project schema \(schemaVersion)") }
        try Self.validateName(name)
        guard bundleIdentifier.split(separator: ".").count >= 2,
              bundleIdentifier.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }),
              !bundleIdentifier.contains(".."), !bundleIdentifier.hasPrefix("."), !bundleIdentifier.hasSuffix(".") else {
            throw MobileProjectBuildError.invalid("Invalid bundle identifier")
        }
        let versionParts = deploymentTarget.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(versionParts.count), versionParts.allSatisfy({ UInt($0) != nil }),
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
        var active: Set<String> = []
        var visited: Set<String> = []
        var result: [Target] = []
        func visit(_ name: String) throws {
            if visited.contains(name) { return }
            guard let target = byName[name] else { throw MobileProjectBuildError.invalid("Missing target dependency: \(name)") }
            guard active.insert(name).inserted else { throw MobileProjectBuildError.invalid("Dependency cycle at \(name)") }
            for dependency in target.dependencies ?? [] { try visit(dependency) }
            active.remove(name)
            visited.insert(name)
            result.append(target)
        }
        try visit(executableTarget)
        return result
    }

    static func validateName(_ name: String) throws {
        guard let first = name.first, first.isASCII, first.isLetter || first == "_",
              name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else {
            throw MobileProjectBuildError.invalid("Use letters, digits and underscores for product and module names: \(name)")
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
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else {
            throw MobileProjectBuildError.invalid("Cannot read directory: \(path)")
        }
        var files: [URL] = []
        for case let file as URL in walker {
            let info = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard info.isSymbolicLink != true else { throw MobileProjectBuildError.invalid("Resource/source symlinks must be materialized: \(file.path)") }
            if info.isRegularFile == true { files.append(file) }
        }
        return files.sorted { $0.path < $1.path }
    }
}
