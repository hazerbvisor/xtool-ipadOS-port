import Foundation
import SwiftUI
import XToolMobileCore

struct IDEWindowsToolsView: View {
    @State private var source = """
    int main(void) {
        return 42;
    }
    """
    @State private var backendStatus = "Checking TinyCC backend…"
    @State private var buildStatus = "Build a tiny x86_64 PE64 executable for WinPad testing."
    @State private var builtExecutable: URL?
    @State private var isBuilding = false

    var body: some View {
        Form {
            Section("TinyCC Windows Backend") {
                Label("Fast PE64 compiler", systemImage: "cpu")
                    .font(.headline)
                Text(backendStatus)
                    .font(.caption)
                    .textSelection(.enabled)
                Button("Refresh backend status") {
                    refreshBackendStatus()
                }
                .disabled(isBuilding)
            }

            Section("HelloWin.c") {
                Text("This bootstrap uses no Windows CRT or SDK. `main` is the PE entry point, which keeps the generated EXE self-contained for WinPad loader tests.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextEditor(text: $source)
                    .font(.system(size: 13, design: .monospaced))
                    .frame(minHeight: 180)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            Section("PE64 Output") {
                Button {
                    buildHelloWin()
                } label: {
                    Label("Build HelloWin.exe", systemImage: "hammer.fill")
                }
                .disabled(isBuilding || source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if isBuilding {
                    ProgressView("Compiling x86_64 PE64…")
                }

                Text(buildStatus)
                    .font(.caption)
                    .textSelection(.enabled)

                if let builtExecutable {
                    ShareLink(item: builtExecutable) {
                        Label("Export HelloWin.exe…", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .onAppear {
            refreshBackendStatus()
        }
    }

    private func refreshBackendStatus() {
        do {
            let compiler = try MobileTinyCCWindowsCompiler.loadFromApplicationBundle()
            backendStatus = "Ready · \(compiler.version) · \(compiler.target) · \(compiler.location.lastPathComponent)"
        } catch {
            backendStatus = String(describing: error)
        }
    }

    private func buildHelloWin() {
        isBuilding = true
        builtExecutable = nil
        buildStatus = "Compiling…"

        defer { isBuilding = false }

        do {
            let compiler = try MobileTinyCCWindowsCompiler.loadFromApplicationBundle()
            let documents = FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
            )[0]
            let output = documents
                .appendingPathComponent("WindowsBuilds", isDirectory: true)
                .appendingPathComponent("HelloWin.exe")

            try compiler.compile(source: source, outputURL: output)

            let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
            let byteCount = (attributes[.size] as? NSNumber)?.intValue ?? 0
            let header = try Data(contentsOf: output, options: .mappedIfSafe).prefix(2)
            guard header.elementsEqual([0x4D, 0x5A]) else {
                throw IDEWindowsBuildError.invalidPEHeader
            }

            builtExecutable = output
            buildStatus = "Success · HelloWin.exe · \(byteCount) bytes · MZ/PE64 ready for WinPad"
            backendStatus = "Ready · \(compiler.version) · \(compiler.target)"
        } catch {
            buildStatus = "Build failed: \(error)"
        }
    }
}

private enum IDEWindowsBuildError: Error, CustomStringConvertible {
    case invalidPEHeader

    var description: String {
        switch self {
        case .invalidPEHeader:
            return "TinyCC output does not start with an MZ executable header."
        }
    }
}
