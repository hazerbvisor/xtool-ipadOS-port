import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw MobileProjectBuildError.invalid("TEST FAILED: " + message) }
}

private final class RecordingCompiler: MobileProjectCompiler, @unchecked Sendable {
    let supportsClangFrontend = true
    let supportsMachOLLD = true
    let location = URL(fileURLWithPath: "/unused/libXToolCompilerEngine.dylib")
    var modules: [String] = []
    var failModule: String?
    var obstructLinkOutput = false
    var swiftArguments: [[String]] = []
    var linkArguments: [String] = []
    func runSwiftFrontend(arguments: [String], diagnosticsURL: URL?) throws -> MobileBuildResult {
        try require(diagnosticsURL != nil, "Swift diagnostic capture has a persistent destination")
        try Data("Swift job started\n".utf8).write(to: diagnosticsURL!)
        func value(_ option: String) -> String { arguments[arguments.firstIndex(of: option)! + 1] }
        let name = value("-module-name")
        modules.append(name)
        swiftArguments.append(arguments)
        if name == failModule { return MobileBuildResult(standardError: Data("Expected compiler error".utf8), exitCode: 1) }
        try Data("object".utf8).write(to: URL(fileURLWithPath: value("-o")))
        try Data("module".utf8).write(to: URL(fileURLWithPath: value("-emit-module-path")))
        if obstructLinkOutput {
            let work = URL(fileURLWithPath: value("-emit-module-path")).deletingLastPathComponent().deletingLastPathComponent()
            try FileManager.default.createDirectory(at: work.appendingPathComponent("Products/HelloApp"), withIntermediateDirectories: true)
        }
        return MobileBuildResult()
    }
    func runClangFrontend(arguments: [String], diagnosticsURL: URL?) throws -> MobileBuildResult {
        try Data("C object".utf8).write(to: URL(fileURLWithPath: arguments[arguments.firstIndex(of: "-o")! + 1]))
        return MobileBuildResult()
    }
    func runMachOLLD(arguments: [String], diagnosticsURL: URL?) throws -> MobileBuildResult {
        try require(diagnosticsURL != nil, "linker diagnostic capture has a persistent destination")
        linkArguments = arguments
        let output = URL(fileURLWithPath: arguments[arguments.firstIndex(of: "-o")! + 1])
        try require(!FileManager.default.fileExists(atPath: output.path), "link output must be an unused file path, not a target folder")
        try Data([0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0, 0, 1, 0, 0, 0, 0, 2, 0, 0, 0]).write(to: output)
        return MobileBuildResult()
    }
}

