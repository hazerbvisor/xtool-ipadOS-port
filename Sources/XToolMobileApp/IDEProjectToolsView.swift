import SwiftUI
import XToolMobileCore

struct IDEResizeHandle: View {
    @Binding var size: CGFloat
    var vertical = true
    var reversed = false
    var minimum: CGFloat = 160
    var maximum: CGFloat = 400
    @State private var origin: CGFloat?
    var body: some View {
        Rectangle().fill(Color.secondary.opacity(0.25))
            .frame(width: vertical ? 7 : nil, height: vertical ? nil : 7)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                if origin == nil { origin = size }
                let delta = vertical ? value.translation.width : value.translation.height
                size = min(maximum, max(minimum, (origin ?? size) + delta * (reversed ? -1 : 1)))
            }.onEnded { _ in origin = nil })
            .accessibilityLabel("Resize panel")
            .accessibilityAdjustableAction { direction in
                size = min(maximum, max(minimum, size + (direction == .increment ? 20 : -20)))
            }
    }
}

private struct IDEWorkspaceHit: Identifiable, Sendable {
    let url: URL
    let path: String
    let line: Int
    let text: String
    var id: String { "\(path):\(line)" }
}

struct IDEProjectToolsView: View {
    let root: URL?
    let initialPath: String
    let initialTab: String
    let prepareMutation: () throws -> Void
    let onChanged: () -> Void
    let onOpen: (URL, Int) -> Void
    @State private var tab = "Files"
    @State private var path = ""
    @State private var newPath = ""
    @State private var query = ""
    @State private var hits: [IDEWorkspaceHit] = []
    @State private var busy = false
    @State private var message = ""
    @State private var trashedPath: String?
    @State private var trashURL: URL?
    @State private var history: [URL] = []
    @State private var recovered: MobileRecoveredBuildLog?
    @State private var showLog = false
    @State private var pendingBuildDeletion: URL?
    @State private var showDeleteBuildConfirmation = false
    private var builds: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Builds") }
    var body: some View {
        VStack {
            Picker("Tools", selection: $tab) { ForEach(["Files", "Search", "Builds"], id: \.self) { Text($0).tag($0) } }.pickerStyle(.segmented)
            if tab == "Files" {
                Form {
                    Section("Project files") {
                        TextField("Path, e.g. Sources/NewFile.swift", text: $path).textInputAutocapitalization(.never).autocorrectionDisabled()
                        HStack {
                            Button("Create file") { mutate { root in let file = try MobileWorkspaceTools.create(path, directory: false, in: root); onOpen(file, 1) } }
                            Button("Create folder") { mutate { root in _ = try MobileWorkspaceTools.create(path, directory: true, in: root) } }
                        }
                        TextField("New path for rename", text: $newPath).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("Rename / move") { mutate { root in _ = try MobileWorkspaceTools.rename(path, to: newPath, in: root); path = newPath } }
                        Button("Move to Trash", role: .destructive) {
                            mutate { root in trashURL = try MobileWorkspaceTools.trash(path, in: root); trashedPath = path }
                        }
                        if let trashURL, let trashedPath {
                            Button("Undo delete: \(trashedPath)") {
                                mutate { root in
                                    let target = try MobileWorkspaceTools.destination(trashedPath, in: root)
                                    guard !FileManager.default.fileExists(atPath: target.path) else { throw MobileProjectBuildError.invalid("A file already exists at the original path") }
                                    try FileManager.default.moveItem(at: trashURL, to: target)
                                    self.trashURL = nil; self.trashedPath = nil
                                }
                            }
                        }
                        Text("Paths are relative to the project. Renaming files does not rename Swift symbols or update explicit manifest paths.").font(.caption)
                    }.disabled(root == nil)
                }
            } else if tab == "Search" {
                HStack {
                    TextField("Search file contents", text: $query).textInputAutocapitalization(.never).autocorrectionDisabled().onSubmit { search() }
                    Button("Search") { search() }.disabled(busy || root == nil || query.isEmpty)
                }.padding()
                List(hits) { hit in
                    Button { onOpen(hit.url, hit.line) } label: {
                        VStack(alignment: .leading) {
                            Text("\(hit.path):\(hit.line)").font(.caption.bold())
                            Text(hit.text).font(.system(size: 12, design: .monospaced)).lineLimit(2)
                        }
                    }
                }
            } else {
                HStack {
                    Button("Refresh history") { loadHistory() }
                    Button("Clear module cache") {
                        do { try MobileModuleCache.clear(in: builds); message = "Module cache cleared. The next build will rebuild SDK modules." }
                        catch { message = String(describing: error) }
                    }
                }
                List(history, id: \.self) { folder in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(folder.lastPathComponent).font(.caption)
                            Spacer()
                            Button(role: .destructive) {
                                pendingBuildDeletion = folder
                                showDeleteBuildConfirmation = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                        Button("View / share log") {
                            Task {
                                do { recovered = try await Task.detached { try MobileBuildLogRecovery.recover(in: folder) }.value; showLog = true }
                                catch { message = String(describing: error) }
                            }
                        }
                        if let ipa = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?.first(where: { $0.pathExtension == "ipa" }) {
                            ShareLink("Export unsigned IPA", item: ipa)
                        }
                    }
                }
            }
            if busy { ProgressView() }
            Text(message).font(.caption).textSelection(.enabled).padding(.horizontal)
        }.padding().navigationTitle("Workspace Tools")
            .onAppear { path = initialPath; tab = initialTab; loadHistory() }
            .confirmationDialog(
                "Delete build?",
                isPresented: $showDeleteBuildConfirmation,
                presenting: pendingBuildDeletion
            ) { folder in
                Button("Delete \(folder.lastPathComponent)", role: .destructive) {
                    deleteBuild(folder)
                }
                Button("Cancel", role: .cancel) {
                    pendingBuildDeletion = nil
                }
            } message: { _ in
                Text("This permanently removes the build folder, build log, and any generated IPA inside it. This cannot be undone.")
            }
            .sheet(isPresented: $showLog) {
                NavigationStack {
                    if let recovered {
                        VStack(alignment: .leading) {
                            Text(recovered.summary)
                            ShareLink("Share Build Log", item: recovered.reportURL)
                            ScrollView { Text(recovered.preview).font(.system(size: 12, design: .monospaced)).textSelection(.enabled) }
                        }.padding().navigationTitle("Build Log")
                    }
                }
            }
    }
    private func mutate(_ action: (URL) throws -> Void) {
        guard let root else { return }
        do { try prepareMutation(); try action(root); onChanged(); message = "Project updated." }
        catch { message = String(describing: error) }
    }
    private func search() {
        guard let root, !query.isEmpty, !busy else { return }
        do { try prepareMutation() } catch { message = String(describing: error); return }
        busy = true
        let needle = query
        Task {
            let result = await Task.detached { () -> [IDEWorkspaceHit] in
                var result: [IDEWorkspaceHit] = []
                for entry in IDEWorkspaceScanner.scan(root: root, maxDepth: 15) where !entry.isDirectory {
                    guard let values = try? entry.url.resourceValues(forKeys: [.fileSizeKey]), (values.fileSize ?? 0) <= 2_000_000,
                          let text = try? String(contentsOf: entry.url, encoding: .utf8) else { continue }
                    for (index, line) in text.components(separatedBy: "\n").enumerated() where line.localizedCaseInsensitiveContains(needle) {
                        result.append(IDEWorkspaceHit(url: entry.url, path: entry.relativePath, line: index + 1, text: String(line.prefix(500))))
                        if result.count >= 500 { return result }
                    }
                }
                return result
            }.value
            hits = result; busy = false; message = "\(result.count) matching lines (maximum 500)."
        }
    }
    private func loadHistory() {
        let root = builds
        Task {
            history = await Task.detached {
                ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
                    .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("build.log").path) }
                    .sorted { lhs, rhs in
                        let l = (try? lhs.appendingPathComponent("build.log").resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                        let r = (try? rhs.appendingPathComponent("build.log").resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                        return l > r
                    }.prefix(50).map { $0 }
            }.value
        }
    }
    private func deleteBuild(_ folder: URL) {
        let target = folder.standardizedFileURL
        let buildsRoot = builds.standardizedFileURL
        guard target.deletingLastPathComponent() == buildsRoot else {
            message = "Refusing to delete a folder outside the Builds directory."
            pendingBuildDeletion = nil
            return
        }
        do {
            try FileManager.default.removeItem(at: target)
            history.removeAll { $0.standardizedFileURL == target }
            message = "Deleted build \(target.lastPathComponent)."
        } catch {
            message = "Could not delete build: \(error)"
        }
        pendingBuildDeletion = nil
    }
}
