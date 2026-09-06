import SwiftUI
import UniformTypeIdentifiers
import XToolMobileCore

@main
struct XToolMobileApp: App {
    var body: some Scene {
        WindowGroup {
            MobileIDEView()
                .preferredColorScheme(.dark)
        }
    }
}

private struct MobileIDEView: View {
    private let capabilities = MobilePlatformCapabilities.current()

    @State private var project: MobileProject?
    @State private var toolchain: PreparedToolchain?
    @State private var helloPlan: MobileCompilerPlan?
    @State private var compilerEngine: MobileCompilerEngine?
    @State private var compilerEngineStatus = "Not bundled"
    @State private var projectScopeURL: URL?
    @State private var toolchainScopeURL: URL?
    @State private var toolchainSource = "None"
    @State private var showingProjectImporter = false
    @State private var showingToolchainImporter = false
    @State private var logLines: [String] = ["xtool mobile ready"]
    @State private var attemptedBundledRuntimeDiscovery = false
    @State private var attemptedCompilerEngineDiscovery = false
    @State private var isPreparingBundledRuntime = false
    @State private var isCompilingHello = false
    @State private var isRunningNativeProbe = false
    @State private var isBuildingProject = false
    @State private var projectBuildProgress: MobileBuildProgress?
    @State private var latestIPA: URL?
    @State private var previousBuildLog: MobileRecoveredBuildLog?
    @State private var showingPreviousBuildLog = false
    @State private var attemptedBuildLogRecovery = false
    @State private var showingTools = false
    @State private var showingGitHub = false
    @State private var showingAssistant = false
    @StateObject private var assistantClient = IDECodexChat()
    @StateObject private var githubClient = IDEGitHubClient()
    @State private var toolsPath = ""
    @State private var toolsTab = "Files"
    @State private var findVisible = false
    @State private var findText = ""
    @State private var replacement = ""
    @State private var editorCommand: IDEEditorCommand?
    @State private var splitEditor = false
    @State private var secondDocumentID: URL?
    @State private var navigatorWidth: CGFloat = 245
    @State private var inspectorWidth: CGFloat = 270
    @State private var consoleHeight: CGFloat = 215
    @State private var diagnostics: [MobileSourceDiagnostic] = []
    @State private var completionSymbols: [String] = []
    @State private var buildPhase = ""
    @State private var completedSteps = 0
    @State private var totalSteps = 1
    @State private var lastAIEdit: MobileWorkspaceTools.AppliedEdits?

    @State private var navigatorVisible = true
    @State private var inspectorVisible = true
    @State private var consoleVisible = true
    @State private var navigatorSearch = ""
    @State private var navigatorEntries: [IDEFileEntry] = []
    @State private var documents: [IDEDocument] = []
    @State private var activeDocumentID: URL?
    @State private var selectedInspectorTab: InspectorTab = .file
    @State private var selectedConsoleTab: ConsoleTab = .build

