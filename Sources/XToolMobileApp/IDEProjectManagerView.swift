import SwiftUI
import XToolMobileCore

private struct IDESavedProject: Identifiable, Hashable {
    let root: URL
    let modified: Date
    let checkout: IDEGitHubClient.Checkout?

    var id: String { root.standardizedFileURL.path }
    var name: String { root.lastPathComponent }
    var hasMobileManifest: Bool {
        FileManager.default.fileExists(
            atPath: root.appendingPathComponent(MobileAppManifest.filename).path
        )
    }
    var hasPackageManifest: Bool {
        FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Package.swift").path
        )
    }
}

struct IDEProjectManagerView: View {
    let currentRoot: URL?
    let onOpen: (URL) -> Void

    @State private var projects: [IDESavedProject] = []
    @State private var query = ""
    @State private var message = ""
    @State private var pendingDelete: IDESavedProject?
    @State private var pendingRename: IDESavedProject?
    @State private var renameText = ""
    @State private var showingDeleteConfirmation = false
    @State private var showingRenamePrompt = false
    @AppStorage("xtoolProjectLastOpened") private var lastOpenedStorage = "{}"

    private var projectsRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Projects", isDirectory: true)
    }

    private var filteredProjects: [IDESavedProject] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return projects }
        return projects.filter { item in
            if item.name.localizedCaseInsensitiveContains(needle) { return true }
            if let checkout = item.checkout {
                return checkout.repository.localizedCaseInsensitiveContains(needle)
                    || checkout.branch.localizedCaseInsensitiveContains(needle)
            }
            return false
        }
    }

    var body: some View {
        Group {
            Section {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search saved projects", text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                }
            } header: {
                Text("Saved projects")
            } footer: {
                Text("GitHub imports and projects created in XTool stay in Documents/Projects until you delete them.")
            }

            if filteredProjects.isEmpty {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: "folder")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text("No Saved Projects")
                            .font(.headline)
                        Text(query.isEmpty
                             ? "Import or create a project and it will appear here."
                             : "No projects match your search.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                }
            } else {
                Section("Projects") {
                    ForEach(filteredProjects) { item in
                        projectRow(item)
                    }
                }
            }

            if !message.isEmpty {
                Section("Project Manager") {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .onAppear { refresh() }
        .confirmationDialog(
            "Delete project?",
            isPresented: $showingDeleteConfirmation,
            presenting: pendingDelete,
            titleVisibility: .visible
        ) { item in
            Button("Delete \(item.name)", role: .destructive) { delete(item) }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { item in
            Text("This permanently removes \(item.name) and its source files from XTool. Build history is stored separately.")
        }
        .alert("Rename project", isPresented: $showingRenamePrompt) {
            TextField("Project name", text: $renameText)
            Button("Rename") {
                if let item = pendingRename { rename(item) }
            }
            Button("Cancel", role: .cancel) { pendingRename = nil }
        } message: {
            Text("The currently open project cannot be renamed. Switch projects first.")
        }
    }

    @ViewBuilder
    private func projectRow(_ item: IDESavedProject) -> some View {
        let current = isCurrent(item)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: current ? "folder.fill" : "folder")
                    .foregroundStyle(current ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.name)
                            .font(.headline)
                            .lineLimit(1)
                        if current {
                            Text("OPEN")
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.18), in: Capsule())
                        }
                    }
                    if let checkout = item.checkout {
                        Text("\(checkout.repository) · \(checkout.branch) · \(checkout.commit.prefix(8))")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text(item.hasMobileManifest
                             ? "XTool mobile project"
                             : (item.hasPackageManifest ? "Swift package" : "Project folder"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Menu {
                    Button {
                        open(item)
                    } label: {
                        Label(current ? "Reload project" : "Open project", systemImage: "arrow.right.circle")
                    }
                    Button {
                        duplicate(item)
                    } label: {
                        Label("Duplicate", systemImage: "plus.square.on.square")
                    }
                    Button {
                        pendingRename = item
                        renameText = item.name
                        showingRenamePrompt = true
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    .disabled(current)
                    Divider()
                    Button(role: .destructive) {
                        pendingDelete = item
                        showingDeleteConfirmation = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .disabled(current)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                }
                .buttonStyle(.borderless)
            }

            HStack(spacing: 12) {
                Button(current ? "Reload" : "Open") { open(item) }
                    .buttonStyle(.borderedProminent)
                if item.hasMobileManifest {
                    Label("Buildable", systemImage: "hammer.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let opened = lastOpened(item) {
                    Text("Opened \(opened.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Modified \(item.modified.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func isCurrent(_ item: IDESavedProject) -> Bool {
        guard let currentRoot else { return false }
        return currentRoot.standardizedFileURL == item.root.standardizedFileURL
    }

    private func open(_ item: IDESavedProject) {
        do {
            try MobileProject(root: item.root).validate()
            markOpened(item.root)
            message = "Opening \(item.name)…"
            onOpen(item.root)
        } catch {
            message = "Could not open \(item.name): \(error)"
        }
    }

    private func duplicate(_ item: IDESavedProject) {
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
            let base = item.name + " Copy"
            var candidate = projectsRoot.appendingPathComponent(base, isDirectory: true)
            var index = 2
            while fm.fileExists(atPath: candidate.path) {
                candidate = projectsRoot.appendingPathComponent("\(base) \(index)", isDirectory: true)
                index += 1
            }
            try fm.copyItem(at: item.root, to: candidate)
            message = "Duplicated as \(candidate.lastPathComponent)."
            refresh()
        } catch {
            message = "Duplicate failed: \(error)"
        }
    }

    private func rename(_ item: IDESavedProject) {
        defer {
            pendingRename = nil
            showingRenamePrompt = false
        }
        guard !isCurrent(item) else {
            message = "Switch away from this project before renaming it."
            return
        }
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidProjectName(name) else {
            message = "Use a simple folder name without /, \\, : or path components."
            return
        }
        do {
            let destination = projectsRoot.appendingPathComponent(name, isDirectory: true)
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                throw MobileProjectBuildError.invalid("A project named \(name) already exists")
            }
            try FileManager.default.moveItem(at: item.root, to: destination)
            migrateLastOpened(from: item.root, to: destination)
            message = "Renamed to \(name)."
            refresh()
        } catch {
            message = "Rename failed: \(error)"
        }
    }

    private func delete(_ item: IDESavedProject) {
        defer {
            pendingDelete = nil
            showingDeleteConfirmation = false
        }
        guard !isCurrent(item) else {
            message = "Switch away from this project before deleting it."
            return
        }
        do {
            let rootPath = projectsRoot.resolvingSymlinksInPath().standardizedFileURL.path
            let targetPath = item.root.resolvingSymlinksInPath().standardizedFileURL.path
            guard targetPath.hasPrefix(rootPath + "/") else {
                throw MobileProjectBuildError.invalid("Refusing to delete a folder outside Documents/Projects")
            }
            try FileManager.default.removeItem(at: item.root)
            removeLastOpened(item.root)
            message = "Deleted \(item.name)."
            refresh()
        } catch {
            message = "Delete failed: \(error)"
        }
    }

    private func refresh() {
        let fm = FileManager.default
        try? fm.createDirectory(at: projectsRoot, withIntermediateDirectories: true)

        if let currentRoot,
           currentRoot.standardizedFileURL.path.hasPrefix(projectsRoot.standardizedFileURL.path + "/") {
            markOpened(currentRoot)
        }

        let urls = (try? fm.contentsOfDirectory(
            at: projectsRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        projects = urls.compactMap { url in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            guard values?.isDirectory == true else { return nil }
            let project = MobileProject(root: url)
            guard (try? project.validate()) != nil else { return nil }
            return IDESavedProject(
                root: url,
                modified: values?.contentModificationDate ?? .distantPast,
                checkout: IDEGitHubClient.checkout(in: url)
            )
        }
        .sorted { lhs, rhs in
            (lastOpened(lhs) ?? lhs.modified) > (lastOpened(rhs) ?? rhs.modified)
        }
    }

    private func isValidProjectName(_ value: String) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && !value.contains("/")
            && !value.contains("\\")
            && !value.contains(":")
    }

    private func openedMap() -> [String: Double] {
        guard let data = lastOpenedStorage.data(using: .utf8),
              let object = try? JSONDecoder().decode([String: Double].self, from: data) else {
            return [:]
        }
        return object
    }

    private func saveOpenedMap(_ map: [String: Double]) {
        if let data = try? JSONEncoder().encode(map) {
            lastOpenedStorage = String(decoding: data, as: UTF8.self)
        }
    }

    private func lastOpened(_ item: IDESavedProject) -> Date? {
        openedMap()[item.root.standardizedFileURL.path]
            .map(Date.init(timeIntervalSince1970:))
    }

    private func markOpened(_ url: URL) {
        var map = openedMap()
        map[url.standardizedFileURL.path] = Date().timeIntervalSince1970
        saveOpenedMap(map)
    }

    private func migrateLastOpened(from oldURL: URL, to newURL: URL) {
        var map = openedMap()
        if let value = map.removeValue(forKey: oldURL.standardizedFileURL.path) {
            map[newURL.standardizedFileURL.path] = value
        }
        saveOpenedMap(map)
    }

    private func removeLastOpened(_ url: URL) {
        var map = openedMap()
        map.removeValue(forKey: url.standardizedFileURL.path)
        saveOpenedMap(map)
    }
}
