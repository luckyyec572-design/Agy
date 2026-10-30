import SwiftUI

struct NativeMessageRow: View {
    let message: ChatMessage
    var streaming = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if message.role == "user" { Image(systemName: "person.fill") }
                else if message.role == "toolResult" { Image(systemName: "terminal") }
                else { NativeAGYLogo(size: 20) }
                Text(message.role == "user" ? "你" : message.role == "toolResult" ? (message.value["toolName"].string.isEmpty ? "工具结果" : message.value["toolName"].string) : "AGY")
                if streaming { ProgressView().controlSize(.mini) }
                Spacer()
                if !message.text.isEmpty {
                    ShareLink(item: message.text) { Image(systemName: "square.and.arrow.up").font(.caption) }.accessibilityLabel("分享消息")
                }
            }.font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            NativeMessageMedia(message: message)
            if message.role == "toolResult" {
                DisclosureGroup(message.value["isError"].bool ? "工具执行失败 · 查看详情" : "查看执行结果") {
                    ForEach(Array(message.content.enumerated()), id: \.offset) { _, block in content(block) }
                }.font(.callout)
            } else {
                ForEach(Array(message.content.enumerated()), id: \.offset) { _, block in content(block) }
            }
            if !message.value["errorMessage"].string.isEmpty {
                Text(message.value["errorMessage"].string).font(.footnote).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(message.role == "user" ? Color.accentColor.opacity(0.09) : Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
        .contextMenu {
            Button("复制文本", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.text }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func content(_ block: WireValue) -> some View {
        switch block["type"].string {
        case "text": NativeMarkdown(text: block["text"].string)
        case "thinking":
            DisclosureGroup("思考过程") { NativeMarkdown(text: block["thinking"].string).foregroundStyle(.secondary) }.font(.callout)
        case "toolCall":
            DisclosureGroup {
                NativeCodeBlock(language: "命令参数", code: block["rawInput"].string.isEmpty ? block["arguments"].pretty : block["rawInput"].string, collapsed: false)
            } label: { Label(block["name"].string.isEmpty ? block["toolName"].string : block["name"].string, systemImage: "wrench.and.screwdriver") }.font(.callout)
        case "image":
            EmptyView() // Image blocks are visible above collapsed tool details.
        default: EmptyView()
        }
    }
}

struct NativeMarkdown: View {
    let text: String
    @AppStorage("nativeOutputMode") private var outputMode = NativeOutputMode.original.rawValue
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(MarkdownBlock.parse(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let value):
                    if let svg = NativeMediaReferences.svg(value) {
                        paragraphs(value.replacingOccurrences(of: svg, with: ""))
                        NativeMediaPreview(data: Data(svg.utf8))
                        NativeCodeBlock(language: "SVG 源码", code: svg, collapsed: true)
                    } else { paragraphs(value) }
                case .code(let language, let code):
                    if let svg = NativeMediaReferences.svg(code) { NativeMediaPreview(data: Data(svg.utf8)) }
                    NativeCodeBlock(language: language, code: code, collapsed: NativeMediaReferences.svg(code) != nil || outputMode != NativeOutputMode.original.rawValue)
                        .id(outputMode + language)
                case .table(let rows):
                    ScrollView(.horizontal) {
                        Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                            ForEach(Array(rows.enumerated()), id: \.offset) { row, cells in
                                GridRow {
                                    ForEach(Array(cells.enumerated()), id: \.offset) { column, cell in
                                        Text(inline(cell)).font(row == 0 ? .callout.bold() : .callout).textSelection(.enabled)
                                            .lineLimit(nil)
                                            .frame(width: tableWidth(rows, column: column), alignment: .leading)
                                            .fixedSize(horizontal: false, vertical: true).padding(10)
                                            .background(row == 0 ? Color.accentColor.opacity(0.1) : Color(uiColor: .tertiarySystemFill))
                                            .overlay(Rectangle().stroke(Color.secondary.opacity(0.12), lineWidth: 0.5))
                                    }
                                }
                            }
                        }
                    }.clipShape(RoundedRectangle(cornerRadius: 10)).reservesHorizontalSwipe()
                }
            }
            NativeFileLinks(text: text)
        }.frame(maxWidth: .infinity, alignment: .leading)
            .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
    }
    private func tableWidth(_ rows: [[String]], column: Int) -> CGFloat {
        let longest = rows.map { column < $0.count ? $0[column].count : 0 }.max() ?? 0
        return CGFloat(min(240, max(110, longest * 10)))
    }
    private func inline(_ value: String) -> AttributedString {
        (try? AttributedString(markdown: NativeDownloadLinks.normalizedMarkdown(value), options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(value)
    }
    private func paragraphs(_ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(value.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                if line.hasPrefix("### ") { Text(inline(String(line.dropFirst(4)))).font(.headline).textSelection(.enabled) }
                else if line.hasPrefix("## ") { Text(inline(String(line.dropFirst(3)))).font(.title3.bold()).textSelection(.enabled) }
                else if line.hasPrefix("# ") { Text(inline(String(line.dropFirst(2)))).font(.title2.bold()).textSelection(.enabled) }
                else if line.hasPrefix("> ") {
                    HStack(alignment: .top) { Capsule().fill(.tint).frame(width: 3); Text(inline(String(line.dropFirst(2)))).foregroundStyle(.secondary).textSelection(.enabled) }.fixedSize(horizontal: false, vertical: true)
                } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                    HStack(alignment: .top) { Text("•"); Text(inline(String(line.dropFirst(2)))).textSelection(.enabled) }
                } else { Text(inline(line)).textSelection(.enabled) }
            }
        }
    }
}

struct NativeCodeBlock: View {
    let language: String
    let code: String
    let collapsed: Bool
    @State private var expanded = false
    @State private var wrap = true
    init(language: String, code: String, collapsed: Bool) {
        self.language = language; self.code = code; self.collapsed = collapsed
        _expanded = State(initialValue: !collapsed)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button { expanded.toggle() } label: {
                    Label(language.isEmpty ? "代码" : language, systemImage: expanded ? "chevron.down" : "chevron.right")
                }.font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { wrap.toggle() } label: { Image(systemName: wrap ? "text.word.spacing" : "arrow.left.and.right") }
                    .accessibilityLabel(wrap ? "自动换行已开启，切换为横向滚动" : "开启自动换行")
                Button { UIPasteboard.general.string = code } label: { Label("复制", systemImage: "doc.on.doc") }.font(.caption)
            }
            if expanded {
                if wrap {
                    Text(code).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                } else {
                    ScrollView(.horizontal) { Text(code).font(.system(.callout, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: true, vertical: true) }.reservesHorizontalSwipe()
                }
            }
        }.padding(12).background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))
    }
}