    var body: some View {
        VStack(spacing: 0) {
            topToolbar
            Divider()

            HStack(spacing: 0) {
                if navigatorVisible {
                    navigatorPanel
                        .frame(width: navigatorWidth)
                    IDEResizeHandle(size: $navigatorWidth, maximum: 330)
                }

                VStack(spacing: 0) {
                    editorTabs
                    Divider()
                    HStack(spacing: 1) {
                        editorSurface
                        if splitEditor { Divider(); secondaryEditor }
                    }

                    if consoleVisible {
                        IDEResizeHandle(size: $consoleHeight, vertical: false, reversed: true, minimum: 100, maximum: 500)
                        consolePanel
                            .frame(height: consoleHeight)
                    }
                }

                if inspectorVisible {
                    IDEResizeHandle(size: $inspectorWidth, reversed: true, maximum: 330)
                    inspectorPanel
                        .frame(width: inspectorWidth)
                }
            }

            Divider()
            statusBar
        }
        .background(Color(uiColor: .systemBackground))
        .onAppear {
            if !attemptedBuildLogRecovery {
                attemptedBuildLogRecovery = true
                recoverPreviousBuildLog(automaticallyPresent: true)
            }
            discoverCompilerEngineIfNeeded()
            discoverBundledRuntimeIfNeeded()
        }
        .fileImporter(
            isPresented: $showingProjectImporter,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            importProject(result)
        }
        .fileImporter(
            isPresented: $showingToolchainImporter,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            importToolchain(result)
        }
        .sheet(isPresented: $showingTools) { workspaceToolsSheet }
        .sheet(isPresented: $showingGitHub) { githubSheet }
        .sheet(isPresented: $showingAssistant) { assistantSheet }
        .sheet(isPresented: $showingPreviousBuildLog) {
            NavigationStack {
                VStack(alignment: .leading, spacing: 12) {
                    if let previousBuildLog {
                        Text(previousBuildLog.summary)
                            .font(.headline)
                        ShareLink(item: previousBuildLog.reportURL) {
                            Label("Share Build Log", systemImage: "square.and.arrow.up")
                        }
                        ScrollView {
                            Text(previousBuildLog.preview)
                                .font(.system(size: 12, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding()
                .navigationTitle("Previous Build Log")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showingPreviousBuildLog = false }
                    }
                }
            }
        }
    }

    // MARK: - IDE chrome

    private var topToolbar: some View {
        HStack(spacing: 10) {
            Button {
                navigatorVisible.toggle()
            } label: {
                Image(systemName: "sidebar.left")
                    .frame(width: 30, height: 30)
            }
            .help("Toggle Project Navigator")

            Button {
                showingProjectImporter = true
            } label: {
                Image(systemName: "folder.badge.plus")
                    .frame(width: 30, height: 30)
            }
            .help("Open Project")

            Divider()
                .frame(height: 24)

            Button {
                runCurrentBuild()
            } label: {
                Group {
                    if isBuilding {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "play.fill")
                    }
                }
                .frame(width: 32, height: 32)
            }
            .disabled(toolchain == nil || compilerEngine == nil || isBuilding)
            .keyboardShortcut("b", modifiers: .command)
            .help("Build Project and Export Unsigned IPA (⌘B)")

            Button {
                saveActiveDocument()
            } label: {
                Image(systemName: "square.and.arrow.down")
                    .frame(width: 30, height: 30)
            }
            .disabled(activeDocument == nil || activeDocument?.isDirty != true)
            .keyboardShortcut("s", modifiers: .command)
            .help("Save (⌘S)")

            HStack(spacing: 7) {
                Image(systemName: "hammer.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 0) {
                    Text(project?.name ?? "Compiler Bootstrap")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text("arm64 iOS")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 7))

            Spacer()

            Menu {
                Button("Workspace tools") { toolsTab = "Files"; showingTools = true }
                Button("Find in file") { findVisible.toggle() }.keyboardShortcut("f", modifiers: .command)
                Button("Search project") { toolsTab = "Search"; showingTools = true }.keyboardShortcut("f", modifiers: [.command, .shift])
                Button("Toggle split editor") { splitEditor.toggle(); secondDocumentID = documents.first(where: { $0.id != activeDocumentID })?.id ?? activeDocumentID }.keyboardShortcut("\\", modifiers: .command)
                Button("Save all") { do { try saveAllDocuments() } catch { appendLog("Save failed: \(error)") } }.keyboardShortcut("s", modifiers: [.command, .shift])
                Button("Close current file") { if let activeDocumentID { closeDocument(activeDocumentID) } }.keyboardShortcut("w", modifiers: .command)
                Button("GitHub") { showingGitHub = true }
                Button("Assistant") { showingAssistant = true }.keyboardShortcut("j", modifiers: [.command, .shift])
            } label: { Image(systemName: "slider.horizontal.3").frame(width: 30, height: 30) }
            .disabled(isBuilding)

            ViewThatFits(in: .horizontal) {
                connectionActions.labelStyle(.titleAndIcon)
                connectionActions.labelStyle(.iconOnly)
            }

            buildStatusPill

            Button {
                consoleVisible.toggle()
            } label: {
                Image(systemName: "rectangle.bottomthird.inset.filled")
                    .frame(width: 30, height: 30)
            }
            .help("Toggle Debug Area")

            Button {
                inspectorVisible.toggle()
            } label: {
                Image(systemName: "sidebar.right")
                    .frame(width: 30, height: 30)
            }
            .help("Toggle Inspector")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .frame(height: 52)
        .background(.ultraThinMaterial)
    }

    private var connectionActions: some View {
        HStack(spacing: 8) {
            Button { showingGitHub = true } label: { Label("GitHub", systemImage: "arrow.triangle.branch").frame(minHeight: 32) }
                .help("GitHub repositories and account")
            Button { showingAssistant = true } label: { Label("Assistant", systemImage: "bubble.left.and.bubble.right").frame(minHeight: 32) }
                .help("Assistant chat and connection")
        }.font(.caption.weight(.semibold)).buttonStyle(.bordered).disabled(isBuilding)
    }

    private var buildStatusPill: some View {
        HStack(spacing: 7) {
            Image(systemName: engineReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(engineReady ? .green : .orange)
            Text(isBuilding ? "Building…" : (engineReady ? "Ready" : "Engine setup"))
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(.thinMaterial, in: Capsule())
    }

    private var navigatorPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text("PROJECT")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    showingProjectImporter = true
                } label: {
                    Image(systemName: "plus")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .frame(height: 36)

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Filter", text: $navigatorSearch)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 9)
            .frame(height: 29)
            .background(Color(uiColor: .tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 8)
            .padding(.bottom, 7)

            Divider()

            if project == nil {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "folder")
                        .font(.system(size: 35))
                        .foregroundStyle(.secondary)
                    Text("Open a Swift project")
                        .font(.callout.weight(.medium))
                    Text("Files appear here and open directly in the editor.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Open Project…") {
                        showingProjectImporter = true
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                }
                .padding(18)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        HStack(spacing: 6) {
                            Image(systemName: "shippingbox.fill")
                                .foregroundStyle(.secondary)
                            Text(project?.name ?? "Project")
                                .font(.system(size: 12, weight: .semibold))
                            Spacer()
                        }
                        .padding(.horizontal, 9)
                        .frame(height: 27)

                        ForEach(filteredNavigatorEntries) { entry in
                            Button {
                                if !entry.isDirectory {
                                    openFile(entry)
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Color.clear.frame(width: CGFloat(entry.depth) * 13, height: 1)
                                    Image(systemName: entry.systemImage)
                                        .frame(width: 15)
                                        .foregroundStyle(entry.isDirectory ? .secondary : .primary)
                                    Text(entry.name)
                                        .font(.system(size: 12))
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 8)
                                .frame(height: 25)
                                .contentShape(Rectangle())
                                .background(activeDocumentID == entry.url ? Color.accentColor.opacity(0.20) : .clear)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("File actions…") { toolsPath = entry.relativePath; toolsTab = "Files"; showingTools = true }
                            }
                        }
                    }
                }
            }
        }
        .background(Color(uiColor: .secondarySystemBackground))
    }