@main struct ProjectPipelineChecks {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("xtool-project-tests-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        try workspaceChecks(in: root.appendingPathComponent("WorkspaceChecks"))
        let project = try MobileAppStarter.create(in: root)
        let toolchain = PreparedToolchain(root: root.appendingPathComponent("SDKFixture"))
        try fm.createDirectory(at: toolchain.iPhoneOSPlatform.appendingPathComponent("Developer/SDKs/iPhoneOS26.5.sdk"), withIntermediateDirectories: true)
        try fm.createDirectory(at: toolchain.toolchainDirectory.appendingPathComponent("usr/lib/swift/iphoneos"), withIntermediateDirectories: true)
        func runtimeArchive(_ relativePath: String, contents: String = "fixture archive") throws -> URL {
            let url = toolchain.toolchainDirectory.appendingPathComponent(relativePath).resolvingSymlinksInPath()
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
            return url
        }
        let runtime = try runtimeArchive("usr/lib/swift/clang/lib/darwin/libclang_rt.ios.a")
        let engine = RecordingCompiler()
        let output = try MobileProjectBuilder.build(project: project, toolchain: toolchain, engine: engine,
            outputDirectory: root.appendingPathComponent("Success"))
        try require(engine.modules == ["Greeting", "HelloApp"], "dependency compiled before app")
        try require(engine.swiftArguments[1].filter { $0.hasSuffix(".swift") }.count == 2, "all app files compiled together")
        try require(engine.swiftArguments.allSatisfy { $0.contains("prefer-serialized") && !$0.contains("only-serialized") }, "prebuilt loader remains enabled")
        try require(engine.linkArguments.contains("-no_adhoc_codesign"), "unsigned link")
        try require(engine.linkArguments.filter { $0.hasSuffix(".o") }.count == 2, "link all targets")
        let linkedExecutable = URL(fileURLWithPath: engine.linkArguments[engine.linkArguments.firstIndex(of: "-o")! + 1])
        try require(linkedExecutable.lastPathComponent == "HelloApp" && linkedExecutable.deletingLastPathComponent().lastPathComponent == "Products", "product uses separate output directory")
        try require(engine.linkArguments.filter { $0.hasSuffix(".o") }.allSatisfy { $0.contains("/Targets/") }, "target intermediates are separate from products")
        try require(engine.linkArguments.contains(runtime.path), "link iOS builtins for availability checks")
        try require(engine.linkArguments.firstIndex(of: runtime.path)! > engine.linkArguments.lastIndex(where: { $0.hasSuffix(".o") })!, "builtins follow object inputs")
        try require(!engine.linkArguments.contains { $0.hasSuffix("usr/lib/system") }, "omit missing SDK library directory")
        let ipaData = try Data(contentsOf: output.ipaURL)
        try require(ipaData.starts(with: [0x50, 0x4b, 0x03, 0x04]), "ZIP archive written")
        try require(ipaData.range(of: Data("Payload/HelloApp.app/Info.plist".utf8)) != nil, "IPA payload layout")
        let buildLog = try String(contentsOf: output.logURL, encoding: .utf8)
        try require(buildLog.contains(runtime.path) && buildLog.contains("Linker arguments:"), "log runtime selection and linker job")
        let recoveredSuccess = try MobileBuildLogRecovery.latest(in: root.appendingPathComponent("Success"))
        try require(recoveredSuccess != nil && recoveredSuccess?.wasInterrupted == false, "completed build is not reported as interrupted")
        let successReport = try String(contentsOf: recoveredSuccess!.reportURL, encoding: .utf8)
        try require(successReport.contains("===== Targets/HelloApp/swift.stderr ====="), "recover native diagnostics from new target layout")

        let obstructedEngine = RecordingCompiler()
        obstructedEngine.obstructLinkOutput = true
        do {
            _ = try MobileProjectBuilder.build(project: project, toolchain: toolchain, engine: obstructedEngine,
                outputDirectory: root.appendingPathComponent("ObstructedOutput"))
            throw NSError(domain: "Occupied linker output path was accepted", code: 1)
        } catch MobileProjectBuildError.invalid(let message) {
            try require(message.contains("Link output path is already occupied"), "explain output path collision")
        }
        try require(obstructedEngine.linkArguments.isEmpty, "reject output collision before entering native LLD")

        // Simulate process termination: persist a running stage and native
        // diagnostics without executing any completion/cleanup handler.
        let interruptedRoot = root.appendingPathComponent("Interrupted")
        let interruptedWork = interruptedRoot.appendingPathComponent("HelloApp-fixture")
        try fm.createDirectory(at: interruptedWork.appendingPathComponent("HelloApp"), withIntermediateDirectories: true)
        try Data("Building HelloApp\nCompiling HelloApp\n".utf8).write(to: interruptedWork.appendingPathComponent("build.log"))
        try MobileBuildLogRecovery.checkpoint(in: interruptedWork, stage: "Compiling HelloApp (Swift)")
        try Data((String(repeating: "x", count: 100_000) + "\nLast native diagnostic\n").utf8)
            .write(to: interruptedWork.appendingPathComponent("HelloApp/swift.stderr"))
        let recovered = try MobileBuildLogRecovery.latest(in: interruptedRoot)
        try require(recovered?.wasInterrupted == true, "unfinished build is detected after restart")
        try require(recovered?.summary.contains("Compiling HelloApp") == true, "recover active stage")
        try require(recovered?.preview.contains("Last native diagnostic") == true, "recover stderr written before termination")
        try require((recovered?.preview.utf8.count ?? Int.max) < 66_000, "preview is bounded")
        let report = try String(contentsOf: recovered!.reportURL, encoding: .utf8)
        try require(report.contains("Compiling HelloApp") && report.contains(String(repeating: "x", count: 100_000)), "share complete saved diagnostics")
        let recoveredAgain = try MobileBuildLogRecovery.latest(in: interruptedRoot)
        try require(recoveredAgain?.preview == recovered?.preview, "recovery can be repeated without deleting original logs")
        let olderWork = interruptedRoot.appendingPathComponent("OlderApp-fixture")
        try fm.createDirectory(at: olderWork, withIntermediateDirectories: true)
        let olderLog = olderWork.appendingPathComponent("build.log")
        try Data("Building OlderApp\nSUCCESS: OlderApp.ipa\n".utf8).write(to: olderLog)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: olderLog.path)
        let latest = try MobileBuildLogRecovery.latest(in: interruptedRoot)
        try require(latest?.reportURL == recovered?.reportURL, "select latest build log, ignoring recovery report timestamps")
        let absent = try MobileBuildLogRecovery.latest(in: root.appendingPathComponent("NoBuilds"))
        try require(absent == nil, "first launch without builds is harmless")
        try fm.removeItem(at: interruptedWork.appendingPathComponent("build-state.json"))
        let legacy = try MobileBuildLogRecovery.latest(in: interruptedRoot)
        try require(legacy?.wasInterrupted == true, "recover logs from older app versions without checkpoints")
        try MobileBuildLogRecovery.checkpoint(in: interruptedWork, stage: "Compiling HelloApp", status: .cancelled)
        let cancelled = try MobileBuildLogRecovery.latest(in: interruptedRoot)
        try require(cancelled?.wasInterrupted == false, "cancellation is not reported as a crash")

