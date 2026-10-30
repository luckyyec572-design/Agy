import SwiftUI
import QuickLook

struct PreviewDocument: Identifiable { let id = UUID(); let url: URL }
struct NativeDownloadedFile: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var exporting = false
    var body: some View {
        NavigationStack {
            Group {
                if QLPreviewController.canPreview(url as NSURL) { NativeQuickLook(url: url) }
                else { ContentUnavailableView("文件已下载", systemImage: "doc", description: Text("此类型暂不支持预览，可以存储到文件或分享给其他 App。")) }
            }
            .navigationTitle(url.lastPathComponent).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { ShareLink(item: url) { Label("分享", systemImage: "square.and.arrow.up") } }
            }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button("存储到文件", systemImage: "folder") { exporting = true }.buttonStyle(.borderedProminent)
                    ShareLink(item: url) { Label("分享", systemImage: "square.and.arrow.up") }.buttonStyle(.bordered)
                }.frame(maxWidth: .infinity).padding().background(.regularMaterial)
            }
            .sheet(isPresented: $exporting) { NativeExportPicker(url: url) }
        }
    }
}
private struct NativeExportPicker: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController { UIDocumentPickerViewController(forExporting: [url], asCopy: true) }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
}
private struct NativeQuickLook: UIViewControllerRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    func makeUIViewController(context: Context) -> QLPreviewController { let controller = QLPreviewController(); controller.dataSource = context.coordinator; return controller }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}