    private var editorTabs: some View {
        HStack(spacing: 0) {
            if documents.isEmpty {
                Text("No Editor")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(documents) { document in
                            Button {
                                activeDocumentID = document.id
                            } label: {
                                HStack(spacing: 7) {
                                    Image(systemName: document.language == .swift ? "swift" : "chevron.left.forwardslash.chevron.right")
                                        .font(.caption)
                                    Text(document.title)
                                        .font(.system(size: 12, weight: activeDocumentID == document.id ? .medium : .regular))
                                    if document.isDirty {
                                        Circle()
                                            .frame(width: 6, height: 6)
                                    }
                                    Button {
                                        closeDocument(document.id)
                                    } label: {
                                        Image(systemName: "xmark")
                                            .font(.system(size: 8, weight: .bold))
                                            .frame(width: 16, height: 16)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal, 10)
                                .frame(height: 35)
                                .background(activeDocumentID == document.id ? Color(uiColor: .secondarySystemBackground) : Color.clear)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Divider()
                                .frame(height: 35)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(height: 35)
        .background(Color(uiColor: .tertiarySystemBackground))
    }

    @ViewBuilder
    private var editorSurface: some View {
        if let document = activeDocument {
            VStack(spacing: 0) {
                HStack(spacing: 5) {
                    Image(systemName: "shippingbox")
                        .font(.caption2)
                    Text(project?.name ?? "CompilerProbe")
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8))
                    Text(document.title)
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(document.language.rawValue)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .frame(height: 29)
                .background(Color(uiColor: .secondarySystemBackground))

                IDECodeEditor(
                    text: activeTextBinding,
                    language: document.language,
                    command: editorCommand,
                    symbols: completionSymbols,
                    diagnostics: diagnosticsFor(document.url)
                )
                if findVisible { findBar }
                ForEach(diagnosticsFor(document.url).prefix(4)) { diagnostic in
                    Button { editorCommand = IDEEditorCommand(action: .jump(diagnostic.line, diagnostic.column)) } label: {
                        Text("Line \(diagnostic.line): \(diagnostic.message)").font(.caption).foregroundStyle(diagnostic.severity == "error" ? .red : .orange).lineLimit(2)
                    }
                }
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Image(systemName: "hammer.fill").font(.system(size: 36)).foregroundStyle(.cyan)
                        .padding(18).background(Color.cyan.opacity(0.1), in: RoundedRectangle(cornerRadius: 20))
                    Text(project == nil ? "Your next app starts here" : "Ready when you are").font(.largeTitle.bold())
                    Text(project == nil ? "Open a project, bring in code from GitHub, or start with a working example." : "Choose a source file in the navigator to start editing.")
                        .foregroundStyle(.secondary)
                    VStack(spacing: 12) {
                        welcomeAction("Open project", detail: "Choose a folder from Files", symbol: "folder") { showingProjectImporter = true }
                        welcomeAction("Import from GitHub", detail: "Public repositories work without signing in", symbol: "arrow.triangle.branch") { showingGitHub = true }
                        welcomeAction("Create example app", detail: "A small Swift app ready to build", symbol: "plus.app") { createAppProject() }
                        welcomeAction("Open assistant", detail: "Connect your Codex host and chat about your code", symbol: "bubble.left.and.bubble.right") { showingAssistant = true }
                    }
                    Button("Open compiler probe") { prepareHelloCompilerJob(openInEditor: true) }.font(.caption).disabled(toolchain == nil)
                }.frame(maxWidth: 560, alignment: .leading).padding(32).frame(maxWidth: .infinity)
            }.background(Color(uiColor: .systemGroupedBackground))
        }
    }

    private func welcomeAction(_ title: String, detail: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol).font(.title3).foregroundStyle(.cyan).frame(width: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline).foregroundStyle(.primary)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        }.buttonStyle(.plain).disabled(isBuilding)
    }

    private var inspectorPanel: some View {
        VStack(spacing: 0) {
            Picker("Inspector", selection: $selectedInspectorTab) {
                ForEach(InspectorTab.allCases) { tab in
                    Image(systemName: tab.systemImage)
                        .tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(8)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch selectedInspectorTab {
                    case .file:
                        fileInspector
                    case .target:
                        targetInspector
                    case .build:
                        buildInspector
                    }
                }
                .padding(12)
            }
        }
        .background(Color(uiColor: .secondarySystemBackground))
    }

    @ViewBuilder
    private var fileInspector: some View {
        inspectorHeading("File Inspector")
        if let document = activeDocument {
            inspectorRow("Name", document.title)
            inspectorRow("Type", document.language.rawValue)
            inspectorRow("State", document.isDirty ? "Modified" : "Saved")
            inspectorRow("Path", document.url.path)
            Button {
                saveActiveDocument()
            } label: {
                Label("Save File", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.bordered)
            .disabled(!document.isDirty)
        } else {
            Text("Select a file to inspect its properties.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var targetInspector: some View {
        inspectorHeading("Target")
        inspectorRow("Architecture", capabilities.architecture)
        inspectorRow("Platform", capabilities.isRunningOnIOSFamily ? "iOS / iPadOS" : "Unknown")
        inspectorRow("Deployment", "iOS 16.0")
        inspectorRow("SDK", toolchain.map(sdkDisplayName) ?? "Preparing…")
        inspectorRow("SDK Source", toolchainSource)

        Divider()
        inspectorHeading("Compiler Engine")
        inspectorRow("Swift", compilerEngine == nil ? "Missing" : "Ready")
        inspectorRow("Clang", compilerEngine?.supportsClangFrontend == true ? "Ready" : "Missing")
        inspectorRow("Mach-O LLD", compilerEngine?.supportsMachOLLD == true ? "Ready" : "Missing")
        inspectorRow("Version", compilerEngine?.version ?? compilerEngineStatus)
    }

    @ViewBuilder
    private var buildInspector: some View {
        inspectorHeading("Build Tools")
        Button {
            createAppProject()
        } label: {
            Label("New Example App", systemImage: "doc.badge.plus")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .disabled(isBuilding)

        Button {
            buildProjectIPA()
        } label: {
            Label("Build Unsigned IPA", systemImage: "shippingbox")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.borderedProminent)
        .disabled(project == nil || !nativePipelineReady || isBuilding)

        if let latestIPA {
            ShareLink(item: latestIPA) {
                Label("Export Unsigned IPA…", systemImage: "square.and.arrow.up")
            }
        }
        if previousBuildLog != nil {
            Button {
                showingPreviousBuildLog = true
            } label: {
                Label("Previous Build Log", systemImage: "doc.text.magnifyingglass")
            }
            .disabled(isBuilding)
        }
        if isBuildingProject {
            Button("Cancel After Current Step") {
                projectBuildProgress?.cancel()
                appendLog("Cancellation requested; waiting for the native compiler call to return.")
            }
        }
        Divider()
        Button {
            runCompilerProbe()
        } label: {
            Label("Validate SDK + VM", systemImage: "checkmark.seal")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .disabled(toolchain == nil)

        Button {
            prepareHelloCompilerJob(openInEditor: true)
        } label: {
            Label("Prepare Swift Probe", systemImage: "swift")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .disabled(toolchain == nil || isBuilding)

        Button {
            compileHello()
        } label: {
            Label("Compile Swift → .o", systemImage: "hammer")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .disabled(helloPlan == nil || compilerEngine == nil || isBuilding)

        Button {
            runClangLLDProbe()
        } label: {
            Label("C → .o → Mach-O", systemImage: "link")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!nativePipelineReady || isBuilding)

        Button {
            showingToolchainImporter = true
        } label: {
            Label("Import Darwin SDK…", systemImage: "shippingbox")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
    }

    private func inspectorHeading(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.secondary)
    }

    private func inspectorRow(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var consolePanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("Console", selection: $selectedConsoleTab) {
                    ForEach(ConsoleTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 190)

                Spacer()

                if isBuilding {
                    ProgressView()
                        .controlSize(.small)
                    Text(buildPhase.isEmpty ? "Building" : buildPhase)
                        .font(.caption)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }

                Button {
                    logLines.removeAll(keepingCapacity: true)
                    appendLog("console cleared")
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(Color(uiColor: .tertiarySystemBackground))

            if isBuildingProject {
                ProgressView(value: Double(completedSteps), total: Double(max(1, totalSteps))).padding(.horizontal)
            }
            if selectedConsoleTab == .issues {
                List(diagnostics) { diagnostic in
                    Button { openDiagnostic(diagnostic) } label: {
                        Text("\(URL(fileURLWithPath: diagnostic.path).lastPathComponent):\(diagnostic.line) · \(diagnostic.message)")
                            .font(.system(size: 12, design: .monospaced)).foregroundStyle(diagnostic.severity == "error" ? .red : .orange)
                    }
                }
            } else { ScrollView {
                Text(consoleText)
                    .font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .secondarySystemBackground))
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 14) {
            Label(engineReady ? "Compiler Ready" : "Compiler Setup", systemImage: engineReady ? "checkmark.circle" : "gear")
            Text("arm64")
            Text("iOS 16.0+")
            if let toolchain {
                Text(sdkDisplayName(toolchain))
            }
            Spacer()
            if let activeDocument {
                Text(activeDocument.language.rawValue.uppercased())
                Text(activeDocument.isDirty ? "Modified" : "Saved")
            }
            Text("UTF-8")
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(.ultraThinMaterial)
    }

    // MARK: - Editor state

    private var workspaceToolsSheet: some View {
        NavigationStack {
            IDEProjectToolsView(root: project?.root, initialPath: toolsPath, initialTab: toolsTab,
                prepareMutation: saveAllDocuments, onChanged: refreshFilesAfterMutation,
                onOpen: { url, line in showingTools = false; openLocation(url, line: line) })
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingTools = false } } }
        }
    }
    private var githubSheet: some View {
        NavigationStack {
            IDEGitHubView(projectRoot: project?.root, prepareMutation: saveAllDocuments,
                onOpen: { url in showingGitHub = false; importProject(.success([url])) }, client: githubClient)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingGitHub = false } } }
        }
    }
    private var assistantSheet: some View {
        NavigationStack {
            IDEAssistantView(root: project?.root, files: projectChatFiles,
                onApply: applyAssistantEdits, onUndo: undoAssistantEdits, chat: assistantClient)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingAssistant = false } } }
        }
    }
    private var projectChatFiles: [String: String] {
        guard let root = project?.root.resolvingSymlinksInPath() else { return [:] }
        return Dictionary(documents.compactMap { document -> (String, String)? in
            let path = document.url.resolvingSymlinksInPath().path
            guard path.hasPrefix(root.path + "/") else { return nil }
            return (String(path.dropFirst(root.path.count + 1)), document.text)
        }, uniquingKeysWith: { _, latest in latest })
    }
    private var findBar: some View {
        HStack {
            TextField("Find", text: $findText).textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("Replace", text: $replacement).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Next") { editorCommand = IDEEditorCommand(action: .find(findText)) }
            Button("Replace") { editorCommand = IDEEditorCommand(action: .replace(findText, replacement, false)) }
            Button("All") { editorCommand = IDEEditorCommand(action: .replace(findText, replacement, true)) }
            Button { findVisible = false } label: { Image(systemName: "xmark") }
        }.font(.caption).padding(8)
    }
    @ViewBuilder private var secondaryEditor: some View {
        VStack {
            Picker("Second editor", selection: $secondDocumentID) {
                Text("Choose a file").tag(nil as URL?)
                ForEach(documents) { document in Text(document.title).tag(Optional(document.id)) }
            }
            if let id = secondDocumentID, let document = documents.first(where: { $0.id == id }) {
                IDECodeEditor(text: textBinding(for: id), language: document.language,
                    symbols: completionSymbols, diagnostics: diagnosticsFor(document.url)).id(id)
            } else { Text("Open a second file to edit side by side.").foregroundStyle(.secondary); Spacer() }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func textBinding(for id: URL) -> Binding<String> {
        Binding(get: { documents.first(where: { $0.id == id })?.text ?? "" }, set: { text in
            guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
            documents[index].text = text; documents[index].isDirty = true
        })
    }
    private func diagnosticsFor(_ url: URL) -> [MobileSourceDiagnostic] {
        diagnostics.filter { diagnostic in
            let source = diagnostic.path.hasPrefix("/") ? URL(fileURLWithPath: diagnostic.path) : project?.root.appendingPathComponent(diagnostic.path)
            return source?.resolvingSymlinksInPath() == url.resolvingSymlinksInPath()
        }
    }
    private func openDiagnostic(_ diagnostic: MobileSourceDiagnostic) {
        let url = diagnostic.path.hasPrefix("/") ? URL(fileURLWithPath: diagnostic.path) : project?.root.appendingPathComponent(diagnostic.path)
        if let url { openLocation(url, line: diagnostic.line, column: diagnostic.column) }
    }
    private func openLocation(_ url: URL, line: Int, column: Int = 1) {
        guard let root = project?.root.resolvingSymlinksInPath(), url.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else {
            appendLog("This diagnostic refers to a file outside the editable project."); return
        }
        if let entry = navigatorEntries.first(where: { $0.url.resolvingSymlinksInPath() == url.resolvingSymlinksInPath() }) {
            openFile(entry)
        } else { openGeneratedFile(url) }
        editorCommand = IDEEditorCommand(action: .jump(line, column))
    }
    private func saveAllDocuments() throws {
        guard !isBuilding else { throw MobileProjectBuildError.invalid("Wait for the current build before modifying project files") }
        for index in documents.indices where documents[index].isDirty {
            try documents[index].text.write(to: documents[index].url, atomically: true, encoding: .utf8)
            documents[index].isDirty = false
        }
    }
    private func refreshFilesAfterMutation() {
        guard let project else { return }
        navigatorEntries = IDEWorkspaceScanner.scan(root: project.root, maxDepth: 15)
        documents = documents.compactMap { document in
            guard let values = try? document.url.resourceValues(forKeys: [.fileSizeKey]), (values.fileSize ?? 0) <= 2_000_000,
                  let text = try? String(contentsOf: document.url, encoding: .utf8) else { return nil }
            return IDEDocument(url: document.url, text: text)
        }
        if !documents.contains(where: { $0.id == activeDocumentID }) { activeDocumentID = documents.first?.id }
        if !documents.contains(where: { $0.id == secondDocumentID }) { secondDocumentID = documents.first?.id }
        diagnostics = []
        refreshCompletionSymbols()
    }
    private func refreshCompletionSymbols() {
        guard let root = project?.root else { completionSymbols = []; return }
        Task {
            let symbols = await Task.detached { () -> [String] in
                guard let regex = try? NSRegularExpression(pattern: #"\b[A-Za-z_][A-Za-z0-9_]{2,}\b"#) else { return [] }
                var names: Set<String> = [], bytes = 0
                for entry in IDEWorkspaceScanner.scan(root: root, maxDepth: 15) where !entry.isDirectory {
                    guard let size = try? entry.url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                          size <= 200_000, bytes + size <= 1_000_000,
                          let text = try? String(contentsOf: entry.url, encoding: .utf8) else { continue }
                    bytes += size
                    let source = text as NSString
                    for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
                        names.insert(source.substring(with: match.range))
                        if names.count >= 4000 { return names.sorted() }
                    }
                }
                return names.sorted()
            }.value
            if project?.root == root { completionSymbols = symbols }
        }
    }
    private func applyAssistantEdits(_ edits: [MobileWorkspaceTools.Edit], expected: [String: String]) throws {
        guard let root = project?.root else { throw MobileProjectBuildError.invalid("Open a project before applying edits") }
        for (path, before) in expected {
            if let current = projectChatFiles[path], current != before { throw MobileProjectBuildError.invalid("\(path) changed since the message was sent. Send fresh context first.") }
        }
        try saveAllDocuments()
        lastAIEdit = try MobileWorkspaceTools.apply(edits, expected: expected, in: root)
        refreshFilesAfterMutation()
        appendLog("Assistant: applied \(edits.count) reviewed file changes.")
    }
    private func undoAssistantEdits() throws {
        guard let root = project?.root, let lastAIEdit else { throw MobileProjectBuildError.invalid("No AI edit to undo") }
        try saveAllDocuments()
        try MobileWorkspaceTools.undo(lastAIEdit, in: root)
        self.lastAIEdit = nil
        refreshFilesAfterMutation()
        appendLog("Assistant edit undone.")
    }

    private var activeDocument: IDEDocument? {
        guard let activeDocumentID else { return nil }
        return documents.first(where: { $0.id == activeDocumentID })
    }

    private var activeTextBinding: Binding<String> {
        Binding(
            get: { activeDocument?.text ?? "" },
            set: { newValue in
                guard let activeDocumentID,
                      let index = documents.firstIndex(where: { $0.id == activeDocumentID }) else { return }
                documents[index].text = newValue
                documents[index].isDirty = true
            }
        )
    }

    private var filteredNavigatorEntries: [IDEFileEntry] {
        guard !navigatorSearch.isEmpty else { return navigatorEntries }
        return navigatorEntries.filter {
            $0.name.localizedCaseInsensitiveContains(navigatorSearch) ||
            $0.relativePath.localizedCaseInsensitiveContains(navigatorSearch)
        }
    }

    private var isBuilding: Bool {
        isCompilingHello || isRunningNativeProbe || isBuildingProject || isPreparingBundledRuntime
    }

    private var engineReady: Bool {
        compilerEngine != nil && toolchain != nil
    }

    private var nativePipelineReady: Bool {
        toolchain != nil &&
        compilerEngine?.supportsClangFrontend == true &&
        compilerEngine?.supportsMachOLLD == true
    }

    private var consoleText: String {
        switch selectedConsoleTab {
        case .build:
            return logLines.joined(separator: "\n")
        case .console:
            return "XTool runtime console\n\n" + logLines.suffix(30).joined(separator: "\n")
        case .issues:
            return diagnostics.map(\.message).joined(separator: "\n")
        }
    }

    private func openFile(_ entry: IDEFileEntry) {
        editorCommand = nil
        if documents.contains(where: { $0.id == entry.url }) {
            activeDocumentID = entry.url
            return
        }

        do {
            let values = try entry.url.resourceValues(forKeys: [.fileSizeKey])
            guard (values.fileSize ?? 0) <= 2_000_000 else { throw MobileProjectBuildError.invalid("Editor files are limited to 2 MB") }
            let text = try String(contentsOf: entry.url, encoding: .utf8)
            documents.append(IDEDocument(url: entry.url, text: text))
            activeDocumentID = entry.url
            appendLog("editor: opened \(entry.relativePath)")
        } catch {
            appendLog("editor: could not open \(entry.relativePath): \(error)")
        }
    }

    private func openGeneratedFile(_ url: URL) {
        editorCommand = nil
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 2_000_000 else { return }
        if let existingIndex = documents.firstIndex(where: { $0.id == url }) {
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                documents[existingIndex].text = text
                documents[existingIndex].isDirty = false
            }
            activeDocumentID = url
            return
        }
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            documents.append(IDEDocument(url: url, text: text))
            activeDocumentID = url
        }
    }

    private func saveActiveDocument() {
        guard let activeDocumentID,
              let index = documents.firstIndex(where: { $0.id == activeDocumentID }) else { return }
        do {
            try documents[index].text.write(to: documents[index].url, atomically: true, encoding: .utf8)
            documents[index].isDirty = false
            appendLog("editor: saved \(documents[index].title)")
            refreshCompletionSymbols()
        } catch {
            appendLog("editor: save failed: \(error)")
        }
    }

    private func closeDocument(_ id: URL) {
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
        if documents[index].isDirty {
            do { try documents[index].text.write(to: documents[index].url, atomically: true, encoding: .utf8) }
            catch { appendLog("Could not save before closing: \(error)"); return }
        }
        documents.remove(at: index)
        if secondDocumentID == id { secondDocumentID = documents.first?.id }
        if activeDocumentID == id {
            activeDocumentID = documents.indices.contains(index)
                ? documents[index].id
                : documents.last?.id
        }
    }

    private func runCurrentBuild() {
        guard !githubClient.busy else { appendLog("Wait for the GitHub action to finish before building."); return }
        consoleVisible = true
        selectedConsoleTab = .build
        if project != nil {
            buildProjectIPA()
        } else if nativePipelineReady {
            runClangLLDProbe()
        } else if helloPlan != nil {
            compileHello()
        } else {
            prepareHelloCompilerJob(openInEditor: true)
            compileHello()
        }
    }

    private func createAppProject() {
        guard !isBuilding else { return }
        do {
            let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true)
            let created = try MobileAppStarter.create(in: documents.appendingPathComponent("Projects"))
            importProject(.success([created.root]))
            openGeneratedFile(created.root.appendingPathComponent("Sources/App/ContentView.swift"))
            appendLog("Example app created. Edit it, then choose Build Unsigned IPA.")
        } catch { appendLog("Could not create example: \(error)") }
    }

