import Foundation

enum NativeDownloadLinks {
    static let host = "agy.yectech.uk"
    static func url(_ value: String) -> URL? {
        // Encode Unicode/spaces before URL.init; mixing raw Unicode with an
        // existing %20 otherwise causes Foundation to turn % into %25.
        let allowed = CharacterSet.urlFragmentAllowed.union(CharacterSet(charactersIn: "%#[]"))
        guard let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: encoded)
    }
    static func normalizedMarkdown(_ source: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\]\(((?:[^()\n]|\([^()\n]*\))*)\)"#) else { return source }
        var result = source
        for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).reversed() {
            guard let range = Range(match.range(at: 1), in: result) else { continue }
            let destination = String(result[range]).trimmingCharacters(in: .whitespaces)
            let raw: String
            let title: String
            if destination.hasPrefix("<"), let end = destination.firstIndex(of: ">") {
                raw = String(destination[destination.index(after: destination.startIndex)..<end]); title = String(destination[destination.index(after: end)...])
            } else if let split = destination.range(of: " \"") {
                raw = String(destination[..<split.lowerBound]); title = String(destination[split.lowerBound...])
            } else { raw = destination; title = "" }
            if let value = url(raw) { result.replaceSubrange(range, with: value.absoluteString + title) }
        }
        return result
    }
    static func isExternalFile(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let domain = url.host,
              domain.lowercased() != host, url.user == nil, url.password == nil else { return false }
        let extensions: Set<String> = ["pdf", "zip", "7z", "tar", "gz", "txt", "csv", "json", "md", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "png", "jpg", "jpeg", "gif", "heic", "webp", "svg", "mp3", "mp4", "wav", "ipa", "apk", "bin", "log"]
        if extensions.contains(url.pathExtension.lowercased()) { return true }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains {
            $0.name.lowercased() == "response-content-disposition" && ($0.value?.lowercased().contains("attachment") == true)
        } == true
    }
    static func files(in text: String, cwd: String) -> [URL] {
        // Parse link destinations outside fenced code; plain code examples must
        // never turn into download requests. Preserve escaped spaces and Unicode.
        let prose = MarkdownBlock.parse(text).compactMap { block -> String? in
            switch block { case .text(let value): return value; case .table(let rows): return rows.flatMap { $0 }.joined(separator: "\n"); case .code: return nil }
        }.joined(separator: "\n")
        var urls: [URL] = []
        func append(_ url: URL) {
            if NativeFileRules.downloadPath(url, host: host, cwd: cwd) != nil || isExternalFile(url) {
                if !urls.contains(url) { urls.append(url) }
            }
        }
        if let attributed = try? AttributedString(markdown: normalizedMarkdown(prose), options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            for run in attributed.runs { if let url = run.link { append(url) } }
        }
        // Bare URLs are not reliably linked by inline-only Markdown parsing.
        if let regex = try? NSRegularExpression(pattern: #"(?:https://|sandbox:/|file:///)[^\s<>\[\])]+"#) {
            for match in regex.matches(in: prose, range: NSRange(prose.startIndex..., in: prose)) {
                guard let range = Range(match.range, in: prose) else { continue }
                let raw = String(prose[range]).trimmingCharacters(in: CharacterSet(charactersIn: "，。；,;"))
                guard let url = url(raw) else { continue }
                // Do not add a truncated bare match from a Markdown URL that
                // contains parentheses and is already handled by the parser.
                if urls.contains(where: { $0.absoluteString.hasPrefix(url.absoluteString) }) { continue }
                append(url)
            }
        }
        return urls
    }
}