        // Empty canonical archive: fall back to the newest versioned device
        // runtime (numeric version order), never the host/simulator archive.
        try Data().write(to: runtime)
        let olderRuntime = try runtimeArchive("usr/lib/clang/9/lib/darwin/libclang_rt.ios.a")
        let newerRuntime = try runtimeArchive("usr/lib/clang/20/lib/darwin/libclang_rt.ios.a")
        _ = try runtimeArchive("usr/lib/swift/clang/lib/darwin/libclang_rt.osx.a")
        _ = try runtimeArchive("usr/lib/swift/clang/lib/darwin/libclang_rt.iossim.a")
        let fallbackEngine = RecordingCompiler()
        _ = try MobileProjectBuilder.build(project: project, toolchain: toolchain, engine: fallbackEngine,
            outputDirectory: root.appendingPathComponent("Fallback"))
        try require(fallbackEngine.linkArguments.contains(newerRuntime.path), "discover newest versioned iOS runtime")
        try require(!fallbackEngine.linkArguments.contains(olderRuntime.path), "ignore older fallback runtime")
        try require(!fallbackEngine.linkArguments.contains { $0.hasSuffix("libclang_rt.osx.a") || $0.hasSuffix("libclang_rt.iossim.a") }, "reject host and simulator runtimes")

        try fm.removeItem(at: olderRuntime)
        try fm.removeItem(at: newerRuntime)
        let missingEngine = RecordingCompiler()
        do {
            _ = try MobileProjectBuilder.build(project: project, toolchain: toolchain, engine: missingEngine,
                outputDirectory: root.appendingPathComponent("MissingRuntime"))
            throw NSError(domain: "Missing device runtime was accepted", code: 1)
        } catch MobileProjectBuildError.invalid(let message) {
            try require(message.contains("libclang_rt.ios.a"), "actionable missing runtime error")
        }
        try require(missingEngine.modules.isEmpty && missingEngine.linkArguments.isEmpty, "preflight runtime before expensive compilation")
        _ = try runtimeArchive("usr/lib/swift/clang/lib/darwin/libclang_rt.ios.a")

