import Foundation

/// SSE blank lines are protocol delimiters, not discardable display lines.
/// Parse original bytes so Foundation's textual line adapters cannot remove them.
struct NativeSSEFramer {
    private var line: [UInt8] = []
    private var previousCR = false
    private var firstLine = true
    private var parser = SSEParser()
    mutating func consume(_ byte: UInt8) throws -> String? {
        if previousCR { previousCR = false; if byte == 10 { return nil } }
        if byte == 10 || byte == 13 {
            previousCR = byte == 13
            var bytes = line; line.removeAll(keepingCapacity: true)
            if firstLine { firstLine = false; if bytes.starts(with: [239, 187, 191]) { bytes.removeFirst(3) } }
            return try parser.consume(String(decoding: bytes, as: UTF8.self))
        }
        guard line.count < 20 * 1024 * 1024 else { throw SSEParser.Failure.eventTooLarge }
        line.append(byte); return nil
    }
}

enum NativeSSEReader {
    static func read<S: AsyncSequence>(_ bytes: S, receive: @escaping @MainActor (WireValue) async throws -> Void) async throws where S.Element == UInt8 {
        var parser = NativeSSEFramer()
        for try await byte in bytes {
            try Task.checkCancellation()
            if let text = try parser.consume(byte) { try await receive(WireValue.parse(text)) }
        }
    }
}

enum NativeFileSort: String, CaseIterable, Identifiable {
    case nameAscending, nameDescending, kind, size
    var id: String { rawValue }
    var title: String {
        switch self { case .nameAscending: return "名称 A–Z"; case .nameDescending: return "名称 Z–A"; case .kind: return "文件类型"; case .size: return "文件大小" }
    }
}
enum NativeFileRules {
    static func downloadPath(_ url: URL, host: String, cwd: String) -> String? {
        guard url.user == nil, url.password == nil else { return nil }
        if let path = protectedDownloadPath(url, host: host) { return path }
        if url.scheme?.lowercased() == "sandbox", url.host == nil,
           let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath.removingPercentEncoding,
           path.hasPrefix("/") { return path }
        if url.host?.lowercased() == host.lowercased(), url.scheme == "https",
           !url.path.hasPrefix("/api/"), !url.path.hasPrefix("/_next/"), !url.path.isEmpty,
           url.path != "/", !(url.path as NSString).pathExtension.isEmpty { return url.path }
        if url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost" { return url.path }
        guard url.scheme == nil, url.host == nil else { return nil }
        let raw = url.path
        guard !raw.isEmpty, !raw.hasPrefix("/api/"), !raw.hasPrefix("/_next/") else { return nil }
        if raw.hasPrefix("/") { return raw }
        guard !cwd.isEmpty, raw.contains("/") || !(raw as NSString).pathExtension.isEmpty else { return nil }
        let root = URL(fileURLWithPath: cwd, isDirectory: true).standardizedFileURL.path
        let target = URL(fileURLWithPath: join(cwd, raw)).standardizedFileURL.path
        guard target.hasPrefix(root == "/" ? "/" : root + "/") else { return nil }
        return target
    }
    static func protectedDownloadPath(_ url: URL, host: String) -> String? {
        guard url.user == nil, url.password == nil,
              url.host == nil || url.host?.lowercased() == host.lowercased(),
              url.scheme == nil || ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.path.hasPrefix("/api/files/") else { return nil }
        if ["/api/files/download", "/api/files/read"].contains(url.path),
           let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "path" })?.value,
           path.hasPrefix("/") { return path }
        var path = String(url.path.dropFirst("/api/files".count))
        let slash = path.dropFirst()
        if slash.count >= 3, slash.dropFirst().first == ":" { path.removeFirst() }
        return path
    }
    static func join(_ parent: String, _ name: String) -> String {
        parent + (parent.hasSuffix("/") ? "" : "/") + name
    }
    static func safeFilename(_ original: String) -> String {
        let base = original.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? "下载文件"
        let cleaned = String(base.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "下载文件" : cleaned
    }
    static func visible(_ entries: [WireValue], search: String, sort: NativeFileSort) -> [WireValue] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter { query.isEmpty || $0["name"].string.localizedStandardContains(query) }.sorted { a, b in
            if a["isDir"].bool != b["isDir"].bool { return a["isDir"].bool }
            if sort == .size, a["size"].int != b["size"].int { return a["size"].int > b["size"].int }
            if sort == .kind {
                let left = (a["name"].string as NSString).pathExtension.lowercased(), right = (b["name"].string as NSString).pathExtension.lowercased()
                if left != right { return left < right }
            }
            let comparison = a["name"].string.localizedStandardCompare(b["name"].string)
            return sort == .nameDescending ? comparison == .orderedDescending : comparison == .orderedAscending
        }
    }
    static func isChallengeHTML(status: Int, mime: String?, disposition: String?) -> Bool {
        mime?.lowercased() == "text/html" && !(status == 200 && disposition?.lowercased().hasPrefix("attachment") == true)
    }
}

enum NativeModelSymbols {
    static func symbol(for capability: String) -> String {
        switch capability { case "文字": return "text.alignleft"; case "图片理解": return "photo"; case "推理": return "lightbulb"; case "音频输入": return "waveform"; case "视频输入": return "video"; case "文件输入": return "doc"; case "工具调用": return "wrench.and.screwdriver"; default: return "questionmark.circle" }
    }
    static func providerName(_ id: String) -> String {
        switch id { case "openai-codex": return "OpenAI Codex"; case "openai": return "OpenAI"; case "google-vertex": return "Google Vertex AI"; case "google": return "Google"; case "anthropic": return "Anthropic"; case "pi-router": return "Pi Router"; default: return id }
    }
}

enum NativeConnectionRules {
    static func idleLabel(foreground: Bool, workspaceReady: Bool) -> String {
        if !foreground { return "后台已暂停" }
        return workspaceReady ? "已就绪" : "正在准备工作空间"
    }
    static func acceptsSnapshot(startVersion: Int, currentVersion: Int) -> Bool { startVersion == currentVersion }
}
