import Foundation

/// Builds one Foundation-style iOS app extension with the same in-process
/// Swift/Clang/LLD toolchain used by the host app.
///
/// The result is deliberately unsigned. `MobileProjectBuilder` embeds the files
/// under `PlugIns/<name>.appex`, after which the normal signing/install path must
/// sign both the nested extension and the host app with compatible profiles.
enum MobileAppExtensionBuilder {
    static func build(
        appExtension: MobileAppManifest.AppExtension,
        manifest: MobileAppManifest,
        project: MobileProject,
        sdk: MobileSwiftSDKConfiguration,
        engine: any MobileProjectCompiler,
        compilerRuntime: URL,
        work: URL,
        cache: URL,
        log: @escaping @Sendable (String) -> Void,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> [MobileIPAFile] {
        let fm = FileManager.default
        let targets = try manifest.orderedTargets(for: appExtension.executableTarget)
        let extensionRoot = work.appendingPathComponent("AppExtensions/\(appExtension.name)", isDirectory: true)
        let targetRoot = extensionRoot.appendingPathComponent("Targets", isDirectory: true)
        let modules = extensionRoot.appendingPathComponent("Modules", isDirectory: true)
        let products = extensionRoot.appendingPathComponent("Products", isDirectory: true)
        let bundleStaging = extensionRoot.appendingPathComponent("Bundle", isDirectory: true)
        try fm.createDirectory(at: targetRoot, withIntermediateDirectories: true)
        try fm.createDirectory(at: modules, withIntermediateDirectories: true)
        try fm.createDirectory(at: products, withIntermediateDirectories: true)
        try fm.createDirectory(at: bundleStaging, withIntermediateDirectories: true)

        func checkCancellation() throws {
            if isCancelled() { throw CancellationError() }
        }
        func checked(_ result: MobileBuildResult, job: String, output: URL) throws {
            if !result.standardOutput.isEmpty { log(String(decoding: result.standardOutput, as: UTF8.self)) }
            if !result.standardError.isEmpty { log(String(decoding: result.standardError, as: UTF8.self)) }
            guard result.succeeded else { throw MobileProjectBuildError.failed(job, result.exitCode) }
            let size = (try? fm.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.intValue ?? 0
            guard size > 0 else {
                throw MobileProjectBuildError.invalid("\(job) produced no output: \(output.lastPathComponent)")
            }
        }
        func input(_ path: String) throws -> URL {
            try MobileProjectPaths.input(path, root: project.root)
        }
        func expand(_ value: String) -> String {
            value.replacingOccurrences(of: "${PROJECT}", with: project.root.path)
                .replacingOccurrences(of: "${BUILD}", with: work.path)
                .replacingOccurrences(of: "${SDK}", with: sdk.sdkURL.path)
                .replacingOccurrences(of: "${SWIFT_RESOURCES}", with: sdk.swiftResourceDirectory.path)
        }

        log("Building app extension \(appExtension.name)")
        let targetTriple = "arm64-apple-ios\(manifest.deploymentTarget)"
        var objects: [URL] = []
        var moduleMaps: [URL] = []
        for target in targets {
            if let map = target.moduleMap { moduleMaps.append(try input(map)) }
        }

        for target in targets {
            try checkCancellation()
            log("Compiling extension target \(target.name)")
            let targetWork = targetRoot.appendingPathComponent(target.name, isDirectory: true)
            try fm.createDirectory(at: targetWork, withIntermediateDirectories: true)
            var seen: Set<URL> = []
            let sources = try target.sources
                .flatMap { try MobileProjectPaths.files($0, root: project.root) }
                .filter { seen.insert($0).inserted }
            let swiftSources = sources.filter { $0.pathExtension == "swift" }
            let nativeSources = sources.filter {
                ["c", "m", "mm", "cpp", "cc", "cxx"].contains($0.pathExtension)
            }
            guard !swiftSources.isEmpty || !nativeSources.isEmpty || target.moduleMap != nil else {
                throw MobileProjectBuildError.invalid("Target \(target.name) has no compilable sources")
            }

            let headers = try (target.headerSearchPaths ?? []).map(input)
            for (index, source) in nativeSources.enumerated() {
                try checkCancellation()
                guard engine.supportsClangFrontend else {
                    throw MobileProjectBuildError.invalid("Clang frontend is unavailable")
                }
                let object = targetWork.appendingPathComponent("native-\(index).o")
                let ext = source.pathExtension
                let language = [
                    "m": "objective-c",
                    "mm": "objective-c++",
                    "cpp": "c++",
                    "cc": "c++",
                    "cxx": "c++",
                ][ext] ?? "c"
                var args = [
                    "-triple", targetTriple,
                    "-emit-obj",
                    "-x", language,
                    "-isysroot", sdk.sdkURL.path,
                    "-mrelocation-model", "pic",
                    "-pic-level", "2",
                    "-fblocks",
                    "-O0",
                ]
                if let clang = sdk.clangBuiltinHeaders {
                    args += [
                        "-resource-dir", clang.deletingLastPathComponent().path,
                        "-internal-isystem", clang.path,
                    ]
                }
                args += [
                    "-internal-isystem", sdk.sdkURL.appendingPathComponent("usr/include").path,
                    "-iframework", sdk.sdkURL.appendingPathComponent("System/Library/Frameworks").path,
                ]
                if language.contains("++") {
                    args += [
                        "-std=c++17", "-fcxx-exceptions", "-fexceptions",
                        "-internal-isystem", sdk.sdkURL.appendingPathComponent("usr/include/c++/v1").path,
                    ]
                }
                if language.hasPrefix("objective-c") {
                    args += ["-fobjc-runtime=ios-\(manifest.deploymentTarget)", "-fobjc-arc"]
                }
                for header in headers { args += ["-I", header.path] }
                args += (target.cFlags ?? []).map(expand)
                args += [source.path, "-o", object.path]
                try checked(
                    engine.runClangFrontend(
                        arguments: args,
                        diagnosticsURL: targetWork.appendingPathComponent("native-\(index).stderr")
                    ),
                    job: "\(appExtension.name):\(target.name)",
                    output: object
                )
                objects.append(object)
            }

            if !swiftSources.isEmpty {
                let object = targetWork.appendingPathComponent("\(target.name).o")
                let module = modules.appendingPathComponent("\(target.name).swiftmodule")
                var args = ["-c"] + swiftSources.map(\.path)
                args += [
                    "-target", targetTriple,
                    "-enable-objc-interop",
                    "-enable-cross-import-overlays",
                    "-Xllvm", "-aarch64-use-tbi",
                    "-sdk", sdk.sdkURL.path,
                    "-resource-dir", sdk.swiftResourceDirectory.path,
                    "-module-cache-path", cache.path,
                    "-module-load-mode", "prefer-serialized",
                    "-disable-modules-validate-system-headers",
                    "-Rmodule-interface-rebuild",
                    "-I", sdk.iPhoneOSSwiftResourceDirectory.path,
                    "-I", modules.path,
                    "-Onone",
                    "-no-color-diagnostics",
                ]
                if let prebuilt = sdk.xtoolPrebuiltModuleCacheDirectory {
                    args += ["-prebuilt-module-cache-path", prebuilt.path]
                }
                if let version = sdk.targetSDKVersion { args += ["-target-sdk-version", version] }
                if let name = sdk.targetSDKName { args += ["-target-sdk-name", name] }
                for path in sdk.includeSearchPaths { args += ["-I", path.path] }
                for path in manifest.moduleSearchPaths ?? [] { args += ["-I", try input(path).path] }
                for path in appExtension.moduleSearchPaths ?? [] { args += ["-I", try input(path).path] }
                for header in headers { args += ["-Xcc", "-I", "-Xcc", header.path] }
                for map in moduleMaps { args += ["-Xcc", "-fmodule-map-file=\(map.path)"] }
                args += [
                    "-Xcc", "-isysroot",
                    "-Xcc", sdk.sdkURL.path,
                    "-Xcc", "-fmodules-cache-path=\(cache.path)",
                ]
                // App-extension products use Foundation's entry point rather than
                // a Swift @main declaration, so their Swift sources are libraries.
                if target.parseAsLibrary ?? true { args += ["-parse-as-library"] }
                args += (target.swiftFlags ?? []).map(expand)
                args += [
                    "-module-name", target.name,
                    "-emit-module-path", module.path,
                    "-o", object.path,
                ]
                try checked(
                    engine.runSwiftFrontend(
                        arguments: args,
                        diagnosticsURL: targetWork.appendingPathComponent("swift.stderr")
                    ),
                    job: "\(appExtension.name):\(target.name)",
                    output: object
                )
                guard fm.fileExists(atPath: module.path) else {
                    throw MobileProjectBuildError.invalid("Missing Swift module: \(target.name)")
                }
                objects.append(object)
            }
        }

        try checkCancellation()
        let executable = products.appendingPathComponent(appExtension.name)
        var link = [
            "-arch", "arm64",
            "-platform_version", "ios", manifest.deploymentTarget,
            sdk.targetSDKVersion ?? manifest.deploymentTarget,
            "-syslibroot", sdk.sdkURL.path,
            "-e", "_NSExtensionMain",
            "-no_adhoc_codesign",
            "-rpath", "@executable_path/../../Frameworks",
            "-rpath", "@executable_path/Frameworks",
            "-rpath", "/usr/lib/swift",
        ]
        link += (appExtension.linkerFlags ?? []).map(expand)

        let libraryPaths = [
            sdk.sdkURL.appendingPathComponent("usr/lib"),
            sdk.sdkURL.appendingPathComponent("usr/lib/system"),
            sdk.sdkURL.appendingPathComponent("usr/lib/swift"),
            sdk.iPhoneOSSwiftResourceDirectory,
        ] + sdk.librarySearchPaths
        var seenLibraries: Set<String> = []
        for path in libraryPaths {
            var directory: ObjCBool = false
            if fm.fileExists(atPath: path.path, isDirectory: &directory),
               directory.boolValue,
               seenLibraries.insert(path.path).inserted {
                link += ["-L", path.path]
            }
        }
        link += ["-F", sdk.sdkURL.appendingPathComponent("System/Library/Frameworks").path]
        for path in appExtension.librarySearchPaths ?? [] { link += ["-L", try input(path).path] }
        link += objects.map(\.path)
        for path in appExtension.linkFiles ?? [] { link.append(try input(path).path) }
        link.append(compilerRuntime.path)
        link += ["-lSystem", "-lobjc", "-lc++"]

        var frameworks = ["Foundation"]
        for framework in appExtension.frameworks ?? [] where !frameworks.contains(framework) {
            frameworks.append(framework)
        }
        for framework in frameworks { link += ["-framework", framework] }
        for library in appExtension.libraries ?? [] { link += ["-l" + library] }
        link += ["-o", executable.path]

        log("Linking app extension \(appExtension.name)")
        log("Extension linker arguments:\n" + link.map { "  " + $0 }.joined(separator: "\n"))
        try checked(
            engine.runMachOLLD(
                arguments: link,
                diagnosticsURL: extensionRoot.appendingPathComponent("link.stderr")
            ),
            job: "Link extension \(appExtension.name)",
            output: executable
        )
        try validateExecutable(executable, fileManager: fm)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let infoURL = try makeInfoPlist(
            appExtension: appExtension,
            manifest: manifest,
            project: project,
            outputDirectory: bundleStaging
        )

        let prefix = "PlugIns/\(appExtension.name).appex"
        var files = [
            MobileIPAFile(
                sourceURL: executable,
                relativePath: "\(prefix)/\(appExtension.name)",
                isExecutable: true
            ),
            MobileIPAFile(sourceURL: infoURL, relativePath: "\(prefix)/Info.plist"),
        ]

        for resource in appExtension.resources ?? [] {
            let origin = try input(resource.path)
            let directory = (try origin.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true
            for file in try MobileProjectPaths.files(resource.path, root: project.root) {
                if ["xcassets", "storyboard", "xib"].contains(file.pathExtension)
                    || file.path.contains(".xcassets/") {
                    throw MobileProjectBuildError.invalid(
                        "Compile extension asset catalogs/storyboards on the host before importing: \(file.lastPathComponent)"
                    )
                }
                let suffix = directory ? String(file.path.dropFirst(origin.path.count + 1)) : ""
                let destination = suffix.isEmpty
                    ? resource.destination
                    : resource.destination + "/" + suffix
                files.append(
                    MobileIPAFile(
                        sourceURL: file,
                        relativePath: "\(prefix)/\(destination)",
                        isExecutable: file.pathExtension == "dylib" || fm.isExecutableFile(atPath: file.path)
                    )
                )
            }
        }
        return files
    }

    private static func makeInfoPlist(
        appExtension: MobileAppManifest.AppExtension,
        manifest: MobileAppManifest,
        project: MobileProject,
        outputDirectory: URL
    ) throws -> URL {
        let source = try MobileProjectPaths.input(appExtension.infoPlist, root: project.root)
        guard var plist = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: source),
            format: nil
        ) as? [String: Any] else {
            throw MobileProjectBuildError.invalid(
                "Extension Info.plist must contain a dictionary: \(appExtension.infoPlist)"
            )
        }
        guard plist["NSExtension"] is [String: Any] else {
            throw MobileProjectBuildError.invalid(
                "Extension \(appExtension.name) Info.plist is missing NSExtension"
            )
        }

        plist["CFBundleDevelopmentRegion"] = plist["CFBundleDevelopmentRegion"] ?? "en"
        plist["CFBundleDisplayName"] = plist["CFBundleDisplayName"] ?? appExtension.name
        plist["CFBundleExecutable"] = appExtension.name
        plist["CFBundleIdentifier"] = appExtension.bundleIdentifier
        plist["CFBundleInfoDictionaryVersion"] = "6.0"
        plist["CFBundleName"] = plist["CFBundleName"] ?? appExtension.name
        plist["CFBundlePackageType"] = "XPC!"
        plist["CFBundleShortVersionString"] = plist["CFBundleShortVersionString"]
            ?? (manifest.shortVersion ?? "1.0")
        plist["CFBundleVersion"] = plist["CFBundleVersion"] ?? (manifest.buildVersion ?? "1")
        plist["MinimumOSVersion"] = manifest.deploymentTarget
        plist["CFBundleSupportedPlatforms"] = ["iPhoneOS"]
        plist["UIDeviceFamily"] = plist["UIDeviceFamily"] ?? [1, 2]

        let encoded = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        let output = outputDirectory.appendingPathComponent("Info.plist")
        try encoded.write(to: output, options: .atomic)
        return output
    }

    private static func validateExecutable(_ executable: URL, fileManager: FileManager) throws {
        let binary = try FileHandle(forReadingFrom: executable)
        let header = try binary.read(upToCount: 16) ?? Data()
        try binary.close()
        guard header.count == 16,
              Array(header.prefix(8)) == [0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0x00, 0x00, 0x01],
              Array(header.suffix(4)) == [2, 0, 0, 0] else {
            throw MobileProjectBuildError.invalid(
                "Extension linker output is not an arm64 Mach-O executable: \(executable.lastPathComponent)"
            )
        }
    }
}