    private func buildProjectIPA() {
        guard !isBuilding, !githubClient.busy, let project, let toolchain, let engine = compilerEngine else { return }
        do {
            // Save every edited tab. A failed save must stop the build.
            for index in documents.indices where documents[index].isDirty {
                try documents[index].text.write(to: documents[index].url, atomically: true, encoding: .utf8)
                documents[index].isDirty = false
            }
            _ = try MobileAppManifest.load(from: project.root)
            let output = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true).appendingPathComponent("Builds")
            let progress = MobileBuildProgress()
            projectBuildProgress = progress
            latestIPA = nil
            diagnostics = []; buildPhase = "Preparing build"; completedSteps = 0; totalSteps = 1
            isBuildingProject = true
            consoleVisible = true
            selectedConsoleTab = .build
            appendLog("Building \(project.name)…")
            Task {
                let worker = Task.detached(priority: .userInitiated) {
                    defer { progress.finish() }
                    return try MobileProjectBuilder.build(project: project, toolchain: toolchain,
                        engine: engine, outputDirectory: output,
                        log: { progress.append($0) }, isCancelled: { progress.isCancelled })
                }
                while !progress.isFinished {
                    for line in progress.drain() { appendLog(line) }
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
                for line in progress.drain() { appendLog(line) }
                do {
                    let result = try await worker.value
                    latestIPA = result.ipaURL
                    appendLog("Ready to export: \(result.ipaURL.lastPathComponent)")
                } catch is CancellationError {
                    appendLog("Build cancelled.")
                } catch { appendLog("Project build failed: \(error)") }
                isBuildingProject = false
                projectBuildProgress = nil
                recoverPreviousBuildLog(automaticallyPresent: false)
            }
        } catch { appendLog("Cannot build project: \(error)") }
    }

