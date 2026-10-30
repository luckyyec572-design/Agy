import Foundation

enum NativeOutputMode: String, CaseIterable, Identifiable {
    case original, steps, conclusion
    var id: String { rawValue }
    var title: String {
        switch self { case .original: return "原版"; case .steps: return "步骤摘要"; case .conclusion: return "结论优先" }
    }
}

struct NativeConversationTurn: Identifiable {
    let id: String
    var user: ChatMessage?
    var process: [ChatMessage]
    var conclusion: ChatMessage?
    var running: Bool
}

enum NativeConversationPresentation {
    static func turns(_ messages: [ChatMessage], live: ChatMessage?, running: Bool) -> [NativeConversationTurn] {
        var all = messages
        if let live { all.append(live) }
        var groups: [[ChatMessage]] = []
        for message in all {
            if groups.isEmpty || message.role == "user" { groups.append([]) }
            groups[groups.count - 1].append(message)
        }
        return groups.enumerated().map { index, group in
            let active = running && index == groups.count - 1
            let user = group.first?.role == "user" ? group.first : nil
            var process = user == nil ? group : Array(group.dropFirst())
            var finalMessage: ChatMessage?
            // Only the trailing assistant response after all tool results can be
            // final. Do not promote an earlier progress message or running text.
            if !active, let last = process.last, last.role == "assistant",
               !last.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !last.content.contains(where: { $0["type"].string == "toolCall" }) {
                finalMessage = process.removeLast()
            }
            return NativeConversationTurn(id: group.first!.id, user: user, process: process, conclusion: finalMessage, running: active)
        }
    }

    static func step(_ message: ChatMessage) -> String {
        if message.value["isError"].bool || !message.value["errorMessage"].string.isEmpty { return "执行失败 · 展开查看详情" }
        if message.role == "toolResult" { return "\(message.value["toolName"].string.isEmpty ? "工具" : message.value["toolName"].string) · 执行结果" }
        if message.role == "bashExecution" { return "执行命令" }
        if let call = message.content.first(where: { $0["type"].string == "toolCall" }) {
            let name = call["name"].string.isEmpty ? "调用工具" : call["name"].string
            // An action label only; raw arguments/commands stay in the disclosure.
            if message.text.isEmpty {
                let labels = ["bash": "执行命令", "read": "读取文件", "write": "写入文件", "edit": "修改文件", "grep": "检索内容", "find": "查找文件", "run_command": "执行命令", "view_file": "读取文件", "write_to_file": "写入文件", "replace_file_content": "修改文件", "search_web": "检索网页"]
                return labels[name] ?? name
            }
        }
        let text = message.text.components(separatedBy: "\n").first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("```") })
        if let text { return String(text.trimmingCharacters(in: CharacterSet(charactersIn: "# *>-")).prefix(120)) }
        return message.content.contains(where: { $0["type"].string == "thinking" }) ? "思考过程" : "处理步骤"
    }
}
