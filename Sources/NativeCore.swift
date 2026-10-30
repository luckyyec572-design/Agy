import Foundation

// Keep wire values tolerant of extension-specific fields and new server events.
enum WireValue: Codable, Hashable {
    case object([String: WireValue]), array([WireValue]), string(String), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([WireValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: WireValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    subscript(_ key: String) -> WireValue { if case .object(let v) = self { return v[key] ?? .null }; return .null }
    var string: String { if case .string(let v) = self { return v }; return "" }
    var array: [WireValue] { if case .array(let v) = self { return v }; return [] }
    var bool: Bool { if case .bool(let v) = self { return v }; return false }
    var int: Int { if case .number(let v) = self { return Int(exactly: v) ?? 0 }; return 0 }
    var double: Double { if case .number(let v) = self { return v }; return 0 }
    var pretty: String {
        guard let data = try? JSONEncoder.pretty.encode(self) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
    static func parse(_ text: String) throws -> WireValue { try JSONDecoder().decode(Self.self, from: Data(text.utf8)) }
}
extension JSONEncoder {
    static var pretty: JSONEncoder { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]; return e }
}

struct PiSession: Codable, Identifiable, Equatable {
    let id: String
    var cwd: String
    var name: String?
    var firstMessage: String?
    var modified: String?
    var relation: WireValue?
    var title: String { [name, firstMessage].compactMap { $0 }.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0 != "(no messages)" } ?? "新会话" }
    var project: String { cwd.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? cwd }
}

struct PiModel: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let provider: String
    var input: [String]?
    var reasoning: Bool?
    var supportsTools: Bool?
    var contextWindow: Int?
    var maxTokens: Int?
    var key: String { provider + ":" + id }
    func capabilityLabels(thinkingLevels: [String]) -> [String] {
        var labels: [String] = []
        for value in input ?? [] {
            let title: String
            switch value { case "text": title = "文字"; case "image": title = "图片理解"; case "audio": title = "音频输入"; case "video": title = "视频输入"; case "file", "document": title = "文件输入"; default: title = value }
            if !labels.contains(title) { labels.append(title) }
        }
        if reasoning == true || thinkingLevels.contains(where: { $0 != "off" }) { labels.append("推理") }
        if supportsTools == true { labels.append("工具调用") }
        return labels
    }
}

struct ChatMessage: Codable, Identifiable, Equatable {
    var id: String
    var value: WireValue
    var role: String { value["role"].string }
    var content: [WireValue] {
        if case .string(let text) = value["content"] { return [.object(["type": .string("text"), "text": .string(text)])] }
        if role == "bashExecution" {
            return [.object(["type": .string("text"), "text": .string("```shell\n" + value["command"].string + "\n" + value["output"].string + "\n```")])]
        }
        return value["content"].array.map { block in
            guard case .object(var fields) = block else { return block }
            if block["type"].string == "image" {
                if block["data"].string.isEmpty { fields["data"] = block["source"]["data"] }
            } else if block["type"].string == "toolCall" {
                if block["name"].string.isEmpty { fields["name"] = block["toolName"] }
                if block["arguments"] == .null { fields["arguments"] = block["input"] }
            }
            return .object(fields)
        }
    }
    var text: String { content.filter { $0["type"].string == "text" }.map { $0["text"].string }.joined(separator: "\n") }
    var identity: String {
        // SDK message timestamps survive snapshots and SSE; toolCallId identifies results.
        role + ":" + value["timestamp"].pretty + ":" + value["toolCallId"].string
    }
    static func history(_ context: WireValue) -> [ChatMessage] {
        let ids = context["entryIds"].array
        return context["messages"].array.enumerated().compactMap { index, value in
            guard value["role"].string != "system",
                  !(value["role"].string == "custom" && !value["display"].bool) else { return nil }
            return Self(id: index < ids.count ? ids[index].string : "history-\(index)", value: value)
        }
    }
}

struct SSEParser {
    private var dataLines: [String] = []
    private var byteCount = 0
    enum Failure: Error { case eventTooLarge }
    mutating func consume(_ rawLine: String) throws -> String? {
        let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
        if line.isEmpty {
            defer { dataLines.removeAll(keepingCapacity: true); byteCount = 0 }
            return dataLines.isEmpty ? nil : dataLines.joined(separator: "\n")
        }
        guard line.hasPrefix("data:") else { return nil }
        var data = String(line.dropFirst(5))
        if data.first == " " { data.removeFirst() }
        byteCount += data.utf8.count
        guard byteCount <= 20 * 1024 * 1024 else { throw Failure.eventTooLarge }
        dataLines.append(data)
        return nil
    }
}

struct LiveTranscript {
    var message: ChatMessage?
    var tools: [String: String] = [:]
    var running = false
    var phase = ""
    private var blocks: [Int: WireValue] = [:]

