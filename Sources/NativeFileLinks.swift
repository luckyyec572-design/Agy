import SwiftUI

struct NativeFileLinks: View {
    let text: String
    @Environment(\.openURL) private var openURL
    @Environment(\.nativeWorkspace) private var cwd
    var body: some View {
        ForEach(NativeDownloadLinks.files(in: text, cwd: cwd), id: \.absoluteString) { url in
            if NativeMediaReferences.isImage(url) { NativeMediaPreview(url: url) }
            else {
            Button { openURL(url) } label: {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.down.doc")
                    Text(url.lastPathComponent.isEmpty ? "下载文件" : url.lastPathComponent)
                        .font(.callout).lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.down.circle").font(.caption)
                }.padding(12).background(NativeTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                    .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(NativeTheme.border, lineWidth: 0.75) }
            }.buttonStyle(.plain).accessibilityLabel("下载 " + url.lastPathComponent)
            }
        }
    }
}

private struct NativeWorkspaceKey: EnvironmentKey { static let defaultValue = "" }
extension EnvironmentValues {
    var nativeWorkspace: String {
        get { self[NativeWorkspaceKey.self] }
        set { self[NativeWorkspaceKey.self] = newValue }
    }
}

private struct NativeSessionKey: EnvironmentKey { static let defaultValue = "" }
extension EnvironmentValues {
    var nativeSessionID: String {
        get { self[NativeSessionKey.self] }
        set { self[NativeSessionKey.self] = newValue }
    }
}
