import SwiftUI

struct NativeMessageMedia: View {
    let message: ChatMessage
    var includeTextLinks = false
    @Environment(\.nativeWorkspace) private var cwd
    var body: some View {
        ForEach(Array(message.content.enumerated()), id: \.offset) { _, block in
            if block["type"].string == "image" {
                if let data = Data(base64Encoded: block["data"].string), !data.isEmpty { NativeMediaPreview(data: data) }
                else if let url = URL(string: block["url"].string.isEmpty ? block["source"]["url"].string : block["url"].string), !url.absoluteString.isEmpty { NativeMediaPreview(url: url) }
            }
        }
        ForEach(NativeMediaReferences.writtenSVG(message), id: \.self) { svg in NativeMediaPreview(data: Data(svg.utf8)) }
        ForEach(NativeMediaReferences.paths(message).filter { $0.pathExtension.lowercased() != "svg" || NativeMediaReferences.writtenSVG(message).isEmpty }, id: \.absoluteString) { url in NativeMediaPreview(url: url) }
        if includeTextLinks {
            ForEach(NativeDownloadLinks.files(in: message.text, cwd: cwd).filter(NativeMediaReferences.isImage), id: \.absoluteString) { url in NativeMediaPreview(url: url) }
        }
        if includeTextLinks || message.role == "toolResult", let svg = NativeMediaReferences.svg(message.text) { NativeMediaPreview(data: Data(svg.utf8)) }
    }
}
