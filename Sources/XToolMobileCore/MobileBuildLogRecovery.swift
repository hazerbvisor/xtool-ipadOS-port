import Foundation

public struct MobileRecoveredBuildLog: Sendable {
    public let reportURL: URL
    public let preview: String
    public let summary: String
    public let wasInterrupted: Bool
}

/// Checkpoints survive process termination; no crash handler is needed.
public enum MobileBuildLogRecovery {
    public enum Status: String, Codable, Sendable {
        case running, succeeded, failed, cancelled
    }

    private struct State: Codable {
        let status: Status
        let stage: String
    }

    public static func checkpoint(in directory: URL, stage: String, status: Status = .running) throws {
        let data = try JSONEncoder().encode(State(status: status, stage: stage))
        try data.write(to: directory.appendingPathComponent("build-state.json"), options: .atomic)
    }

    /// Read only the tail for display, while streaming the complete saved log
    /// and native stderr files into a shareable report off the UI thread.
    public static func latest(in builds: URL) throws -> MobileRecoveredBuildLog? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: builds.path) else { return nil }
        let folders = try fm.contentsOfDirectory(at: builds,
            includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        let candidates: [(URL, Date)] = folders.compactMap { folder in
            let log = folder.appendingPathComponent("build.log")
            guard let values = try? log.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                  values.isRegularFile == true else { return nil }
            return (folder, values.contentModificationDate ?? .distantPast)
        }
        guard let directory = candidates.sorted(by: {
            $0.1 == $1.1 ? $0.0.lastPathComponent > $1.0.lastPathComponent : $0.1 > $1.1
        }).first?.0 else { return nil }
        return try recover(in: directory)
    }

    public static func recover(in directory: URL) throws -> MobileRecoveredBuildLog {
        let fm = FileManager.default
        let logURL = directory.appendingPathComponent("build.log")
        let state = (try? Data(contentsOf: directory.appendingPathComponent("build-state.json")))
            .flatMap { try? JSONDecoder().decode(State.self, from: $0) }
        let logTail = try tail(of: logURL)
        let status = state?.status ?? legacyStatus(logTail)
        let interrupted = status == .running
        let summary: String
        switch status {
        case .running:
            summary = state.map { "Previous build was interrupted during: \($0.stage)." }
                ?? "Previous build has no recorded completion."
        case .succeeded: summary = "Previous build completed successfully."
        case .failed: summary = "Previous build failed."
        case .cancelled: summary = "Previous build was cancelled."
        }

        // Captures live at the build root (linker) or Targets/<target>.
        // Also retain support for older builds with <target> at the root.
        // Do not traverse module caches, which can contain thousands of files.
        var diagnostics: [URL] = []
        for child in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey]) {
            if child.pathExtension == "stderr" { diagnostics.append(child) }
            if (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
               !["Modules", "ModuleCache"].contains(child.lastPathComponent) {
                diagnostics += (try fm.contentsOfDirectory(at: child, includingPropertiesForKeys: nil))
                    .filter { $0.pathExtension == "stderr" }
                if child.lastPathComponent == "Targets" {
                    for target in try fm.contentsOfDirectory(at: child, includingPropertiesForKeys: [.isDirectoryKey]) {
                        guard (try? target.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                        diagnostics += (try fm.contentsOfDirectory(at: target, includingPropertiesForKeys: nil))
                            .filter { $0.pathExtension == "stderr" }
                    }
                }
            }
        }
        let reportURL = directory.appendingPathComponent("recovered-build-log.txt")
        let temporary = directory.appendingPathComponent("recovery-\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: temporary.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? fm.removeItem(at: temporary) }
        let output = try FileHandle(forWritingTo: temporary)
        defer { try? output.close() }
        func write(_ text: String) throws { try output.write(contentsOf: Data(text.utf8)) }
        try write("XTool saved build log\nProject build: \(directory.lastPathComponent)\n\(summary)\n")
        if interrupted {
            try write("An interrupted build does not establish whether the cause was a compiler crash, memory pressure, or the app being closed. Only diagnostics written before termination can be recovered.\n")
        }
        let orderedDiagnostics = diagnostics.sorted {
            let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left == right ? $0.path < $1.path : left < right
        }
        for source in [logURL] + orderedDiagnostics {
            let relative = String(source.path.dropFirst(directory.path.count + 1))
            try write("\n===== \(relative) =====\n")
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
                try output.write(contentsOf: chunk)
            }
        }
        try output.synchronize()
        try output.close()
        if fm.fileExists(atPath: reportURL.path) { try fm.removeItem(at: reportURL) }
        try fm.moveItem(at: temporary, to: reportURL)
        return MobileRecoveredBuildLog(reportURL: reportURL, preview: try tail(of: reportURL),
            summary: summary, wasInterrupted: interrupted)
    }

    private static func tail(of url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let size = try file.seekToEnd()
        let limit: UInt64 = 64 * 1024
        try file.seek(toOffset: size > limit ? size - limit : 0)
        let text = String(decoding: try file.read(upToCount: Int(limit)) ?? Data(), as: UTF8.self)
        return (size > limit ? "[Showing the last 64 KiB. Share Build Log exports the full saved output.]\n" : "") + text
    }

    private static func legacyStatus(_ text: String) -> Status {
        if text.contains("\nSUCCESS:") { return .succeeded }
        if text.contains("\nBUILD FAILED:") { return .failed }
        return .running
    }
}
