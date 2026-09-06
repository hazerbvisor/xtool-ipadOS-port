import Foundation

public struct MobileProjectBuildOutput: Sendable {
    public let ipaURL: URL
    public let logURL: URL
}

public protocol MobileProjectCompiler: Sendable {
    var supportsClangFrontend: Bool { get }
    var supportsMachOLLD: Bool { get }
    var location: URL { get }
    func runSwiftFrontend(arguments: [String], diagnosticsURL: URL?) throws -> MobileBuildResult
    func runClangFrontend(arguments: [String], diagnosticsURL: URL?) throws -> MobileBuildResult
    func runMachOLLD(arguments: [String], diagnosticsURL: URL?) throws -> MobileBuildResult
}

public extension MobileProjectCompiler {
    func runSwiftFrontend(arguments: [String]) throws -> MobileBuildResult {
        try runSwiftFrontend(arguments: arguments, diagnosticsURL: nil)
    }
    func runClangFrontend(arguments: [String]) throws -> MobileBuildResult {
        try runClangFrontend(arguments: arguments, diagnosticsURL: nil)
    }
    func runMachOLLD(arguments: [String]) throws -> MobileBuildResult {
        try runMachOLLD(arguments: arguments, diagnosticsURL: nil)
    }
}

/// Runs one native job at a time, then packages the linked executable without signing.
public enum MobileProjectBuilder {
    public static func build(
        project: MobileProject,
        toolchain: PreparedToolchain,
        engine: any MobileProjectCompiler,
        outputDirectory: URL,
        log: @escaping @Sendable (String) -> Void = { _ in },
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) throws -> MobileProjectBuildOutput {
        let fm = FileManager.default
        let manifest = try MobileAppManifest.load(from: project.root)
        let targets = try manifest.orderedTargets()
        let sdk = try toolchain.mobileSwiftSDKConfiguration()
        guard engine.supportsMachOLLD else { throw MobileProjectBuildError.invalid("Mach-O linker is unavailable") }
        // Each attempt owns its outputs. A failed job cannot reuse yesterday's object or IPA.
        let work = outputDirectory.appendingPathComponent("\(manifest.name)-\(UUID().uuidString)", isDirectory: true)
        let modules = work.appendingPathComponent("Modules", isDirectory: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let manifestIdentity = String(decoding: try encoder.encode(manifest), as: UTF8.self)
        let engineAttributes = try? fm.attributesOfItem(atPath: engine.location.path)
        let sdkAttributes = try? fm.attributesOfItem(atPath: sdk.sdkURL.path)
        let cacheIdentity = ["module-cache-v1", project.root.path, toolchain.root.path,
            sdk.sdkURL.path, PreparedToolchain.expectedBundledRuntimeRevision,
            engine.location.path, String(describing: engineAttributes?[.modificationDate]),
            String(describing: engineAttributes?[.size]), String(describing: sdkAttributes?[.modificationDate]), manifestIdentity].joined(separator: "\n")
        let cache = try MobileModuleCache.directory(in: outputDirectory, identity: cacheIdentity)
        // Product and target names commonly match. Keep their filesystem
        // namespaces separate so LLD never receives a target directory as -o.
        let targetRoot = work.appendingPathComponent("Targets", isDirectory: true)
        let products = work.appendingPathComponent("Products", isDirectory: true)
        try fm.createDirectory(at: modules, withIntermediateDirectories: true)
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        try fm.createDirectory(at: products, withIntermediateDirectories: true)
        let logURL = work.appendingPathComponent("build.log")
        fm.createFile(atPath: logURL.path, contents: nil)
        let logFile = try FileHandle(forWritingTo: logURL)
        defer { try? logFile.close() }
        func report(_ line: String) {
            try? logFile.write(contentsOf: Data((line + "\n").utf8))
            try? logFile.synchronize()
            log(line)
        }
        var currentStage = "Preparing build"
        func stage(_ name: String) throws {
            currentStage = name
            try MobileBuildLogRecovery.checkpoint(in: work, stage: name)
            report(name)
        }
        func checkCancellation() throws {
            if isCancelled() { throw CancellationError() }
        }
        func checked(_ result: MobileBuildResult, job: String, output: URL) throws {
            if !result.standardOutput.isEmpty { report(String(decoding: result.standardOutput, as: UTF8.self)) }
            if !result.standardError.isEmpty { report(String(decoding: result.standardError, as: UTF8.self)) }
            guard result.succeeded else { throw MobileProjectBuildError.failed(job, result.exitCode) }
            let size = (try? fm.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.intValue ?? 0
            guard size > 0 else { throw MobileProjectBuildError.invalid("\(job) produced no output: \(output.lastPathComponent)") }
        }
        func expand(_ value: String) -> String {
            value.replacingOccurrences(of: "${PROJECT}", with: project.root.path)
                .replacingOccurrences(of: "${BUILD}", with: work.path)
                .replacingOccurrences(of: "${SDK}", with: sdk.sdkURL.path)
                .replacingOccurrences(of: "${SWIFT_RESOURCES}", with: sdk.swiftResourceDirectory.path)
        }
        func input(_ path: String) throws -> URL { try MobileProjectPaths.input(path, root: project.root) }

        report("Building \(manifest.name) for arm64 iOS \(manifest.deploymentTarget)")
        report("Build log: \(logURL.path)")
        report("Reusable module cache: \(cache.path)")
        report("Build progress: 0/\(targets.count + 2)")
        do {
            try stage("Preparing build")
            // Direct LLD invocation bypasses the Clang driver's automatic
            // compiler-rt linkage, including __isPlatformVersionAtLeast.
            // Resolve it before compiling so an incomplete runtime fails early.
            let compilerRuntime = try iOSCompilerRuntime(toolchain: toolchain, sdk: sdk, fileManager: fm)
            report("iOS compiler runtime: \(compilerRuntime.path)")
            var objects: [URL] = []
            var moduleMaps: [URL] = []
            for target in targets {
                if let map = target.moduleMap { moduleMaps.append(try input(map)) }
            }
            let targetTriple = "arm64-apple-ios\(manifest.deploymentTarget)"
            for (targetIndex, target) in targets.enumerated() {
                try checkCancellation()
                try stage("Compiling \(target.name)")
                let targetWork = targetRoot.appendingPathComponent(target.name, isDirectory: true)
                try fm.createDirectory(at: targetWork, withIntermediateDirectories: true)
                var seen: Set<URL> = []
                let sources = try target.sources.flatMap { try MobileProjectPaths.files($0, root: project.root) }
                    .filter { seen.insert($0).inserted }
                let swiftSources = sources.filter { $0.pathExtension == "swift" }
                let nativeSources = sources.filter { ["c", "m", "mm", "cpp", "cc", "cxx"].contains($0.pathExtension) }
                guard !swiftSources.isEmpty || !nativeSources.isEmpty || target.moduleMap != nil else {
                    throw MobileProjectBuildError.invalid("Target \(target.name) has no compilable sources")
                }
                let headers = try (target.headerSearchPaths ?? []).map(input)
                for (index, source) in nativeSources.enumerated() {
                    try checkCancellation()
                    guard engine.supportsClangFrontend else { throw MobileProjectBuildError.invalid("Clang frontend is unavailable") }
                    let object = targetWork.appendingPathComponent("native-\(index).o")
                    let ext = source.pathExtension
                    let language = ["m": "objective-c", "mm": "objective-c++", "cpp": "c++", "cc": "c++", "cxx": "c++"][ext] ?? "c"
                    var args = ["-triple", targetTriple, "-emit-obj", "-x", language,
                                "-isysroot", sdk.sdkURL.path, "-mrelocation-model", "pic", "-pic-level", "2", "-fblocks", "-O0"]
                    if let clang = sdk.clangBuiltinHeaders {
                        args += ["-resource-dir", clang.deletingLastPathComponent().path, "-internal-isystem", clang.path]
                    }
                    args += ["-internal-isystem", sdk.sdkURL.appendingPathComponent("usr/include").path,
                             "-iframework", sdk.sdkURL.appendingPathComponent("System/Library/Frameworks").path]
                    if language.contains("++") {
                        args += ["-std=c++17", "-fcxx-exceptions", "-fexceptions", "-internal-isystem", sdk.sdkURL.appendingPathComponent("usr/include/c++/v1").path]
                    }
                    if language.hasPrefix("objective-c") { args += ["-fobjc-runtime=ios-\(manifest.deploymentTarget)", "-fobjc-arc"] }
                    for header in headers { args += ["-I", header.path] }
                    args += (target.cFlags ?? []).map(expand)
                    args += [source.path, "-o", object.path]
                    try stage("Compiling \(target.name): \(source.lastPathComponent)")
                    try checked(engine.runClangFrontend(arguments: args,
                        diagnosticsURL: targetWork.appendingPathComponent("native-\(index).stderr")), job: target.name, output: object)
                    objects.append(object)
                }
                if !swiftSources.isEmpty {
                    let object = targetWork.appendingPathComponent("\(target.name).o")
                    let module = modules.appendingPathComponent("\(target.name).swiftmodule")
                    var args = ["-c"] + swiftSources.map(\.path)
                    args += ["-target", targetTriple, "-enable-objc-interop", "-enable-cross-import-overlays",
                             "-Xllvm", "-aarch64-use-tbi", "-sdk", sdk.sdkURL.path,
                             "-resource-dir", sdk.swiftResourceDirectory.path,
                             "-module-cache-path", cache.path, "-module-load-mode", "prefer-serialized",
                             "-disable-modules-validate-system-headers", "-Rmodule-interface-rebuild",
                             "-I", sdk.iPhoneOSSwiftResourceDirectory.path, "-I", modules.path,
                             "-Onone", "-no-color-diagnostics"]
                    if let prebuilt = sdk.xtoolPrebuiltModuleCacheDirectory { args += ["-prebuilt-module-cache-path", prebuilt.path] }
                    if let version = sdk.targetSDKVersion { args += ["-target-sdk-version", version] }
                    if let name = sdk.targetSDKName { args += ["-target-sdk-name", name] }
                    for path in sdk.includeSearchPaths { args += ["-I", path.path] }
                    for path in manifest.moduleSearchPaths ?? [] { args += ["-I", try input(path).path] }
                    for header in headers { args += ["-Xcc", "-I", "-Xcc", header.path] }
                    for map in moduleMaps { args += ["-Xcc", "-fmodule-map-file=\(map.path)"] }
                    args += ["-Xcc", "-isysroot", "-Xcc", sdk.sdkURL.path,
                             "-Xcc", "-fmodules-cache-path=\(cache.path)"]
                    // Let ClangImporter place libc++ ahead of its builtin wrapper headers.
                    let hasMainFile = swiftSources.contains { $0.lastPathComponent == "main.swift" }
                    if target.parseAsLibrary ?? (target.name != manifest.executableTarget || !hasMainFile) { args += ["-parse-as-library"] }
                    args += (target.swiftFlags ?? []).map(expand)
                    args += ["-module-name", target.name, "-emit-module-path", module.path, "-o", object.path]
                    try stage("Compiling \(target.name) (Swift)")
                    try checked(engine.runSwiftFrontend(arguments: args,
                        diagnosticsURL: targetWork.appendingPathComponent("swift.stderr")), job: target.name, output: object)
                    guard fm.fileExists(atPath: module.path) else { throw MobileProjectBuildError.invalid("Missing Swift module: \(target.name)") }
                    objects.append(object)
                }
                report("Build progress: \(targetIndex + 1)/\(targets.count + 2)")
            }
            try checkCancellation()
            let executable = products.appendingPathComponent(manifest.name)
            guard !fm.fileExists(atPath: executable.path) else {
                throw MobileProjectBuildError.invalid("Link output path is already occupied: \(executable.path)")
            }
            var link = ["-arch", "arm64", "-platform_version", "ios", manifest.deploymentTarget, sdk.targetSDKVersion ?? manifest.deploymentTarget,
                        "-syslibroot", sdk.sdkURL.path, "-e", "_main", "-no_adhoc_codesign",
                        "-rpath", "@executable_path/Frameworks", "-rpath", "/usr/lib/swift"]
            let libraryPaths = [
                sdk.sdkURL.appendingPathComponent("usr/lib"),
                sdk.sdkURL.appendingPathComponent("usr/lib/system"),
                sdk.sdkURL.appendingPathComponent("usr/lib/swift"),
                sdk.iPhoneOSSwiftResourceDirectory,
            ] + sdk.librarySearchPaths
            var seenLibraries: Set<String> = []
            for path in libraryPaths {
                var directory: ObjCBool = false
                if fm.fileExists(atPath: path.path, isDirectory: &directory), directory.boolValue,
                   seenLibraries.insert(path.path).inserted {
                    link += ["-L", path.path]
                }
            }
            link += ["-F", sdk.sdkURL.appendingPathComponent("System/Library/Frameworks").path]
            for path in manifest.librarySearchPaths ?? [] { link += ["-L", try input(path).path] }
            link += objects.map(\.path)
            for path in manifest.linkFiles ?? [] { link.append(try input(path).path) }
            link.append(compilerRuntime.path)
            link += ["-lSystem", "-lobjc", "-lc++"]
            for framework in manifest.frameworks ?? [] { link += ["-framework", framework] }
            for library in manifest.libraries ?? [] { link += ["-l" + library] }
            // Mach-O object LC_LINKER_OPTION records carry Swift/framework autolinks.
            link += ["-o", executable.path]
            try stage("Linking \(manifest.name)")
            report("Linker arguments:\n" + link.map { "  " + $0 }.joined(separator: "\n"))
            try checked(engine.runMachOLLD(arguments: link,
                diagnosticsURL: work.appendingPathComponent("link.stderr")), job: "Link", output: executable)
            report("Build progress: \(targets.count + 1)/\(targets.count + 2)")
            let binary = try FileHandle(forReadingFrom: executable)
            let header = try binary.read(upToCount: 16) ?? Data()
            try binary.close()
            guard header.count == 16, Array(header.prefix(8)) == [0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0x00, 0x00, 0x01],
                  Array(header.suffix(4)) == [2, 0, 0, 0] else {
                throw MobileProjectBuildError.invalid("Linker output is not an arm64 Mach-O executable")
            }
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            try checkCancellation()
            var files: [MobileIPAFile] = []
            for resource in manifest.resources ?? [] {
                let origin = try input(resource.path)
                let directory = (try origin.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true
                for file in try MobileProjectPaths.files(resource.path, root: project.root) {
                    if ["xcassets", "storyboard", "xib"].contains(file.pathExtension) || file.path.contains(".xcassets/") {
                        throw MobileProjectBuildError.invalid("Compile asset catalogs/storyboards on the host before importing: \(file.lastPathComponent)")
                    }
                    let suffix = directory ? String(file.path.dropFirst(origin.path.count + 1)) : ""
                    let destination = suffix.isEmpty ? resource.destination : resource.destination + "/" + suffix
                    files.append(MobileIPAFile(sourceURL: file, relativePath: destination,
                        isExecutable: file.pathExtension == "dylib" || fm.isExecutableFile(atPath: file.path)))
                }
            }
            if manifest.reuseCompilerEngine == true {
                files.append(MobileIPAFile(sourceURL: engine.location, relativePath: "Frameworks/libXToolCompilerEngine.dylib", isExecutable: true))
            }
            if manifest.reuseBundledRuntime == true {
                guard let archive = Bundle.main.url(forResource: "MobileRuntime", withExtension: "tar") else {
                    throw MobileProjectBuildError.invalid("The installed app has no runtime archive to reuse")
                }
                files.append(MobileIPAFile(sourceURL: archive, relativePath: "MobileRuntime.tar"))
            }
            let ipa = work.appendingPathComponent("\(manifest.name)-unsigned.ipa")
            let extraPlist: [String: Any]
            if let path = manifest.infoPlist {
                guard let dict = try PropertyListSerialization.propertyList(from: Data(contentsOf: input(path)), format: nil) as? [String: Any] else {
                    throw MobileProjectBuildError.invalid("Info.plist must contain a dictionary")
                }
                extraPlist = dict
            } else { extraPlist = [:] }
            try stage("Packaging unsigned IPA")
            try MobileIPAPackager.packageUnsignedIPA(executableURL: executable,
                configuration: MobileIPAConfiguration(productName: manifest.name, executableName: manifest.name,
                    bundleIdentifier: manifest.bundleIdentifier, displayName: manifest.name,
                    shortVersion: manifest.shortVersion ?? "1.0", buildVersion: manifest.buildVersion ?? "1",
                    minimumOSVersion: manifest.deploymentTarget), additionalFiles: files,
                additionalInfoPlist: extraPlist, outputURL: ipa)
            report("SUCCESS: \(ipa.lastPathComponent)")
            report("Build progress: \(targets.count + 2)/\(targets.count + 2)")
            try MobileBuildLogRecovery.checkpoint(in: work, stage: currentStage, status: .succeeded)
            return MobileProjectBuildOutput(ipaURL: ipa, logURL: logURL)
        } catch {
            report("BUILD FAILED: \(error)")
            try? MobileBuildLogRecovery.checkpoint(in: work, stage: currentStage,
                status: error is CancellationError ? .cancelled : .failed)
            throw error
        }
    }

    /// Only use the device iOS builtins archive from the imported Darwin tree.
    /// Host Linux, macOS and iOS simulator runtimes are not substitutes.
    private static func iOSCompilerRuntime(
        toolchain: PreparedToolchain,
        sdk: MobileSwiftSDKConfiguration,
        fileManager: FileManager
    ) throws -> URL {
        var resourceDirectories = [
            sdk.swiftResourceDirectory.appendingPathComponent("clang"),
            toolchain.toolchainDirectory.appendingPathComponent("usr/lib/swift/clang"),
        ]
        // Some SDKBuilder exports retain only the versioned Clang resource
        // directory instead of the usual usr/lib/swift/clang symlink.
        let versionRoots = [
            sdk.swiftResourceDirectory.deletingLastPathComponent().appendingPathComponent("clang"),
            toolchain.toolchainDirectory.appendingPathComponent("usr/lib/clang"),
        ]
        for root in versionRoots {
            let versions = (try? fileManager.contentsOfDirectory(at: root,
                includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
            resourceDirectories += versions.sorted {
                $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending
            }
        }
        var searched: [String] = []
        for directory in resourceDirectories {
            let archive = directory.appendingPathComponent("lib/darwin/libclang_rt.ios.a").resolvingSymlinksInPath()
            guard !searched.contains(archive.path) else { continue }
            searched.append(archive.path)
            if let values = try? archive.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
               values.isRegularFile == true, (values.fileSize ?? 0) > 0,
               fileManager.isReadableFile(atPath: archive.path) {
                return archive
            }
        }
        throw MobileProjectBuildError.invalid(
            "Missing iOS compiler runtime libclang_rt.ios.a. Re-prepare/import the Darwin runtime with Clang's device libraries. Searched:\n"
                + searched.joined(separator: "\n"))
    }
}
