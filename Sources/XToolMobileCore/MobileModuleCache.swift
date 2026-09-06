import Foundation

public enum MobileModuleCache {
    public static func directory(in builds: URL, identity: String) throws -> URL {
        // Hash is only a directory label. Compare the complete identity before
        // reuse, so even a hash collision cannot reuse an incompatible cache.
        var hash: UInt64 = 14695981039346656037
        for byte in identity.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        let root = builds.appendingPathComponent("ModuleCaches/\(String(hash, radix: 16))")
        let stamp = root.appendingPathComponent("identity.txt")
        let fm = FileManager.default
        if fm.fileExists(atPath: root.path), (try? String(contentsOf: stamp, encoding: .utf8)) != identity {
            try fm.removeItem(at: root)
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try identity.write(to: stamp, atomically: true, encoding: .utf8)
        return root.appendingPathComponent("Modules")
    }

    public static func clear(in builds: URL) throws {
        let root = builds.appendingPathComponent("ModuleCaches")
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }
}
