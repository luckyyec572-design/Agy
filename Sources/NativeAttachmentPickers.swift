import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// Present actual picker controllers from a stable sheet, never from a Menu item.
struct NativeDocumentPicker: UIViewControllerRepresentable {
    let onComplete: ([URL]) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onComplete: onComplete) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ picker: UIDocumentPickerViewController, context: Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onComplete: ([URL]) -> Void
        init(onComplete: @escaping ([URL]) -> Void) { self.onComplete = onComplete }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { onComplete(urls) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { onComplete([]) }
    }
}

struct NativePhotoPicker: UIViewControllerRepresentable {
    let limit: Int
    let onComplete: ([PHPickerResult]) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onComplete: onComplete) }
    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = max(1, limit)
        config.preferredAssetRepresentationMode = .compatible
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ picker: PHPickerViewController, context: Context) {}
    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onComplete: ([PHPickerResult]) -> Void
        init(onComplete: @escaping ([PHPickerResult]) -> Void) { self.onComplete = onComplete }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) { onComplete(results) }
    }
}

enum NativePhotoImport {
    static func load(_ result: PHPickerResult) async throws -> ImportedAttachment {
        let provider = result.itemProvider
        guard let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) else { throw AttachmentImportError.unsupportedPhoto }
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                if let error { continuation.resume(throwing: error); return }
                guard let url else { continuation.resume(throwing: AttachmentImportError.unsupportedPhoto); return }
                // Provider URLs expire when this callback returns. Finish reading
                // and downsampling here, before resuming the asynchronous caller.
                continuation.resume(with: Result { try NativePhotoEncoding.encode(url, name: provider.suggestedName) })
            }
        }
    }

}