        engine.failModule = "Greeting"
        let failureRoot = root.appendingPathComponent("Failure")
        do {
            _ = try MobileProjectBuilder.build(project: project, toolchain: toolchain, engine: engine, outputDirectory: failureRoot)
            throw MobileProjectBuildError.invalid("TEST FAILED: build succeeded after compiler error")
        } catch MobileProjectBuildError.failed { }
        let failedFiles = fm.enumerator(at: failureRoot, includingPropertiesForKeys: nil)!.allObjects as! [URL]
        try require(!failedFiles.contains { $0.pathExtension == "ipa" }, "failure must not export an IPA")
        try require(failedFiles.contains { $0.lastPathComponent == "build.log" }, "failure log preserved")
        let recoveredFailure = try MobileBuildLogRecovery.latest(in: failureRoot)
        try require(recoveredFailure?.wasInterrupted == false && recoveredFailure?.summary.contains("failed") == true,
            "handled compiler failure does not trigger interrupted-build popup")

        var manifest = try MobileAppManifest.load(from: project.root)
        manifest.targets[0].dependencies = ["HelloApp"]
        do {
            _ = try manifest.orderedTargets()
            throw NSError(domain: "Cycle was not rejected", code: 1)
        } catch MobileProjectBuildError.invalid { }

        let executable = linkedExecutable
        for badPath in ["../escape", "/absolute", "Info.plist", "HelloApp"] {
            do {
                try MobileIPAPackager.packageUnsignedIPA(executableURL: executable,
                    configuration: MobileIPAConfiguration(productName: "Test", executableName: "HelloApp", bundleIdentifier: "com.example.test", displayName: "Test"),
                    additionalFiles: [MobileIPAFile(sourceURL: executable, relativePath: badPath)],
                    outputURL: root.appendingPathComponent("bad.ipa"))
                throw NSError(domain: "Invalid IPA path was accepted", code: 1)
            } catch MobileIPAPackager.PackagerError.invalidArchivePath { }
        }
        print("PASS: dependency order, multi-file jobs, iOS runtime linkage/discovery/preflight, IPA output, failure handling, cycles and archive paths")
    }
}


