import Foundation

struct IDEFileEntry: Identifiable, Hashable, Sendable {
    let id: URL
    let url: URL
    let name: String
    let relativePath: String
    let depth: Int
    let isDirectory: Bool

    var language: IDELanguage {
        IDELanguage.infer(from: name)
    }

    var systemImage: String {
        if isDirectory { return "folder" }
        switch language {
        case .swift: return "swift"
        case .c, .cpp, .objectiveC, .objectiveCpp: return "chevron.left.forwardslash.chevron.right"
        case .plainText:
            switch url.pathExtension.lowercased() {
            case "plist": return "list.bullet.rectangle"
            case "json", "yml", "yaml": return "curlybraces"
            default: return "doc.text"
            }
        }
    }
}

struct IDEDocument: Identifiable, Equatable, Sendable {
    let id: URL
    let url: URL
    let title: String
    let language: IDELanguage
    var text: String
    var isDirty: Bool

    init(url: URL, text: String) {
        self.id = url
        self.url = url
        self.title = url.lastPathComponent
        self.language = IDELanguage.infer(from: url.lastPathComponent)
        self.text = text
        self.isDirty = false
    }
}

enum IDEWorkspaceScanner {
    private static let allowedExtensions: Set<String> = [
        "swift", "c", "h", "cc", "cpp", "cxx", "hpp", "hh", "m", "mm",
        "plist", "json", "yml", "yaml", "txt", "md"
    ]

    private static let ignoredDirectories: Set<String> = [
        ".git", ".build", ".swiftpm", "DerivedData", "Pods", "Carthage"
    ]

    static func scan(root: URL, maxDepth: Int = 5) -> [IDEFileEntry] {
        var entries: [IDEFileEntry] = []
        walk(root: root, directory: root, depth: 0, maxDepth: maxDepth, entries: &entries)
        return entries
    }

    private static func walk(
        root: URL,
        directory: URL,
        depth: Int,
        maxDepth: Int,
        entries: inout [IDEFileEntry]
    ) {
        guard depth <= maxDepth else { return }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isHiddenKey, .isSymbolicLinkKey]
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return }

        let sorted = children.sorted { lhs, rhs in
            let lDir = (try? lhs.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let rDir = (try? rhs.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if lDir != rDir { return lDir && !rDir }
            return lhs.lastPathComponent.localizedCaseInsensitiveCompare(rhs.lastPathComponent) == .orderedAscending
        }

        for child in sorted {
            guard let values = try? child.resourceValues(forKeys: Set(keys)), values.isHidden != true, values.isSymbolicLink != true else { continue }
            let isDirectory = values.isDirectory == true
            if isDirectory && ignoredDirectories.contains(child.lastPathComponent) { continue }

            let relative = child.path.replacingOccurrences(of: root.path + "/", with: "")
            if isDirectory {
                entries.append(
                    IDEFileEntry(
                        id: child,
                        url: child,
                        name: child.lastPathComponent,
                        relativePath: relative,
                        depth: depth,
                        isDirectory: true
                    )
                )
                walk(root: root, directory: child, depth: depth + 1, maxDepth: maxDepth, entries: &entries)
                continue
            }

            let name = child.lastPathComponent
            let ext = child.pathExtension.lowercased()
            let specialName = name == "Package.swift" || name == "xtool.yml" || name == "Info.plist"
            guard specialName || allowedExtensions.contains(ext) else { continue }
            entries.append(
                IDEFileEntry(
                    id: child,
                    url: child,
                    name: name,
                    relativePath: relative,
                    depth: depth,
                    isDirectory: false
                )
            )
        }
    }
}
