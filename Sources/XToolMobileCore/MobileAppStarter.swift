import Foundation

public enum MobileAppStarter {
    public static func create(in parent: URL) throws -> MobileProject {
        let root = parent.appendingPathComponent("HelloApp-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("Sources/App"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("Sources/Greeting"), withIntermediateDirectories: true)
        let manifest = """
        {
          "schemaVersion": 1,
          "name": "HelloApp",
          "bundleIdentifier": "com.example.helloapp",
          "deploymentTarget": "16.0",
          "executableTarget": "HelloApp",
          "frameworks": ["SwiftUI", "UIKit", "Foundation"],
          "targets": [
            {"name": "Greeting", "sources": ["Sources/Greeting"]},
            {"name": "HelloApp", "sources": ["Sources/App"], "dependencies": ["Greeting"]}
          ]
        }
        """
        let app = """
        import SwiftUI
        import Greeting

        @main
        struct HelloApp: App {
            var body: some Scene {
                WindowGroup { ContentView() }
            }
        }
        """
        let view = """
        import SwiftUI
        import Greeting

        struct ContentView: View {
            var body: some View {
                VStack(spacing: 16) {
                    Image(systemName: "hammer.circle.fill").font(.system(size: 64))
                    Text(greeting()).font(.title)
                    Text("Compiled and packaged on iPad.").foregroundStyle(.secondary)
                }.padding()
            }
        }
        """
        try manifest.write(to: root.appendingPathComponent(MobileAppManifest.filename), atomically: true, encoding: .utf8)
        try app.write(to: root.appendingPathComponent("Sources/App/HelloApp.swift"), atomically: true, encoding: .utf8)
        try view.write(to: root.appendingPathComponent("Sources/App/ContentView.swift"), atomically: true, encoding: .utf8)
        try "public func greeting() -> String { \"Hello from XTool!\" }\n".write(
            to: root.appendingPathComponent("Sources/Greeting/Greeting.swift"), atomically: true, encoding: .utf8)
        return MobileProject(root: root)
    }
}

/// Thread-safe mailbox between the sequential native build worker and the UI.
public final class MobileBuildProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private var cancelled = false
    private var finished = false
    public init() {}
    public func append(_ line: String) { lock.lock(); defer { lock.unlock() }; lines.append(line) }
    public func drain() -> [String] { lock.lock(); defer { lock.unlock() }; let result = lines; lines.removeAll(); return result }
    public func cancel() { lock.lock(); defer { lock.unlock() }; cancelled = true }
    public func finish() { lock.lock(); defer { lock.unlock() }; finished = true }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    public var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }
}
