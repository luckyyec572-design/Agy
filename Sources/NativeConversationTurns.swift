import SwiftUI

struct NativeConversationTurns: View {
    let turns: [NativeConversationTurn]
    let mode: NativeOutputMode
    var body: some View {
        ForEach(turns) { turn in
            if let user = turn.user { NativeMessageRow(message: user).id(user.id) }
            VStack(alignment: .leading, spacing: 12) {
                if mode == .steps {
                    ForEach(Array(turn.process.enumerated()), id: \.element.id) { index, message in
                        DisclosureGroup {
                            NativeMessageRow(message: message, streaming: message.id == "streaming")
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                Text(NativeConversationPresentation.step(message)).font(.callout).foregroundStyle(message.value["isError"].bool ? .red : .primary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        NativeMessageMedia(message: message, includeTextLinks: true)
                    }
                }
                if turn.running {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text(mode == .conclusion ? "正在思考…" : "正在处理下一步…") }.font(.callout).foregroundStyle(.secondary)
                }
                if let final = turn.conclusion {
                    NativeMessageRow(message: final).id(final.id)
                }
                if mode == .conclusion, !turn.process.isEmpty {
                    if !turn.running { ForEach(turn.process) { NativeMessageMedia(message: $0, includeTextLinks: true) } }
                    DisclosureGroup("中间过程 · \(turn.process.count) 项") {
                        ForEach(turn.process) { NativeMessageRow(message: $0, streaming: $0.id == "streaming") }
                    }.font(.callout)
                }
                if !turn.running && turn.conclusion == nil && !turn.process.isEmpty {
                    Text("本轮未产生最终结论，可展开过程查看执行结果。").font(.caption).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
