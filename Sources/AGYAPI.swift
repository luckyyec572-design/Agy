import Foundation
import UIKit

final class AGYRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
final class AGYExternalRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, url.scheme == "https", url.user == nil, url.password == nil else { completionHandler(nil); return }
        var clean = request
        clean.setValue(nil, forHTTPHeaderField: "Authorization"); clean.setValue(nil, forHTTPHeaderField: "Cookie")
        completionHandler(clean)
    }
}
@MainActor final class AGYAPI {
    var credentials: AGYCredentials
    private let policy = AGYRedirectPolicy()
    private let session: URLSession
    init(credentials: AGYCredentials) {
        self.credentials = credentials
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 65
        config.timeoutIntervalForResource = 600
        config.httpCookieStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config, delegate: policy, delegateQueue: nil)
    }
    func request(_ path: String, query: [String: String] = [:], method: String = "GET", body: WireValue? = nil) throws -> URLRequest {
        var target = URLComponents(url: credentials.url.appendingPathComponent("v1").appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { target.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var request = URLRequest(url: target.url!)
        request.httpMethod = method
        request.setValue("Bearer " + credentials.token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Match the mobile client identity used by the existing Pi app so the
        // origin's Browser Integrity Check accepts native API requests.
        let os = UIDevice.current.systemVersion.replacingOccurrences(of: ".", with: "_")
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.3.0"
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS \(os) like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 AGY-iPhone/\(version)", forHTTPHeaderField: "User-Agent")
        if let body { request.httpBody = try JSONEncoder().encode(body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return request
    }
    func validate(_ response: URLResponse, data: Data? = nil) throws {
        guard let http = response as? HTTPURLResponse else { throw AGYError.message("服务器响应无效") }
        guard (200..<300).contains(http.statusCode) else {
            let text = data.flatMap { try? JSONDecoder().decode(WireValue.self, from: $0) }?["error"].string ?? ""
            throw AGYError.message(http.statusCode == 401 ? "连接密钥已失效，请重新连接。" : text.isEmpty ? "服务器返回 HTTP \(http.statusCode)" : text)
        }
    }
    func json<T: Decodable>(_ path: String, query: [String: String] = [:], method: String = "GET", body: WireValue? = nil) async throws -> T {
        let (data, response) = try await session.data(for: request(path, query: query, method: method, body: body))
        try validate(response, data: data)
        return try JSONDecoder().decode(T.self, from: data)
    }
    func upload(_ attachment: ImportedAttachment, sessionID: String) async throws -> AGYAttachment {
        guard attachment.data.count <= NativeAttachmentReader.maxFileBytes else { throw AttachmentImportError.tooLarge }
        var req = try request("sessions/\(sessionID)/attachments", query: ["name": attachment.name], method: "POST")
        req.setValue(attachment.mime, forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 300
        let (data, response) = try await session.upload(for: req, from: attachment.data)
        try validate(response, data: data)
        return try JSONDecoder().decode(AGYAttachment.self, from: data)
    }
    func download(_ path: String, sessionID: String, name: String? = nil) async throws -> URL {
        guard !sessionID.isEmpty else { throw AGYError.message("请先选择会话") }
        var req = try request("sessions/\(sessionID)/files", query: ["path": path])
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        let (temporary, response) = try await session.download(for: req)
        try validate(response)
        return try protect(temporary, name: NativeFileRules.safeFilename(name ?? path))
    }
    private func protect(_ temporary: URL, name: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AGYPreviews/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(name)
        try FileManager.default.moveItem(at: temporary, to: target)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: target.path)
        return target
    }
    func downloadExternal(_ url: URL) async throws -> URL {
        guard NativeDownloadLinks.isExternalFile(url) else { throw AGYError.message("不支持此下载地址") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil; configuration.httpShouldSetCookies = false
        let external = URLSession(configuration: configuration, delegate: AGYExternalRedirectPolicy(), delegateQueue: nil)
        defer { external.finishTasksAndInvalidate() }
        // No gateway authorization header is ever added to external downloads.
        let (temporary, response) = try await external.download(from: url)
        try validate(response)
        return try protect(temporary, name: NativeFileRules.safeFilename(response.suggestedFilename ?? url.lastPathComponent))
    }
    func events(_ id: String, receive: @escaping (AGYSession) -> Void) async throws {
        var req = try request("sessions/\(id)/events")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: req)
        try validate(response)
        guard (response as? HTTPURLResponse)?.mimeType == "text/event-stream" else { throw AGYError.message("服务器没有返回事件流") }
        // Preserve original delimiters; Foundation's lines adapter can discard SSE blank lines.
        var line: [UInt8] = [], parser = SSEParser(), previousCR = false
        for try await byte in bytes {
            try Task.checkCancellation()
            if previousCR { previousCR = false; if byte == 10 { continue } }
            if byte == 10 || byte == 13 {
                previousCR = byte == 13
                if let data = try parser.consume(String(decoding: line, as: UTF8.self)) {
                    receive(try JSONDecoder().decode(AGYSession.self, from: Data(data.utf8)))
                }
                line.removeAll(keepingCapacity: true)
            } else {
                guard line.count < 20 * 1024 * 1024 else { throw AGYError.message("事件内容过大") }
                line.append(byte)
            }
        }
    }
    func invalidate() { session.invalidateAndCancel() }
}
