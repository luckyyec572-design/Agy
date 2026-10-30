import Foundation

enum NativeMediaReferences {
    static func isImage(_ url: URL) -> Bool {
        ["png", "jpg", "jpeg", "gif", "webp", "heic", "svg", "bmp", "tiff"].contains(url.pathExtension.lowercased())
    }
    static func svg(_ text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"<svg\b[^>]*>[\s\S]*?</svg>"#, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return nil }
        return String(text[range])
    }
    static func paths(_ message: ChatMessage) -> [URL] {
        var paths: [URL] = []
        var fields = [message.value, message.value["details"]]
        for block in message.content where block["type"].string == "toolCall" { fields.append(block["arguments"]) }
        for field in fields {
            for key in ["path", "file_path", "filePath", "filename", "AbsolutePath", "TargetFile", "ImagePath"] {
                if let url = URL(string: field[key].string), isImage(url), !paths.contains(url) { paths.append(url) }
            }
        }
        return paths
    }
    static func writtenSVG(_ message: ChatMessage) -> [String] {
        var sources: [String] = []
        for block in message.content where block["type"].string == "toolCall" {
            for key in ["content", "text"] {
                if let source = svg(block["arguments"][key].string), !sources.contains(source) { sources.append(source) }
            }
        }
        return sources
    }
}