    // MARK: - Compiler/runtime discovery

    private func recoverPreviousBuildLog(automaticallyPresent: Bool) {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let builds = documents.appendingPathComponent("Builds")
        Task {
            do {
                let recovered = try await Task.detached(priority: .utility) {
                    try MobileBuildLogRecovery.latest(in: builds)
                }.value
                guard !isBuildingProject else { return }
                previousBuildLog = recovered
                if automaticallyPresent, let recovered, recovered.wasInterrupted {
                    appendLog(recovered.summary + " Open Previous Build Log to view or share the saved output.")
                    consoleVisible = true
                    selectedConsoleTab = .build
                    showingPreviousBuildLog = true
                }
            } catch {
                appendLog("Could not recover previous build log: \(error)")
            }
        }
    }

    private func discoverCompilerEngineIfNeeded() {
        guard !attemptedCompilerEngineDiscovery else { return }
        attemptedCompilerEngineDiscovery = true

        do {
            let engine = try MobileCompilerEngine.loadFromApplicationBundle()
            compilerEngine = engine
            compilerEngineStatus = "Loaded: \(engine.version)"
            appendLog("compiler engine: loaded")
            appendLog("compiler engine version: \(engine.version)")
            appendLog("compiler engine path: \(engine.location.path)")
            appendLog("compiler engine clang: \(engine.supportsClangFrontend ? "ready" : "missing")")
            appendLog("compiler engine lld-macho: \(engine.supportsMachOLLD ? "ready" : "missing")")
        } catch {
            compilerEngine = nil
            compilerEngineStatus = "Not bundled"
            appendLog("compiler engine: not bundled yet")
        }
    }

