import SwiftUI
import UniformTypeIdentifiers

/// A thin UIViewControllerRepresentable shell over UIDocumentPickerViewController (folder mode).
/// Cannot be unit/UI-tested (system UI) — the enumeration + manager logic is tested separately.
/// On pick: starts security-scoped access, captures a security-scoped bookmark, fires `onPick(url, bookmark)`.
struct FolderPicker: UIViewControllerRepresentable {
    var onPick: (URL, Data) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL, Data) -> Void
        init(onPick: @escaping (URL, Data) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            guard url.startAccessingSecurityScopedResource() else { return }
            defer { url.stopAccessingSecurityScopedResource() }
            guard let bookmark = try? url.bookmarkData(
                options: .minimalBookmark,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) else { return }
            onPick(url, bookmark)
        }
    }
}
