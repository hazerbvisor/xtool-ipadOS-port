import SwiftUI
import UniformTypeIdentifiers
import UIKit
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

private struct XIPDocumentPicker: UIViewControllerRepresentable {
    let onResult: (Result<[URL], Error>) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onResult: onResult)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // Some iPadOS Files providers expose XIP archives but refuse an
        // open-in-place handoff. In that case the file looks enabled yet tapping
        // it does nothing. Force import/copy mode so the provider must hand XTool
        // a local readable copy. XTool deletes that temporary copy after SDK
        // extraction completes or is cancelled.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onResult: (Result<[URL], Error>) -> Void

        init(onResult: @escaping (Result<[URL], Error>) -> Void) {
            self.onResult = onResult
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onResult(.success(urls))
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onResult(.success([]))
        }
    }
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

    @State private var showingXIPImporter = false
    @State private var sdkImportTask: Task<Void, Never>?
    @State private var sdkImportProgress = 0.0
    @State private var sdkImportStatus = "Choose an Xcode .xip to install its complete iPhoneOS SDK."
    @State private var installedSDKs: [String] = []
    @State private var activeSDKName: String?

    @State private var windowsProbeExecutable: URL?
    @State private var windowsProbeInspection: MobileWindowsPEInspection?
    @State private var windowsProbeEngineVersion = "Not checked"
    @State private var windowsProbeSupportsClang = false
    @State private var windowsProbeSupportsCOFF = false

    private var builds: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Builds")
    }

    var body: some View {
        VStack {
            Picker("Tools", selection: $tab) {
                ForEach(["Files", "Search", "Builds", "SDK", "Windows"], id: \.self) {
                    Text($0).tag($0)
                }
            }
            .pickerStyle(.segmented)

            if tab == "Files" {
                Form {
                    Section("Project files") {
                        TextField("Path, e.g. Sources/NewFile.swift", text: $path)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        HStack {
                            Button("Create file") {
                                mutate { root in
                                    let file = try MobileWorkspaceTools.create(path, directory: false, in: root)
                                    onOpen(file, 1)
                                }
                            }
                            Button("Create folder") {
                                mutate { root in
                                    _ = try MobileWorkspaceTools.create(path, directory: true, in: root)
                                }
                            }
                        }
                        TextField("New path for rename", text: $newPath)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("Rename / move") {
                            mutate { root in
                                _ = try MobileWorkspaceTools.rename(path, to: newPath, in: root)
                                path = newPath
                            }
                        }
                        Button("Move to Trash", role: .destructive) {
                            mutate { root in
                                trashURL = try MobileWorkspaceTools.trash(path, in: root)
                                trashedPath = path
                            }
                        }
                        if let trashURL, let trashedPath {
                            Button("Undo delete: \(trashedPath)") {
                                mutate { root in
                                    let target = try MobileWorkspaceTools.destination(trashedPath, in: root)
                                    guard !FileManager.default.fileExists(atPath: target.path) else {
                                        throw MobileProjectBuildError.invalid("A file already exists at the original path")
                                    }
                                    try FileManager.default.moveItem(at: trashURL, to: target)
                                    self.trashURL = nil
                                    self.trashedPath = nil
                                }
                            }
                        }
                        Text("Paths are relative to the project. Renaming files does not rename Swift symbols or update explicit manifest paths.")
                            .font(.caption)
                    }
                    .disabled(root == nil)
                }
            } else if tab == "Search" {
                HStack {
                    TextField("Search file contents", text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { search() }
                    Button("Search") { search() }
                        .disabled(busy || root == nil || query.isEmpty)
                }
                .padding()
                List(hits) { hit in
                    Button { onOpen(hit.url, hit.line) } label: {
                        VStack(alignment: .leading) {
                            Text("\(hit.path):\(hit.line)").font(.caption.bold())
                            Text(hit.text)
                                .font(.system(size: 12, design: .monospaced))
                                .lineLimit(2)
                        }
                    }
                }
            } else if tab == "Builds" {
                HStack {
                    Button("Refresh history") { loadHistory() }
                    Button("Clear module cache") {
                        do {
                            try MobileModuleCache.clear(in: builds)
                            message = "Module cache cleared. The next build will rebuild SDK modules."
                        } catch {
                            message = String(describing: error)
                        }
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
                                do {
                                    recovered = try await Task.detached {
                                        try MobileBuildLogRecovery.recover(in: folder)
                                    }.value
                                    showLog = true
                                } catch {
                                    message = String(describing: error)
                                }
                            }
                        }
                        if let ipa = (try? FileManager.default.contentsOfDirectory(
                            at: folder,
                            includingPropertiesForKeys: nil
                        ))?.first(where: { $0.pathExtension == "ipa" }) {
                            ShareLink("Export unsigned IPA", item: ipa)
                        }
                    }
                }
            } else if tab == "SDK" {
                sdkTools
            } else {
                windowsCompilerTools
            }

            if busy { ProgressView() }
            Text(message)
                .font(.caption)
                .textSelection(.enabled)
                .padding(.horizontal)
        }
        .padding()
        .navigationTitle("Workspace Tools")
        .onAppear {
            path = initialPath
            tab = initialTab
            loadHistory()
            loadSDKStatus()
            loadWindowsCompilerStatus()
        }
        .sheet(isPresented: $showingXIPImporter) {
            XIPDocumentPicker { result in
                showingXIPImporter = false
                beginSDKImport(result)
            }
            .ignoresSafeArea()
        }
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
                        ScrollView {
                            Text(recovered.preview)
                                .font(.system(size: 12, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                    .padding()
                    .navigationTitle("Build Log")
                }
            }
        }
    }

    @ViewBuilder
    private var sdkTools: some View {
        Form {
            Section("Xcode SDK Extractor") {
                Label("Extract iPhoneOS SDK from Xcode", systemImage: "shippingbox.and.arrow.backward")
                    .font(.headline)
                Text("XTool asks iPadOS to make a temporary local copy of the Xcode .xip, extracts only iPhoneOS*.sdk into its mobile runtime, then removes the temporary XIP copy. The rest of Xcode is decoded as needed but never stored on disk.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    showingXIPImporter = true
                } label: {
                    Label("Choose Xcode .xip…", systemImage: "doc.badge.plus")
                }
                .disabled(sdkImportTask != nil)

                if sdkImportTask != nil {
                    ProgressView(value: sdkImportProgress)
                    Text(sdkImportStatus)
                        .font(.caption)
                        .textSelection(.enabled)
                    Button("Cancel extraction", role: .destructive) {
                        sdkImportTask?.cancel()
                        sdkImportStatus = "Cancelling…"
                    }
                } else {
                    Text(sdkImportStatus)
                        .font(.caption)
                        .textSelection(.enabled)
                }
            }

            Section("Installed SDKs") {
                if installedSDKs.isEmpty {
                    Text("No iPhoneOS SDK detected in XToolMobileRuntime.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(installedSDKs, id: \.self) { sdk in
                        HStack {
                            Image(systemName: sdk == activeSDKName ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(sdk == activeSDKName ? .green : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(sdk)
                                if sdk == activeSDKName {
                                    Text("Active for builds")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                        }
                    }
                }
                Button("Refresh SDK list") { loadSDKStatus() }
                    .disabled(sdkImportTask != nil)
            }

            Section("Compatibility") {
                Text("A newly imported SDK is activated only when XTool also has the matching prebuilt Swift stdlib module. Otherwise the SDK stays installed while the current compatible SDK remains active, preventing the compiler runtime from being broken by an SDK-only upgrade.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var windowsCompilerTools: some View {
        Form {
            Section("Windows x64 compiler gate") {
                LabeledContent("Compiler engine", value: windowsProbeEngineVersion)
                LabeledContent("Clang frontend", value: windowsProbeSupportsClang ? "Ready" : "Missing")
                LabeledContent("COFF LLD", value: windowsProbeSupportsCOFF ? "Ready" : "Missing")

                Button {
                    runWindowsCompilerProbe()
                } label: {
                    Label("Build x64 HelloWindows.exe", systemImage: "pc")
                }
                .disabled(busy || !windowsProbeSupportsClang || !windowsProbeSupportsCOFF)

                Text("Compiles a CRT-free C function for x86_64-pc-windows-msvc, then links it with the embedded lld-link driver. No Windows SDK, Visual Studio, MinGW, or Windows PC is required.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let inspection = windowsProbeInspection {
                Section("PE32+ result") {
                    LabeledContent("Machine", value: inspection.machine == 0x8664 ? "AMD64 · 0x8664" : "0x\(String(inspection.machine, radix: 16, uppercase: true))")
                    LabeledContent("Format", value: inspection.optionalMagic == 0x20B ? "PE32+ · 0x20B" : "0x\(String(inspection.optionalMagic, radix: 16, uppercase: true))")
                    LabeledContent("Sections", value: String(inspection.sectionCount))
                    LabeledContent("Entry RVA", value: "0x\(String(inspection.entryRVA, radix: 16, uppercase: true))")
                    LabeledContent("Entry section", value: inspection.entrySection)
                    LabeledContent("File size", value: "\(inspection.fileSize) bytes")
                    LabeledContent("Entry bytes", value: inspection.entryPreview)
                    LabeledContent("WinPad Phase 17", value: inspection.phase17EntryCompatible ? "Compatible · MOV EAX,42; RET" : "Needs wider decoder")
                }
            }

            if let windowsProbeExecutable {
                Section("Output") {
                    ShareLink(item: windowsProbeExecutable) {
                        Label("Export HelloWindows.exe", systemImage: "square.and.arrow.up")
                    }
                    Text(windowsProbeExecutable.path)
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func beginSDKImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            sdkImportStatus = "Could not open XIP: \(error.localizedDescription)"
        case .success(let urls):
            guard let url = urls.first else {
                sdkImportStatus = "XIP selection cancelled."
                return
            }
            guard url.pathExtension.lowercased() == "xip" else {
                sdkImportStatus = "That is not an Xcode .xip file. Choose the original .xip downloaded from Apple."
                return
            }
            let hasScope = url.startAccessingSecurityScopedResource()
            let localPickerCopy = url.standardizedFileURL.path.hasPrefix(NSHomeDirectory() + "/")
            sdkImportProgress = 0
            sdkImportStatus = "Opening \(url.lastPathComponent)…"

            sdkImportTask = Task {
                defer {
                    if hasScope { url.stopAccessingSecurityScopedResource() }
                    if localPickerCopy { try? FileManager.default.removeItem(at: url) }
                    Task { @MainActor in
                        sdkImportTask = nil
                        loadSDKStatus()
                    }
                }
                do {
                    let importResult = try await MobileXcodeSDKInstaller.importFromXcodeXIP(url) { update in
                        await MainActor.run {
                            sdkImportProgress = update.progress
                            sdkImportStatus = update.message
                        }
                    }
                    await MainActor.run {
                        sdkImportProgress = 1
                        sdkImportStatus = "\(importResult.activationMessage) \(importResult.filesWritten) SDK files written."
                    }
                } catch is CancellationError {
                    await MainActor.run {
                        sdkImportStatus = "SDK extraction cancelled. The active runtime was left unchanged."
                    }
                } catch {
                    await MainActor.run {
                        sdkImportStatus = "SDK extraction failed: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    private func loadSDKStatus() {
        do {
            let runtimeRoot = try MobileXcodeSDKInstaller.canonicalRuntimeRoot()
            let toolchain = PreparedToolchain(root: runtimeRoot)
            let sdkDirectory = toolchain.iPhoneOSPlatform
                .appendingPathComponent("Developer/SDKs", isDirectory: true)
            installedSDKs = ((try? FileManager.default.contentsOfDirectory(
                at: sdkDirectory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? [])
                .filter { $0.pathExtension == "sdk" && $0.lastPathComponent.hasPrefix("iPhoneOS") }
                .map(\.lastPathComponent)
                .sorted()
            activeSDKName = try? toolchain.iPhoneOSSDK().lastPathComponent
        } catch {
            installedSDKs = []
            activeSDKName = nil
        }
    }

    private func loadWindowsCompilerStatus() {
        do {
            let engine = try MobileCompilerEngine.loadFromApplicationBundle()
            windowsProbeEngineVersion = engine.version
            windowsProbeSupportsClang = engine.supportsClangFrontend
            windowsProbeSupportsCOFF = engine.supportsCOFFLLD
        } catch {
            windowsProbeEngineVersion = "Unavailable"
            windowsProbeSupportsClang = false
            windowsProbeSupportsCOFF = false
        }
    }

    private func runWindowsCompilerProbe() {
        guard !busy else { return }
        busy = true
        windowsProbeExecutable = nil
        windowsProbeInspection = nil
        message = "Windows probe: loading compiler engine…"

        Task {
            do {
                let engine = try MobileCompilerEngine.loadFromApplicationBundle()
                windowsProbeEngineVersion = engine.version
                windowsProbeSupportsClang = engine.supportsClangFrontend
                windowsProbeSupportsCOFF = engine.supportsCOFFLLD
                guard engine.supportsClangFrontend else {
                    throw MobileCompilerEngineError.missingSymbol("xtool_clang_frontend_run")
                }
                guard engine.supportsCOFFLLD else {
                    throw MobileCompilerEngineError.missingSymbol("xtool_lld_coff_run")
                }

                guard let applicationSupport = FileManager.default.urls(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask
                ).first else {
                    throw MobileProjectBuildError.invalid("Application Support directory is unavailable")
                }
                let workspace = applicationSupport
                    .appendingPathComponent("WindowsCompilerProbe", isDirectory: true)
                let plan = try MobileWindowsCOFFProbePlan.helloReturn42(workspace: workspace)

                message = "Windows probe: Clang → x86_64 COFF object…"
                let clangResult = try await Task.detached {
                    try engine.runClangFrontend(arguments: plan.clangArguments)
                }.value
                guard clangResult.succeeded else {
                    let diagnostics = String(data: clangResult.standardError, encoding: .utf8) ?? ""
                    throw MobileProjectBuildError.invalid(
                        "Windows Clang failed (\(clangResult.exitCode)): \(diagnostics)"
                    )
                }
                guard FileManager.default.fileExists(atPath: plan.objectURL.path) else {
                    throw MobileProjectBuildError.invalid("Clang returned success but HelloWindows.obj is missing")
                }

                message = "Windows probe: COFF LLD → PE32+ executable…"
                let lldResult = try await Task.detached {
                    try engine.runCOFFLLD(arguments: plan.lldArguments)
                }.value
                guard lldResult.succeeded else {
                    let diagnostics = String(data: lldResult.standardError, encoding: .utf8) ?? ""
                    throw MobileProjectBuildError.invalid(
                        "COFF LLD failed (\(lldResult.exitCode)): \(diagnostics)"
                    )
                }
                guard FileManager.default.fileExists(atPath: plan.executableURL.path) else {
                    throw MobileProjectBuildError.invalid("lld-link returned success but HelloWindows.exe is missing")
                }

                let inspection = try plan.inspectExecutable()
                windowsProbeInspection = inspection
                windowsProbeExecutable = plan.executableURL
                message = inspection.phase17EntryCompatible
                    ? "Windows compiler SUCCESS — genuine AMD64 PE32+ built on-device; entry is already WinPad Phase 17 compatible."
                    : "Windows compiler SUCCESS — genuine AMD64 PE32+ built on-device; entry needs wider WinPad instruction coverage."
            } catch {
                message = "Windows compiler probe failed: \(String(describing: error))"
            }
            busy = false
        }
    }

    private func mutate(_ action: (URL) throws -> Void) {
        guard let root else { return }
        do {
            try prepareMutation()
            try action(root)
            onChanged()
            message = "Project updated."
        } catch {
            message = String(describing: error)
        }
    }

    private func search() {
        guard let root, !query.isEmpty, !busy else { return }
        do {
            try prepareMutation()
        } catch {
            message = String(describing: error)
            return
        }
        busy = true
        let needle = query
        Task {
            let result = await Task.detached { () -> [IDEWorkspaceHit] in
                var result: [IDEWorkspaceHit] = []
                for entry in IDEWorkspaceScanner.scan(root: root, maxDepth: 15) where !entry.isDirectory {
                    guard let values = try? entry.url.resourceValues(forKeys: [.fileSizeKey]),
                          (values.fileSize ?? 0) <= 2_000_000,
                          let text = try? String(contentsOf: entry.url, encoding: .utf8) else {
                        continue
                    }
                    for (index, line) in text.components(separatedBy: "\n").enumerated()
                    where line.localizedCaseInsensitiveContains(needle) {
                        result.append(
                            IDEWorkspaceHit(
                                url: entry.url,
                                path: entry.relativePath,
                                line: index + 1,
                                text: String(line.prefix(500))
                            )
                        )
                        if result.count >= 500 { return result }
                    }
                }
                return result
            }.value
            hits = result
            busy = false
            message = "\(result.count) matching lines (maximum 500)."
        }
    }

    private func loadHistory() {
        let root = builds
        Task {
            history = await Task.detached {
                ((try? FileManager.default.contentsOfDirectory(
                    at: root,
                    includingPropertiesForKeys: nil
                )) ?? [])
                    .filter {
                        FileManager.default.fileExists(
                            atPath: $0.appendingPathComponent("build.log").path
                        )
                    }
                    .sorted { lhs, rhs in
                        let l = (try? lhs.appendingPathComponent("build.log")
                            .resourceValues(forKeys: [.contentModificationDateKey])
                            .contentModificationDate) ?? .distantPast
                        let r = (try? rhs.appendingPathComponent("build.log")
                            .resourceValues(forKeys: [.contentModificationDateKey])
                            .contentModificationDate) ?? .distantPast
                        return l > r
                    }
                    .prefix(50)
                    .map { $0 }
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