    private func discoverBundledRuntimeIfNeeded() {
        guard !attemptedBundledRuntimeDiscovery else { return }
        attemptedBundledRuntimeDiscovery = true

        let fileManager = FileManager.default
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            appendLog("bundled runtime: Application Support unavailable")
            return
        }

        let extractedRoot = applicationSupport.appendingPathComponent(
            "XToolMobileRuntime",
            isDirectory: true
        )

        let existing = PreparedToolchain(root: extractedRoot)
        if (try? existing.validate()) != nil {
            toolchain = existing
            toolchainScopeURL = nil
            toolchainSource = "Bundled archive"
            appendLog("bundled runtime cache: valid")
            appendLog("SDK: \(sdkDisplayName(existing))")
            return
        }

        guard let archiveURL = Bundle.main.url(
            forResource: "MobileRuntime",
            withExtension: "tar"
        ) else {
            appendLog("bundled runtime archive: not present")
            return
        }

        isPreparingBundledRuntime = true
        appendLog("bundled runtime archive: found")
        appendLog("bundled runtime: extracting to Application Support...")

        Task {
            do {
                let selected = try await Task.detached(priority: .userInitiated) {
                    let fileManager = FileManager.default
                    try fileManager.createDirectory(
                        at: applicationSupport,
                        withIntermediateDirectories: true
                    )

                    if fileManager.fileExists(atPath: extractedRoot.path) {
                        try fileManager.removeItem(at: extractedRoot)
                    }

                    try MobileRuntimeArchive.extractTar(
                        at: archiveURL,
                        to: applicationSupport
                    )

                    let selected = PreparedToolchain(root: extractedRoot)
                    try selected.validate()
                    return selected
                }.value

                toolchain = selected
                toolchainScopeURL = nil
                toolchainSource = "Bundled archive"
                isPreparingBundledRuntime = false
                appendLog("bundled runtime: extracted + valid")
                appendLog("SDK: \(sdkDisplayName(selected))")
            } catch {
                isPreparingBundledRuntime = false
                appendLog("bundled runtime extraction failed: \(String(describing: error))")
            }
        }
    }

    private func importProject(_ result: Result<[URL], Error>) {
        guard !isBuilding, !assistantClient.busy else { appendLog("Wait for the build or assistant response before changing projects."); return }
        do {
            guard let url = try result.get().first else { return }
            let scoped = url.startAccessingSecurityScopedResource()

            let selected = MobileProject(root: url)
            do { try selected.validate(); try saveAllDocuments() } catch {
                if scoped { url.stopAccessingSecurityScopedResource() }
                throw error
            }
            releaseSecurityScope(for: projectScopeURL)
            project = selected
            assistantClient.load(root: url)
            projectScopeURL = scoped ? url : nil
            latestIPA = nil
            navigatorEntries = IDEWorkspaceScanner.scan(root: url, maxDepth: 15)
            documents.removeAll()
            activeDocumentID = nil
            secondDocumentID = nil
            lastAIEdit = nil
            diagnostics = []
            refreshCompletionSymbols()
            appendLog("project: \(selected.name)")
            appendLog(FileManager.default.fileExists(atPath: url.appendingPathComponent(MobileAppManifest.filename).path)
                ? "Mobile build configuration: found" : "SwiftPM project: prepare xtool-mobile.json before building on-device")
            appendLog("navigator: \(navigatorEntries.filter { !$0.isDirectory }.count) editable files")
        } catch {
            appendLog("project import failed: \(String(describing: error))")
        }
    }

    private func importToolchain(_ result: Result<[URL], Error>) {
        guard !isBuilding else { appendLog("Wait for the current build before changing SDKs."); return }
        do {
            guard let url = try result.get().first else { return }
            releaseSecurityScope(for: toolchainScopeURL)
            _ = url.startAccessingSecurityScopedResource()

            let selected = PreparedToolchain(root: url)
            try selected.validate()
            let sdk = try selected.iPhoneOSSDK()
            toolchain = selected
            toolchainScopeURL = url
            toolchainSource = "Files"
            appendLog("external Darwin SDK tree: valid")
            appendLog("SDK: \(sdk.lastPathComponent)")
        } catch {
            appendLog("Darwin SDK import failed: \(String(describing: error))")
        }
    }

    // MARK: - Existing proven compiler bridge

    private func runCompilerProbe() {
        guard let toolchain else {
            appendLog("probe failed: no Darwin SDK selected")
            return
        }

        do {
            appendLog("probe: validating Darwin SDK...")
            try toolchain.validate()
            let sdk = try toolchain.iPhoneOSSDK()
            appendLog("probe: \(sdk.lastPathComponent) found")
            appendLog("probe: Linux compiler executable not required")

            let reservationBytes = 2 * 1024 * 1024 * 1024
            let reserved = MobilePlatformCapabilities.canReserveAddressSpace(bytes: reservationBytes)
            appendLog("probe: 2 GiB VM reservation \(reserved ? "OK" : "FAILED")")
            if let compilerEngine {
                appendLog("probe: compiler engine loaded: \(compilerEngine.version)")
                appendLog("probe: Clang frontend \(compilerEngine.supportsClangFrontend ? "READY" : "missing")")
                appendLog("probe: Mach-O LLD \(compilerEngine.supportsMachOLLD ? "READY" : "missing")")
            } else {
                appendLog("probe: compiler engine not bundled")
            }
            appendLog(reserved ? "probe: READY for embedded compiler bridge" : "probe: memory capability needs investigation")
        } catch {
            appendLog("probe failed: \(String(describing: error))")
        }
    }

    private func prepareHelloCompilerJob(openInEditor: Bool = false) {
        guard let toolchain else {
            appendLog("hello: no Darwin SDK selected")
            return
        }

        do {
            guard let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first else {
                appendLog("hello: Application Support unavailable")
                return
            }

            let workspace = applicationSupport.appendingPathComponent(
                "CompilerProbe",
                isDirectory: true
            )
            let plan = try MobileCompilerPlan.helloWorld(
                toolchain: toolchain,
                workspace: workspace
            )
            helloPlan = plan

            appendLog("hello: source written: \(plan.sourceURL.path)")
            appendLog("hello: target: \(plan.targetTriple)")
            appendLog("hello: output: \(plan.objectURL.path)")
            appendLog("hello: frontend job prepared")
            appendLog("hello argv:")
            for argument in plan.arguments {
                appendLog("  \(argument)")
            }
            appendLog(
                compilerEngine == nil
                    ? "hello: awaiting bundled compiler engine"
                    : "hello: ready to execute performFrontend in-process"
            )
            if openInEditor {
                openGeneratedFile(plan.sourceURL)
            }
        } catch {
            appendLog("hello preparation failed: \(String(describing: error))")
        }
    }

    private func compileHello() {
        guard let plan = helloPlan else {
            appendLog("compile: prepare Hello.swift first")
            return
        }
        guard let engine = compilerEngine else {
            appendLog("compile: compiler engine is not bundled")
            return
        }

        isCompilingHello = true
        consoleVisible = true
        appendLog("compile: entering in-process Swift frontend...")

        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try engine.run(plan)
                }.value

                appendCompilerDiagnostics(result.standardError)

                guard result.succeeded else {
                    appendLog("compile: frontend exited with code \(result.exitCode)")
                    isCompilingHello = false
                    return
                }

                guard FileManager.default.fileExists(atPath: plan.objectURL.path) else {
                    appendLog("compile: frontend returned success but Hello.o is missing")
                    isCompilingHello = false
                    return
                }

                let attributes = try FileManager.default.attributesOfItem(
                    atPath: plan.objectURL.path
                )
                let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0
                appendLog("compile: SUCCESS")
                appendLog("compile: Hello.o produced (\(byteCount) bytes)")
                appendLog("compile: \(plan.objectURL.path)")
                isCompilingHello = false
            } catch {
                appendLog("compile failed: \(String(describing: error))")
                isCompilingHello = false
            }
        }
    }

    private func runClangLLDProbe() {
        guard let toolchain else {
            appendLog("native probe: no Darwin SDK selected")
            return
        }
        guard let engine = compilerEngine else {
            appendLog("native probe: compiler engine is not bundled")
            return
        }
        guard engine.supportsClangFrontend else {
            appendLog("native probe: embedded Clang frontend is missing")
            return
        }
        guard engine.supportsMachOLLD else {
            appendLog("native probe: embedded Mach-O LLD is missing")
            return
        }

        do {
            guard let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first else {
                appendLog("native probe: Application Support unavailable")
                return
            }

            let workspace = applicationSupport.appendingPathComponent(
                "NativeCompilerProbe",
                isDirectory: true
            )
            let plan = try MobileClangLLDProbePlan.helloC(
                toolchain: toolchain,
                workspace: workspace
            )

            isRunningNativeProbe = true
            consoleVisible = true
            appendLog("native probe: source: \(plan.sourceURL.path)")
            appendLog("native probe: target: \(plan.targetTriple)")
            appendLog("native probe: entering in-process Clang frontend...")
            appendLog("clang argv:")
            for argument in plan.clangArguments {
                appendLog("  \(argument)")
            }

            Task {
                do {
                    let clangResult = try await Task.detached(priority: .userInitiated) {
                        try engine.runClangFrontend(arguments: plan.clangArguments)
                    }.value

                    appendNativeDiagnostics(label: "clang", data: clangResult.standardError)
                    guard clangResult.succeeded else {
                        appendLog("native probe: Clang exited with code \(clangResult.exitCode)")
                        isRunningNativeProbe = false
                        return
                    }

                    guard FileManager.default.fileExists(atPath: plan.objectURL.path) else {
                        appendLog("native probe: Clang returned success but HelloC.o is missing")
                        isRunningNativeProbe = false
                        return
                    }

                    let objectAttributes = try FileManager.default.attributesOfItem(
                        atPath: plan.objectURL.path
                    )
                    let objectBytes = (objectAttributes[.size] as? NSNumber)?.int64Value ?? 0
                    appendLog("native probe: Clang SUCCESS — HelloC.o (\(objectBytes) bytes)")
                    appendLog("native probe: entering in-process Mach-O LLD...")
                    appendLog("lld argv:")
                    for argument in plan.lldArguments {
                        appendLog("  \(argument)")
                    }

                    let lldResult = try await Task.detached(priority: .userInitiated) {
                        try engine.runMachOLLD(arguments: plan.lldArguments)
                    }.value

                    appendNativeDiagnostics(label: "lld", data: lldResult.standardError)
                    guard lldResult.succeeded else {
                        appendLog("native probe: LLD exited with code \(lldResult.exitCode)")
                        isRunningNativeProbe = false
                        return
                    }

                    guard FileManager.default.fileExists(atPath: plan.executableURL.path) else {
                        appendLog("native probe: LLD returned success but Mach-O output is missing")
                        isRunningNativeProbe = false
                        return
                    }

                    let executableAttributes = try FileManager.default.attributesOfItem(
                        atPath: plan.executableURL.path
                    )
                    let executableBytes = (executableAttributes[.size] as? NSNumber)?.int64Value ?? 0
                    appendLog("native probe: LLD SUCCESS — arm64 iOS Mach-O (\(executableBytes) bytes)")
                    appendLog("native probe: \(plan.executableURL.path)")
                    appendLog("native probe: C + LLD IN-PROCESS BOOTSTRAP COMPLETE")
                    isRunningNativeProbe = false
                } catch {
                    appendLog("native probe failed: \(String(describing: error))")
                    isRunningNativeProbe = false
                }
            }
        } catch {
            appendLog("native probe preparation failed: \(String(describing: error))")
            isRunningNativeProbe = false
        }
    }

    // MARK: - Logging/utilities

    private func appendCompilerDiagnostics(_ data: Data) {
        guard !data.isEmpty else {
            appendLog("compile diagnostics: <none captured>")
            return
        }

        appendLog("compile diagnostics:")
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(whereSeparator: \.isNewline) {
            appendLog("  \(line)")
        }
    }

    private func appendNativeDiagnostics(label: String, data: Data) {
        guard !data.isEmpty else {
            appendLog("\(label) diagnostics: <none captured>")
            return
        }

        appendLog("\(label) diagnostics:")
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(whereSeparator: \.isNewline) {
            appendLog("  \(line)")
        }
    }

    private func sdkDisplayName(_ toolchain: PreparedToolchain) -> String {
        (try? toolchain.iPhoneOSSDK().lastPathComponent) ?? "Missing"
    }

    private func appendLog(_ line: String) {
        logLines.append(line)
        while logLines.count > 500 || (logLines.count > 1 && logLines.reduce(0, { $0 + $1.utf8.count }) > 2_000_000) { logLines.removeFirst() }
        for diagnostic in MobileSourceDiagnostic.parse(line) where diagnostic.severity != "note" {
            if diagnostics.count < 200, !diagnostics.contains(diagnostic) { diagnostics.append(diagnostic) }
        }
        if line.hasPrefix("Compiling ") || line.hasPrefix("Linking ") || line == "Packaging unsigned IPA" { buildPhase = line }
        if line.hasPrefix("Build progress:"), let value = line.split(separator: " ").last {
            let parts = value.split(separator: "/")
            if parts.count == 2, let done = Int(parts[0]), let total = Int(parts[1]) { completedSteps = done; totalSteps = total }
        }
    }

    private func releaseSecurityScope(for url: URL?) {
        url?.stopAccessingSecurityScopedResource()
    }
}

private enum InspectorTab: String, CaseIterable, Identifiable {
    case file
    case target
    case build

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .file: return "doc.text.magnifyingglass"
        case .target: return "scope"
        case .build: return "hammer"
        }
    }
}

private enum ConsoleTab: String, CaseIterable, Identifiable {
    case build = "Build"
    case console = "Console"
    case issues = "Issues"

    var id: String { rawValue }
}
