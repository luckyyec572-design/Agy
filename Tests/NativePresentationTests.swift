import Foundation

@main struct NativePresentationTests {
    static func main() throws {
        var checks = 0
        func check(_ value: Bool, _ label: String) { precondition(value, label); checks += 1 }
        func message(_ id: String, _ role: String, _ text: String) -> ChatMessage {
            ChatMessage(id: id, value: .object(["role": .string(role), "content": .string(text)]))
        }
        let user = message("u", "user", "检查服务器")
        let plan = message("p", "assistant", "检查服务状态\n这里是详细过程")
        let call = ChatMessage(id: "call", value: try WireValue.parse(#"{"role":"assistant","content":[{"type":"toolCall","name":"bash","arguments":{"command":"very long command"}}]}"#))
        let result = message("r", "toolResult", "long output")
        let final = message("f", "assistant", "## 结论\n已修复。")
        let complete = [user, plan, call, result, final]
        let turns = NativeConversationPresentation.turns(complete, live: nil, running: false)
        check(NativeOutputMode.allCases.map(\.title) == ["原版", "步骤摘要", "结论优先"], "All three modes remain available")
        check(turns.count == 1 && turns[0].user?.id == "u", "Group each user turn")
        check(turns[0].conclusion?.id == "f", "Trailing assistant answer is the conclusion")
        check(turns[0].process.map(\.id) == ["p", "call", "r"], "All process details remain available")
        check(NativeConversationPresentation.turns(complete, live: nil, running: true)[0].conclusion == nil, "Running answer remains folded until settled")
        let live = message("streaming", "assistant", "not final yet")
        check(NativeConversationPresentation.turns(Array(complete.dropLast()), live: live, running: true)[0].process.last?.id == "streaming", "Streaming deltas remain in process")
        check(NativeConversationPresentation.turns([user, plan, call, result], live: nil, running: false)[0].conclusion == nil, "Do not promote an earlier progress message after tool execution")
        let second = NativeConversationPresentation.turns(complete + [message("u2", "user", "next")], live: live, running: true)
        check(second.count == 2 && second[0].conclusion?.id == "f" && second[1].running, "Previous conclusions remain visible during next run")
        check(NativeConversationPresentation.step(call) == "执行命令", "Step label omits raw command")
        check(NativeConversationPresentation.step(plan) == "检查服务状态", "Step excerpt uses source text, no invented summary")
        check(NativeConversationPresentation.turns([], live: nil, running: false).isEmpty, "Empty transcript")
        func path(_ raw: String) -> String? { NativeFileRules.downloadPath(NativeDownloadLinks.url(raw)!, host: "agy.yectech.uk", cwd: "/workspace") }
        check(path("sandbox:/workspace/报告%20一.pdf") == "/workspace/报告 一.pdf", "Sandbox path: \(String(describing: path("sandbox:/workspace/报告%20一.pdf")))")
        check(path("https://agy.yectech.uk/workspace/report.zip") == "/workspace/report.zip", "Same-origin absolute artifact link")
        check(path("/api/files/download?path=%2Fworkspace%2Fa.zip") == "/workspace/a.zip", "Query-path download links")
        check(NativeFileRules.downloadPath(URL(string: "a.pdf")!, host: "agy.yectech.uk", cwd: "/") == "/a.pdf", "Relative file at root workspace")
        check(path("https://other.example/workspace/a.pdf") == nil, "External hosts never use authenticated Pi request")
        check(path("sandbox:/workspace/100%25.pdf") == "/workspace/100%.pdf", "Do not double-decode literal percent")
        let links = NativeDownloadLinks.files(in: "[报告](sandbox:/workspace/report.pdf)\n[包](output.zip)\n[来源](https://example.org/article)", cwd: "/workspace")
        check(links.count == 2, "Discover local artifacts, leave ordinary web links alone")
        check(NativeDownloadLinks.files(in: "```shell\nhttps://example.org/test.zip\n```", cwd: "/workspace").isEmpty, "Commands do not generate file actions")
        check(NativeDownloadLinks.files(in: "[包](https://example.org/a(1).zip)", cwd: "/workspace").count == 1, "Balanced parentheses in a file link")
        check(NativeDownloadLinks.files(in: "https://example.org/report.pdf", cwd: "").count == 1, "Bare external download URL")
        check(!NativeDownloadLinks.isExternalFile(URL(string: "https://user:pass@example.org/a.zip")!), "Reject userinfo in external link")
        check(!NativeDownloadLinks.isExternalFile(URL(string: "javascript:alert(1)")!), "Reject executable link scheme")
        let imageRead = ChatMessage(id: "image", value: try WireValue.parse(#"{"role":"toolResult","content":[{"type":"image","source":{"url":"sandbox:/workspace/p.png"}}]}"#))
        check(imageRead.content[0]["url"].string == "sandbox:/workspace/p.png", "Image source URL normalized")
        check(NativeMediaReferences.isImage(URL(string: "sandbox:/workspace/p.svg")!), "SVG is an inline image")
        check(NativeMediaReferences.svg("```svg\n<svg width=\"10\" height=\"10\"></svg>\n```") != nil, "SVG source extracted from code")
        print("Passed \(checks) conversation presentation and download link checks")
    }
}
