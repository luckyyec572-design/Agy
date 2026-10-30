import SwiftUI

struct AGYLimitsView: View {
    @EnvironmentObject private var store: AGYStore
    var body: some View {
        List {
            if let limits = store.limits {
                ForEach(limits.groups) { group in
                    Section(group.name) {
                        ForEach(group.buckets) { bucket in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text(bucket.title).font(.headline)
                                    Spacer()
                                    if let fraction = bucket.remaining_fraction {
                                        Text(max(0, min(1, fraction)), format: .percent.precision(.fractionLength(0))).monospacedDigit().fontWeight(.semibold)
                                    } else { Text("未返回").foregroundStyle(.secondary) }
                                }
                                if let fraction = bucket.remaining_fraction {
                                    ProgressView(value: max(0, min(1, fraction))).tint(fraction < 0.1 ? .orange : NativeTheme.accent).accessibilityLabel("剩余额度")
                                }
                                if let reset = bucket.reset {
                                    Text("重置：\(reset.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                                }
                            }.padding(.vertical, 6)
                        }
                    }
                }
                Section {
                    Text("百分比为账户实际剩余额度；同组模型共享额度，Gemini 4 的独立额度按账户返回结果显示。").font(.footnote).foregroundStyle(.secondary)
                    LabeledContent("更新于", value: Date(timeIntervalSince1970: limits.fetchedAt).formatted(date: .abbreviated, time: .standard)).font(.caption)
                }
            } else if store.limitsLoading {
                HStack { ProgressView(); Text("正在读取账户额度…") }
            }
            if let error = store.limitsError { Section { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red) } }
        }.navigationTitle("账户额度").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button { Task { await store.refreshLimits() } } label: { Image(systemName: "arrow.clockwise") }.disabled(store.limitsLoading).accessibilityLabel("刷新额度") }
            .refreshable { await store.refreshLimits() }
            .task { await store.refreshLimits() }
    }
}
