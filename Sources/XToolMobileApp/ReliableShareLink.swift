import SwiftUI
import UIKit

/// XTool Mobile uses file URLs for its export actions. SwiftUI's `ShareLink`
/// can present an empty share sheet for large/generated files on iPadOS, so use
/// the system document exporter instead. Keeping the same type name makes this
/// a drop-in replacement for the existing `ShareLink(item: URL) { ... }` calls
/// in XToolMobileApp without changing the surrounding IDE UI.
struct ShareLink<LabelContent: View>: View {
    let item: URL
    private let label: () -> LabelContent

    @State private var isPresentingExporter = false
    @State private var exportError: String?

    init(item: URL, @ViewBuilder label: @escaping () -> LabelContent) {
        self.item = item
        self.label = label
    }

    var body: some View {
        Button {
            guard FileManager.default.fileExists(atPath: item.path) else {
                exportError = "The file no longer exists at \(item.lastPathComponent). Build it again and retry."
                return
            }
            isPresentingExporter = true
        } label: {
            label()
        }
        .fullScreenCover(isPresented: $isPresentingExporter) {
            XToolDocumentExportPicker(fileURL: item) {
                isPresentingExporter = false
            }
            .ignoresSafeArea()
        }
        .alert(
            "Export Failed",
            isPresented: Binding(
                get: { exportError != nil },
                set: { visible in
                    if !visible { exportError = nil }
                }
            )
        ) {
            Button("OK", role: .cancel) {
                exportError = nil
            }
        } message: {
            Text(exportError ?? "Unable to export the file.")
        }
    }
}

private struct XToolDocumentExportPicker: UIViewControllerRepresentable {
    let fileURL: URL
    let onFinish: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forExporting: [fileURL],
            asCopy: true
        )
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(
        _ uiViewController: UIDocumentPickerViewController,
        context: Context
    ) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onFinish: () -> Void

        init(onFinish: @escaping () -> Void) {
            self.onFinish = onFinish
        }

        func documentPicker(
            _ controller: UIDocumentPickerViewController,
            didPickDocumentsAt urls: [URL]
        ) {
            onFinish()
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onFinish()
        }
    }
}
