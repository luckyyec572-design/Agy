import SwiftUI
import ImageIO
import SwiftDraw

private struct NativeMediaRunningKey: EnvironmentKey { static let defaultValue = false }
private struct NativeMediaAPIKey: EnvironmentKey { static let defaultValue: AGYAPI? = nil }
extension EnvironmentValues {
    var nativeMediaRunning: Bool {
        get { self[NativeMediaRunningKey.self] }
        set { self[NativeMediaRunningKey.self] = newValue }
    }
    var nativeMediaAPI: AGYAPI? {
        get { self[NativeMediaAPIKey.self] }
        set { self[NativeMediaAPIKey.self] = newValue }
    }
}

@MainActor struct NativeMediaPreview: View {
    var data: Data? = nil
    var url: URL? = nil
    @Environment(\.nativeMediaAPI) private var api
    @Environment(\.nativeWorkspace) private var cwd
    @Environment(\.nativeSessionID) private var sessionID
    @Environment(\.nativeMediaRunning) private var running
    @Environment(\.openURL) private var openURL
    @State private var image: UIImage?
    @State private var loading = false
    @State private var failed = false
    @State private var fullScreen = false
    private var key: String { url?.absoluteString ?? String(data?.hashValue ?? 0) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let image {
                Button { fullScreen = true } label: {
                    Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 340)
                        .padding(6).background(Color.white, in: RoundedRectangle(cornerRadius: 12))
                }.buttonStyle(.plain).accessibilityLabel("查看完整图片")
            } else if loading { ProgressView("正在载入图片…").font(.caption) }
            else if failed { Label("图片暂无法预览，可下载原文件或查看源码", systemImage: "photo.badge.exclamationmark").font(.caption).foregroundStyle(.secondary) }
            if let url {
                Button { openURL(url) } label: { Label("下载 " + url.lastPathComponent, systemImage: "arrow.down.circle") }.font(.caption)
            }
        }.task(id: key + (running ? "-running" : "-settled")) { await load() }
            .sheet(isPresented: $fullScreen) {
                NavigationStack {
                    ScrollView([.horizontal, .vertical]) { if let image { Image(uiImage: image).resizable().scaledToFit().frame(width: max(320, min(1600, image.size.width))).padding() } }
                        .background(Color.white).navigationTitle("图片").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { fullScreen = false } } }
                }
            }
    }
    private func load() async {
        loading = true; failed = false
        defer { loading = false }
        do {
            var bytes = data
            if let url, let api {
                let file: URL
                if let path = NativeFileRules.downloadPath(url, host: api.credentials.url.host ?? "", cwd: cwd) { file = try await api.download(path, sessionID: sessionID) }
                else { file = try await api.downloadExternal(url) }
                let values = try file.resourceValues(forKeys: [.fileSizeKey])
                guard (values.fileSize ?? 0) <= 25 * 1024 * 1024 else { throw AttachmentImportError.tooLarge }
                bytes = try Data(contentsOf: file)
            }
            guard let bytes, bytes.count <= 25 * 1024 * 1024 else { throw AttachmentImportError.unreadable }
            let rendered = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                if let svg = NativeSVGDocument.parse(bytes) { return svg.rasterize(scale: 1) }
                guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
                      let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 1600] as CFDictionary) else { return nil }
                return UIImage(cgImage: cg)
            }.value
            try Task.checkCancellation()
            image = rendered; failed = rendered == nil
        } catch is CancellationError { }
        catch { failed = true }
    }
}