private func workspaceChecks(in root: URL) throws {
    let fm = FileManager.default
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    func rejects(_ message: String, _ action: () throws -> Void) throws {
        do { try action() } catch { return }
        throw NSError(domain: "TEST FAILED: " + message, code: 1)
    }
    let file = try MobileWorkspaceTools.create("Sources/a.swift", directory: false, in: root)
    try "before".write(to: file, atomically: true, encoding: .utf8)
    for path in ["../escape", "/escape", "Sources/../../escape", ".xtool/chat.json", "a//b"] {
        try rejects("unsafe path accepted") { _ = try MobileWorkspaceTools.destination(path, in: root) }
    }
    try fm.createSymbolicLink(at: root.appendingPathComponent("outside"), withDestinationURL: root.deletingLastPathComponent())
    try rejects("symlink escape accepted") { _ = try MobileWorkspaceTools.create("outside/escape.swift", directory: false, in: root) }
    try require(!fm.fileExists(atPath: root.deletingLastPathComponent().appendingPathComponent("escape.swift").path), "rejected link must not create outside file")
    try fm.createSymbolicLink(atPath: root.appendingPathComponent("dangling").path, withDestinationPath: "../missing-directory")
    try rejects("dangling parent accepted") { _ = try MobileWorkspaceTools.create("dangling/new.swift", directory: false, in: root) }
    try fm.createSymbolicLink(atPath: root.appendingPathComponent("alias.swift").path, withDestinationPath: "Sources/a.swift")
    try rejects("symlink leaf accepted") { _ = try MobileWorkspaceTools.destination("alias.swift", in: root) }
    let nested = try MobileWorkspaceTools.create("New/Nested/file.swift", directory: false, in: root)
    try require(fm.fileExists(atPath: nested.path), "ordinary nonexistent parents remain supported")
    try rejects("stale batch changed files") {
        _ = try MobileWorkspaceTools.apply([.init(path: "new.swift", content: "new"), .init(path: "Sources/a.swift", content: "after")], expected: ["Sources/a.swift": "stale"], in: root)
    }
    try require(!fm.fileExists(atPath: root.appendingPathComponent("new.swift").path), "batch preflight is atomic")
    try rejects("unseen existing file accepted") {
        _ = try MobileWorkspaceTools.apply([.init(path: "Sources/a.swift", content: nil)], expected: [:], in: root)
    }
    let batch = try MobileWorkspaceTools.apply([.init(path: "Sources/a.swift", content: "after"), .init(path: "new.swift", content: "new")], expected: ["Sources/a.swift": "before"], in: root)
    try "user edit".write(to: file, atomically: true, encoding: .utf8)
    try rejects("undo overwrote a subsequent user edit") { try MobileWorkspaceTools.undo(batch, in: root) }
    try "after".write(to: file, atomically: true, encoding: .utf8)
    try MobileWorkspaceTools.undo(batch, in: root)
    let restored = try String(contentsOf: file, encoding: .utf8)
    try require(restored == "before" && !fm.fileExists(atPath: root.appendingPathComponent("new.swift").path), "undo restores updates and removes creations")
    let deletion = try MobileWorkspaceTools.apply([.init(path: "Sources/a.swift", content: nil)], expected: ["Sources/a.swift": "before"], in: root)
    try MobileWorkspaceTools.undo(deletion, in: root)
    let renamed = try MobileWorkspaceTools.rename("Sources/a.swift", to: "Sources/b.swift", in: root)
    let trash = try MobileWorkspaceTools.trash("Sources/b.swift", in: root)
    try require(!fm.fileExists(atPath: renamed.path) && fm.fileExists(atPath: trash.path), "trash preserves original")
    let diagnostics = MobileSourceDiagnostic.parse("/some path/File.swift:12:3: error: missing value\nnoise\nFile.swift:2:1: warning: unused")
    try require(diagnostics.count == 2 && diagnostics[0].line == 12 && diagnostics[0].path == "/some path/File.swift", "parse diagnostics with spaces")
    let cache = try MobileModuleCache.directory(in: root, identity: "compiler-a/sdk-a")
    try require(fm.fileExists(atPath: cache.path), "cache directory exists on return")
    try Data().write(to: cache.appendingPathComponent("sentinel"))
    let reused = try MobileModuleCache.directory(in: root, identity: "compiler-a/sdk-a")
    let changed = try MobileModuleCache.directory(in: root, identity: "compiler-b/sdk-a")
    try require(cache == reused, "same identity must return the same directory URL: \(cache.absoluteString) vs \(reused.absoluteString)")
    try require(cache.path != changed.path, "compiler change must select a different cache path")
    try require(fm.fileExists(atPath: reused.appendingPathComponent("sentinel").path), "cache reuse must preserve compiled modules")
    let stamp = cache.deletingLastPathComponent().appendingPathComponent("identity.txt")
    try "invalid identity".write(to: stamp, atomically: true, encoding: .utf8)
    let repaired = try MobileModuleCache.directory(in: root, identity: "compiler-a/sdk-a")
    try require(repaired == cache && !fm.fileExists(atPath: repaired.appendingPathComponent("sentinel").path), "identity mismatch must discard stale modules")
    try MobileModuleCache.clear(in: root)
    try require(!fm.fileExists(atPath: cache.path), "cache clearing")
    print("PASS: workspace paths, stale-edit preflight, edit undo, trash, diagnostics and cache identity")
}