    mutating func ingest(_ event: WireValue) -> ChatMessage? {
        switch event["type"].string {
        case "connected": running = event["isStreaming"].bool; tools = [:]; message = nil; blocks = [:]
        case "agent_start": running = true; phase = "正在思考"
        case "message_start":
            guard running else { return nil }
            let value = event["message"]
            guard value["role"].string == "assistant" else { return nil }
            message = ChatMessage(id: "streaming", value: value)
            blocks = Dictionary(uniqueKeysWithValues: message!.content.enumerated().map { ($0.offset, $0.element) })
        case "message_update":
            guard running else { return nil }
            let delta = event["assistantMessageEvent"]
            let kind = delta["type"].string
            let index = delta["contentIndex"].int
            guard index >= 0 && index <= 4096 else { return nil }
            var block = blocks[index] ?? .object([:])
            var fields: [String: WireValue] = [:]
            if case .object(let existing) = block { fields = existing }
            switch kind {
            case "text_start": fields = ["type": .string("text"), "text": .string("")]
            case "thinking_start": fields = ["type": .string("thinking"), "thinking": .string("")]
            case "text_delta": fields["type"] = .string("text"); fields["text"] = .string((fields["text"]?.string ?? "") + delta["delta"].string)
            case "thinking_delta": fields["type"] = .string("thinking"); fields["thinking"] = .string((fields["thinking"]?.string ?? "") + delta["delta"].string)
            case "text_end": fields = ["type": .string("text"), "text": delta["content"]]
            case "thinking_end": fields = ["type": .string("thinking"), "thinking": delta["content"]]
            case "toolcall_start": fields = ["type": .string("toolCall"), "id": delta["id"], "name": delta["toolName"]]
            case "toolcall_delta": fields["rawInput"] = .string((fields["rawInput"]?.string ?? "") + delta["delta"].string)
            case "toolcall_end": if case .object(let call) = delta["toolCall"] { fields = call }
            default: return nil
            }
            block = .object(fields); blocks[index] = block
            var value: [String: WireValue] = ["role": .string("assistant")]
            if let message, case .object(let old) = message.value { value = old }
            value["content"] = .array(blocks.keys.sorted().compactMap { blocks[$0] })
            message = ChatMessage(id: "streaming", value: .object(value))
        case "message_end":
            let value = event["message"]
            guard value["role"].string != "system", !value["role"].string.isEmpty,
                  !(value["role"].string == "custom" && !value["display"].bool) else { return nil }
            if value["role"].string == "assistant" { message = nil; blocks = [:] }
            return ChatMessage(id: UUID().uuidString, value: value)
        case "tool_execution_start":
            tools[event["toolCallId"].string] = event["toolName"].string; phase = "正在执行工具"
        case "tool_execution_end": tools.removeValue(forKey: event["toolCallId"].string)
        case "auto_retry_start": phase = "服务正在重试（\(event["attempt"].int)）"
        case "auto_compaction_start", "compaction_start": phase = "正在整理上下文"
        case "prompt_done", "agent_settled": running = false; tools = [:]; phase = ""
        // agent_end may be followed by a retry or another stage of the same prompt.
        default: break
        }
        return nil
    }
}

enum MarkdownBlock: Equatable {
    case text(String), code(String, String), table([[String]])
    static func parse(_ source: String) -> [MarkdownBlock] {
        let lines = source.components(separatedBy: "\n")
        var result: [MarkdownBlock] = [], paragraph: [String] = [], code: [String] = []
        var fence: String?, language = "", index = 0
        func flush() { if !paragraph.isEmpty { result.append(.text(paragraph.joined(separator: "\n"))); paragraph = [] } }
        func cells(_ line: String) -> [String] {
            var text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("|") { text.removeFirst() }; if text.hasSuffix("|") { text.removeLast() }
            return text.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        while index < lines.count {
            let line = lines[index], trimmed = line.trimmingCharacters(in: .whitespaces)
            if let active = fence {
                if trimmed.hasPrefix(active) { result.append(.code(language, code.joined(separator: "\n"))); code = []; fence = nil }
                else { code.append(line) }
            } else if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush(); fence = String(trimmed.prefix(3)); language = String(trimmed.dropFirst(3))
            } else if index + 1 < lines.count, line.contains("|"), !cells(lines[index + 1]).isEmpty,
                      cells(lines[index + 1]).allSatisfy({ $0.filter { $0 != ":" && $0 != " " }.count >= 3 && $0.allSatisfy { "-: ".contains($0) } }) {
                flush(); var rows = [cells(line)]; index += 2
                while index < lines.count, lines[index].contains("|"), !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(cells(lines[index])); index += 1
                }
                result.append(.table(rows)); continue
            } else { paragraph.append(line) }
            index += 1
        }
        if fence != nil { result.append(.code(language, code.joined(separator: "\n"))) }
        flush(); return result
    }
}
