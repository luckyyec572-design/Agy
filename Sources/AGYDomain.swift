import Foundation

struct AGYModel: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    var family: String { name.components(separatedBy: " (").first ?? name }
}
struct AGYAttachment: Codable, Identifiable {
    let id: String
    let name: String
    let mime: String
    let size: Int
    var path: String?
}
struct AGYModelVariant: Codable, Hashable { let id: String; let effort: String }
struct AGYModelFamily: Codable, Identifiable {
    let id: String
    let name: String
    let variants: [AGYModelVariant]
    let efforts: [String]
    let defaultEffort: String
}
enum AGYThinking {
    static func title(_ value: String) -> String {
        ["low": "低", "medium": "中", "high": "高", "xhigh": "更高", "max": "最高", "": "由模型决定"][value] ?? value
    }
}
enum AGYApprovalMode: String, CaseIterable, Identifiable {
    case review, turbo
    var id: String { rawValue }
    var title: String { self == .review ? "Restriction Mode · 逐项审批" : "Turbo Mode · 自动执行" }
    var detail: String { self == .review ? "每次工具操作都等待你的允许或拒绝，包括读取文件。审批超时或断开时拒绝执行。" : "无需逐项审批即可读写文件、执行命令和使用工具；服务器明确禁止的规则仍有效。" }
}
struct AGYApproval: Codable, Identifiable {
    let id: String
    let sessionID: String
    let tool: String
    let parameters: WireValue
    let createdAt: Double
    let expiresAt: Double
}
struct AGYResponseStep: Codable { let index: Int; let text: String }
struct AGYLimits: Decodable {
    let fetchedAt: Double
    let source: String
    let groups: [AGYLimitGroup]
}
struct AGYLimitGroup: Decodable, Identifiable {
    let name: String
    var description: String?
    let buckets: [AGYLimitBucket]
    var id: String { name }
}
struct AGYLimitBucket: Decodable, Identifiable {
    let id: String
    let name: String
    var remaining_fraction: Double?
    var reset_time: String?
    var window: String?
    var reset: Date? { reset_time.flatMap { ISO8601DateFormatter().date(from: $0) } }
    var title: String { window == "5h" ? "5 小时额度" : window == "weekly" ? "每周额度" : name }
}
struct AGYTool: Codable, Identifiable {
    let id: String
    let name: String
    let state: String
    let parameters: WireValue
    let output: String
    var isError: Bool?
}
struct AGYMessage: Codable, Identifiable {
    let id: String
    let role: String
    let text: String
    var tools: [AGYTool]?
    var attachments: [AGYAttachment]?
    var steps: [AGYResponseStep]?
    var rendered: ChatMessage {
        var blocks: [WireValue] = [.object(["type": .string("text"), "text": .string(text)])]
        for a in attachments ?? [] {
            guard let path = a.path else { continue }
            let url = URL(fileURLWithPath: path).absoluteString
            if a.mime.hasPrefix("image/") { blocks.append(.object(["type": .string("image"), "url": .string(url)])) }
            else { blocks.append(.object(["type": .string("text"), "text": .string("[\(a.name)](\(url))")])) }
        }
        return ChatMessage(id: id, value: .object(["role": .string(role), "content": .array(blocks)]))
    }
    var presented: [ChatMessage] {
        guard role == "assistant" else { return [rendered] }
        var middle: [(Int, ChatMessage)] = []
        for tool in tools ?? [] {
            middle.append((Int(tool.id) ?? 0, ChatMessage(id: id + "-tool-" + tool.id, value: .object([
                "role": .string("toolResult"), "toolName": .string(tool.name), "details": tool.parameters,
                "isError": .bool(tool.isError ?? false), "content": .string("```json\n" + tool.parameters.pretty + "\n```\n" + tool.output)]))))
        }
        for step in steps ?? [] where !step.text.isEmpty && step.text.trimmingCharacters(in: .whitespacesAndNewlines) != text.trimmingCharacters(in: .whitespacesAndNewlines) {
            middle.append((step.index, ChatMessage(id: id + "-step-\(step.index)", value: .object(["role": .string("assistant"), "content": .string(step.text)]))))
        }
        let process = middle.sorted { $0.0 < $1.0 }.map(\.1)
        return text.isEmpty ? process : process + [rendered]
    }
}
struct AGYSession: Codable, Identifiable {
    let id: String
    var name: String
    let cwd: String
    let model: String
    let mode: String
    let modified: Double
    let running: Bool
    let conversationID: String
    let error: String
    let revision: Int
    var messages: [AGYMessage]?
    var baseModel: String?
    var effort: String?
    var approvalMode: String?
    var approvals: [AGYApproval]?
}
struct AGYStatus: Decodable {
    let name: String
    let version: Int
    let roots: [String]
    let defaultModel: String
    var accountProfile: String?
    var capabilities: AGYCapabilities?
}
struct AGYCapabilities: Decodable { let separateEffort: Bool; let nativeApprovals: Bool; let artifacts: Bool }
struct AGYModels: Decodable { let models: [AGYModel]; var families: [AGYModelFamily]? }
struct AGYSessions: Decodable { let sessions: [AGYSession] }
struct AGYCredentials: Codable {
    let url: URL
    let token: String
    static func validated(_ rawURL: String, token: String) throws -> Self {
        guard let url = URL(string: rawURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, ["", "/"].contains(url.path), token.count >= 32,
              !token.contains("\n"), !token.contains("\r") else { throw AGYError.message("请输入 HTTPS 服务器地址和完整连接密钥。") }
        return Self(url: url, token: token)
    }
}
enum AGYError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
