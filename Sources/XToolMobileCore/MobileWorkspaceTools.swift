import Foundation

public struct MobileSourceDiagnostic: Identifiable, Hashable, Sendable {
    public var id: String { "\(path):\(line):\(column):\(severity):\(message)" }
    public let path: String
    public let line: Int
    public let column: Int
    public let severity: String
    public let message: String

    public static func parse(_ text: String) -> [Self] {
        let pattern = #"^(.+?):([0-9]+):([0-9]+): (error|warning|note): (.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .anchorsMatchLines) else { return [] }
        let source = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: source.length)).compactMap { match in
            let fields = (1...5).map { source.substring(with: match.range(at: $0)) }
            guard let line = Int(fields[1]), let column = Int(fields[2]) else { return nil }
            return Self(path: fields[0], line: line, column: column, severity: fields[3], message: fields[4])
        }
    }
}

public enum MobileWorkspaceTools {
    /// Rejects traversal and symlink components, including dangling links and
    /// symlink parents of files which have not been created yet.
    public static func destination(_ path: String, in root: URL) throws -> URL {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.contains("\\"), !path.contains("\0"),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !parts.contains(where: { [".git", ".build", ".xtool"].contains(String($0)) }) else {
            throw MobileProjectBuildError.invalid("Invalid project path: \(path)")
        }
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        // Resolving an entire nonexistent destination is not sufficient on all
        // Foundation implementations. Inspect each component with readlink
        // semantics before allowing creation beneath it. The editor does not
        // support editing through project symlinks, even internal ones.
        var target = base
        for part in parts {
            target.appendPathComponent(String(part))
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: target.path)) != nil {
                throw MobileProjectBuildError.invalid("Symlink paths are not editable: \(path)")
            }
        }
        target = target.standardizedFileURL
        guard target.path.hasPrefix(base.path + "/") else {
            throw MobileProjectBuildError.invalid("Path leaves the project: \(path)")
        }
        return target
    }

    public static func create(_ path: String, directory: Bool, in root: URL) throws -> URL {
        let target = try destination(path, in: root)
        let fm = FileManager.default
        guard !fm.fileExists(atPath: target.path) else { throw MobileProjectBuildError.invalid("Already exists: \(path)") }
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if directory { try fm.createDirectory(at: target, withIntermediateDirectories: false) }
        else { try Data().write(to: target, options: .withoutOverwriting) }
        return target
    }

    public static func rename(_ path: String, to newPath: String, in root: URL) throws -> URL {
        let origin = try destination(path, in: root)
        let target = try destination(newPath, in: root)
        guard !FileManager.default.fileExists(atPath: target.path) else { throw MobileProjectBuildError.invalid("Already exists: \(newPath)") }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: origin, to: target)
        return target
    }

    public static func trash(_ path: String, in root: URL) throws -> URL {
        let source = try destination(path, in: root)
        let trash = root.appendingPathComponent(".xtool/Trash/\(UUID().uuidString)/\(path)")
        try FileManager.default.createDirectory(at: trash.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: source, to: trash)
        return trash
    }

    public struct Edit: Codable, Sendable, Identifiable {
        public var id: String { path }
        public let path: String
        public let content: String?
        public init(path: String, content: String?) { self.path = path; self.content = content }
    }

    public struct AppliedEdits: Sendable {
        public let before: [Edit]
        public let after: [Edit]
    }

    /// The caller supplies the exact text shown to the assistant. Reject stale
    /// edits, unseen existing files and colliding paths before changing anything.
    public static func apply(_ edits: [Edit], expected: [String: String], in root: URL) throws -> AppliedEdits {
        guard !edits.isEmpty, edits.count <= 30,
              edits.reduce(0, { $0 + ($1.content?.utf8.count ?? 0) }) <= 4_000_000 else {
            throw MobileProjectBuildError.invalid("Edit batch is empty or too large")
        }
        var paths: Set<String> = []
        var before: [Edit] = []
        for edit in edits {
            let target = try destination(edit.path, in: root)
            let key = target.path.lowercased()
            guard paths.insert(key).inserted,
                  !paths.contains(where: { $0 != key && ($0.hasPrefix(key + "/") || key.hasPrefix($0 + "/")) }) else {
                throw MobileProjectBuildError.invalid("Conflicting edit paths: \(edit.path)")
            }
            let current = FileManager.default.fileExists(atPath: target.path)
                ? try String(contentsOf: target, encoding: .utf8) : nil
            guard current == expected[edit.path] else {
                throw MobileProjectBuildError.invalid("File changed or was not shared: \(edit.path). Send fresh context first.")
            }
            before.append(Edit(path: edit.path, content: current))
        }
        // Keep a recoverable copy even if the app is terminated mid-write.
        let backup = root.appendingPathComponent(".xtool/Edits/\(UUID().uuidString).json")
        try FileManager.default.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(before).write(to: backup, options: .atomic)
        var written: [Edit] = []
        do {
            for (edit, original) in zip(edits, before) {
                try write(edit, in: root)
                written.append(original)
            }
        } catch {
            for original in written.reversed() { try? write(original, in: root) }
            throw error
        }
        return AppliedEdits(before: before, after: edits)
    }

    public static func undo(_ batch: AppliedEdits, in root: URL) throws {
        let expected = Dictionary(uniqueKeysWithValues: batch.after.compactMap { edit in edit.content.map { (edit.path, $0) } })
        _ = try apply(batch.before, expected: expected, in: root)
    }

    private static func write(_ edit: Edit, in root: URL) throws {
        let target = try destination(edit.path, in: root)
        if let content = edit.content {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: target, atomically: true, encoding: .utf8)
        } else if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
    }
}
