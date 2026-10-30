import SwiftUI

@main struct AGYApp: App {
    @StateObject private var store = AGYStore()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            AGYRoot().environmentObject(store).tint(NativeTheme.accent)
                .task { await store.restore() }
                .onChange(of: phase) { _, value in store.scene(value) }
        }
    }
}
struct AGYRoot: View {
    @EnvironmentObject private var store: AGYStore
    @State private var file: PreviewDocument?
    @State private var downloading = false
    var body: some View {
        Group {
            if store.connected {
                TabView(selection: $store.tab) {
                    AGYChat().tag(0).tabItem { Label("对话", systemImage: "bubble.left.and.bubble.right") }
                    AGYHistory().tag(1).tabItem { Label("历史", systemImage: "clock") }
                    AGYSettings().tag(2).tabItem { Label("设置", systemImage: "gearshape") }
                }
            } else { AGYConnection() }
        }
        .environment(\.nativeMediaAPI, store.api)
        .environment(\.nativeWorkspace, store.cwd)
        .environment(\.nativeSessionID, store.selected?.id ?? "")
        .environment(\.nativeMediaRunning, store.selected?.running ?? false)
        .environment(\.openURL, OpenURLAction { url in
            guard let api = store.api else { return .systemAction }
            let path = NativeFileRules.downloadPath(url, host: api.credentials.url.host ?? "", cwd: store.cwd)
            guard path != nil || NativeDownloadLinks.isExternalFile(url) else { return .systemAction }
            guard !downloading else { return .handled }
            let sid = store.selected?.id ?? ""
            downloading = true
            Task {
                defer { downloading = false }
                do {
                    let target: URL
                    if let path { target = try await api.download(path, sessionID: sid) }
                    else { target = try await api.downloadExternal(url) }
                    file = PreviewDocument(url: target)
                } catch { store.error = error.localizedDescription }
            }
            return .handled
        })
        .sheet(item: $file) { NativeDownloadedFile(url: $0.url) }
        .overlay { if downloading { ProgressView("正在下载文件…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18)) } }
    }
}
struct AGYConnection: View {
    @EnvironmentObject private var store: AGYStore
    @State private var address = "https://agy.yectech.uk"
    @State private var key = ""
    @State private var visible = false
    @FocusState private var focused: Bool
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    NativeAGYLogo(size: 64).padding(.top, 36)
                    Text("AGY，随身同行。 ").font(.largeTitle.bold())
                    Text("连接你的服务器，在 iPhone 上继续工作。").font(.body).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 14) {
                        Text("服务器地址").font(.headline)
                        TextField("https://你的服务器", text: $address).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().textContentType(.URL).padding(12).background(NativeTheme.canvas, in: RoundedRectangle(cornerRadius: 12))
                        Text("连接密钥").font(.headline)
                        HStack {
                            Group { if visible { TextField("服务器提供的连接密钥", text: $key) } else { SecureField("服务器提供的连接密钥", text: $key) } }
                                .textInputAutocapitalization(.never).autocorrectionDisabled().focused($focused)
                            Button { visible.toggle() } label: { Image(systemName: visible ? "eye.slash" : "eye") }.accessibilityLabel("显示或隐藏连接密钥")
                        }.padding(12).background(NativeTheme.canvas, in: RoundedRectangle(cornerRadius: 12))
                        Button {
                            focused = false
                            do { let c = try AGYCredentials.validated(address, token: key.trimmingCharacters(in: .whitespacesAndNewlines)); Task { await store.connect(c) } }
                            catch { store.error = error.localizedDescription }
                        } label: { HStack { Spacer(); if store.busy { ProgressView() }; Text("连接 AGY").fontWeight(.semibold); Spacer() }.padding(.vertical, 10) }
                            .buttonStyle(.borderedProminent).disabled(store.busy || address.isEmpty || key.isEmpty)
                    }.padding(20).background(NativeTheme.surface, in: RoundedRectangle(cornerRadius: 24))
                    if let error = store.error { Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.red).textSelection(.enabled) }
                    Text("连接信息保存在本机钥匙串。Google 账号由服务器上的 AGY 管理。").font(.footnote).foregroundStyle(.secondary)
                }.padding(24)
            }.background(NativeTheme.canvas).navigationTitle("AGY").navigationBarTitleDisplayMode(.inline)
                .onAppear { if !store.storedURL.isEmpty { address = store.storedURL } }
        }
    }
}
struct AGYChat: View {
    @EnvironmentObject private var store: AGYStore
    @State private var showConfiguration = false
    @State private var following = true
    @State private var jumpToLatest = 0
    @AppStorage("nativeOutputMode") private var outputMode = NativeOutputMode.original.rawValue
    @State private var attachmentPicker: AGYAttachmentPicker?
    @State private var pickerContext = UUID()
    @FocusState private var composerFocused: Bool
    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if store.selected?.messages?.isEmpty != false {
                            VStack(alignment: .leading, spacing: 16) {
                                NativeAGYLogo(size: 52)
                                Text("今天想做些什么？").font(.title.bold())
                                Text("分析代码、整理思路，或继续服务器上的工作。").foregroundStyle(.secondary)
                                ForEach(["查看当前目录，介绍项目结构", "帮我分析一个问题，先给出计划"], id: \.self) { text in
                                    Button { store.draft = text } label: { HStack { Text(text).multilineTextAlignment(.leading); Spacer(); Image(systemName: "arrow.up.left") }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(NativeTheme.surface, in: RoundedRectangle(cornerRadius: 16)) }.buttonStyle(.plain)
                                }
                            }.padding(.vertical, 36)
                        }
                        if outputMode == NativeOutputMode.original.rawValue {
                            ForEach(store.presentedMessages) { message in
                                NativeMessageRow(message: message, streaming: message.id == store.selected?.messages?.last?.id && store.selected?.running == true)
                            }
                        } else {
                            NativeConversationTurns(turns: NativeConversationPresentation.turns(store.presentedMessages, live: nil, running: store.selected?.running ?? false), mode: NativeOutputMode(rawValue: outputMode) ?? .original)
                        }
                        ForEach(store.selected?.approvals ?? []) { request in AGYApprovalCard(request: request) }
                        if store.selected?.running == true { HStack { ProgressView(); Text("AGY 正在工作…").font(.callout).foregroundStyle(.secondary) }.padding(10) }
                        if let issue = store.error { Label(issue, systemImage: "wifi.exclamationmark").font(.callout).foregroundStyle(.red).textSelection(.enabled) }
                        if let error = store.selected?.error, !error.isEmpty { Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
                        if store.pending != nil {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("上一条消息的发送结果待确认。").font(.callout)
                                HStack {
                                    Button("核对会话") { if let id = store.pending?.sessionID { Task { await store.select(id) } } }
                                    Button("按原编号重试") { Task { await store.retryPending() } }
                                }.buttonStyle(.bordered).disabled(store.busy)
                            }.padding().background(NativeTheme.surface, in: RoundedRectangle(cornerRadius: 16))
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }.padding(16)
                        .background(NativeScrollFollow(conversation: store.selected?.id ?? "new", jump: jumpToLatest, following: $following).frame(width: 0, height: 0))
                }.scrollDismissesKeyboard(.interactively)
                    .overlay(alignment: .bottomTrailing) { if !following { Button { jumpToLatest += 1 } label: { Image(systemName: "arrow.down").padding(14).background(.regularMaterial, in: Circle()) }.accessibilityLabel("回到最新消息").padding() } }
                    .safeAreaInset(edge: .bottom, spacing: 0) { composer }
                    .background(NativeTheme.canvas)
            }
            .navigationTitle(store.selected?.name ?? "AGY")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button { showConfiguration = true } label: { Image(systemName: "slider.horizontal.3").frame(width: 36, height: 36) }.accessibilityLabel("模型和工作目录") }
                ToolbarItem(placement: .topBarTrailing) { Button { store.newConversation() } label: { Image(systemName: "square.and.pencil").frame(width: 36, height: 36) }.accessibilityLabel("新建对话").disabled(store.busy || store.pending != nil) }
            }
            .sheet(isPresented: $showConfiguration) { AGYConfiguration() }
            .sheet(item: $attachmentPicker) { picker in
                if picker == .photos {
                    NativePhotoPicker(limit: max(1, 8 - store.attachments.count)) { results in
                        let context = pickerContext; attachmentPicker = nil
                        Task { await store.importPhotos(results, context: context) }
                    }
                } else {
                    NativeDocumentPicker { urls in
                        let context = pickerContext; attachmentPicker = nil
                        Task { await store.importFiles(urls, context: context) }
                    }
                }
            }
        }
    }
    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !store.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(store.attachments) { item in
                            HStack(spacing: 8) {
                                if item.imported.mime.hasPrefix("image/"), let image = UIImage(data: item.imported.data) {
                                    Image(uiImage: image).resizable().scaledToFill().frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 8))
                                } else { Image(systemName: "doc").frame(width: 28) }
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.imported.name).font(.caption).lineLimit(1)
                                    Text(ByteCountFormatter.string(fromByteCount: Int64(item.imported.data.count), countStyle: .file)).font(.caption2).foregroundStyle(.secondary)
                                }.frame(width: 110, alignment: .leading)
                                Button { store.attachments.removeAll { $0.id == item.id } } label: { Image(systemName: "xmark.circle.fill").frame(width: 36, height: 44) }.disabled(store.busy).accessibilityLabel("移除 \(item.imported.name)")
                            }.padding(8).background(NativeTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }.frame(height: 64)
            }
            if store.importing || !store.uploadProgress.isEmpty {
                HStack { ProgressView().controlSize(.small); Text(store.importing ? "正在读取附件…" : store.uploadProgress).font(.caption).lineLimit(2) }
            }
            HStack(spacing: 8) {
                Circle().fill(store.selected?.running == true ? .orange : NativeTheme.accent).frame(width: 6, height: 6)
                Text(store.connection).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { showConfiguration = true } label: { Text(store.currentFamily?.name ?? "选择模型").lineLimit(1).font(.caption) }
            }
            HStack {
                Text("思考：" + AGYThinking.title(store.effort)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(store.approvalMode == "turbo" ? "Turbo" : store.approvalMode == "review" ? "逐项审批" : "旧版策略").font(.caption2).foregroundStyle(.secondary)
                Menu { Picker("输出展示", selection: $outputMode) { ForEach(NativeOutputMode.allCases) { Text($0.title).tag($0.rawValue) } } } label: { Label(NativeOutputMode(rawValue: outputMode)?.title ?? "原版", systemImage: "text.alignleft").font(.caption) }
            }
            HStack(alignment: .bottom, spacing: 12) {
                Menu {
                    Button("照片图库", systemImage: "photo.on.rectangle") { pickerContext = store.attachmentContext; attachmentPicker = .photos }
                    Button("选择文件", systemImage: "doc") { pickerContext = store.attachmentContext; attachmentPicker = .files }
                } label: { Image(systemName: "plus").frame(width: 36, height: 44) }
                    .disabled(store.busy || store.importing || store.pending != nil || store.attachments.count >= 8).accessibilityLabel("添加照片或文件")
                TextField("发送消息…", text: $store.draft, axis: .vertical).lineLimit(1...6).focused($composerFocused).padding(.vertical, 9)
                if store.selected?.running == true {
                    Button { Task { await store.stop() } } label: { Image(systemName: "stop.fill").frame(width: 44, height: 44).background(NativeTheme.accent, in: Circle()).foregroundStyle(NativeTheme.onAccent) }.accessibilityLabel("停止任务")
                } else {
                    Button { composerFocused = false; jumpToLatest += 1; Task { await store.send() } } label: {
                        Group { if store.busy { ProgressView() } else { Image(systemName: "arrow.up").fontWeight(.semibold) } }.frame(width: 44, height: 44)
                            .background(store.canSend ? NativeTheme.accent : NativeTheme.inactiveControl, in: Circle()).foregroundStyle(store.canSend ? NativeTheme.onAccent : NativeTheme.inactiveSymbol)
                    }.disabled(!store.canSend).accessibilityLabel("发送消息")
                }
            }.padding(10).background(NativeTheme.composer, in: RoundedRectangle(cornerRadius: 22)).overlay(RoundedRectangle(cornerRadius: 22).stroke(NativeTheme.border, lineWidth: 1))
        }.padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 10).background(NativeTheme.canvas)
            .onChange(of: store.draft) { _, _ in store.saveDraft() }
    }
}
enum AGYAttachmentPicker: String, Identifiable { case photos, files; var id: String { rawValue } }
struct AGYConfiguration: View {
    @EnvironmentObject private var store: AGYStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("1 · 选择模型") {
                    Picker("模型", selection: Binding(get: { store.baseModel }, set: { value in Task { await store.setModel(value) } })) {
                        ForEach(store.families) { family in Text(family.name).tag(family.id) }
                    }
                    Button { Task { await store.refreshModels() } } label: { HStack { Text("刷新可用模型"); if store.modelsLoading { ProgressView() } } }.disabled(store.modelsLoading)
                }.disabled(store.busy || store.selected?.running == true || !store.gatewayReady)
                Section("2 · 思考强度") {
                    if let family = store.currentFamily, family.efforts != [""] {
                        Picker("思考强度", selection: Binding(get: { store.effort }, set: { value in Task { await store.setThinking(value) } })) {
                            ForEach(family.efforts, id: \.self) { Text(AGYThinking.title($0)).tag($0) }
                        }.pickerStyle(.segmented)
                    } else { Text("当前模型未提供独立的思考强度选项").foregroundStyle(.secondary) }
                }.disabled(store.busy || store.selected?.running == true || !store.gatewayReady)
                Section("3 · 审批策略") {
                    Picker("审批策略", selection: Binding(get: { store.approvalMode }, set: { value in Task { await store.configure(permission: value) } })) {
                        if store.approvalMode == "legacy" { Text("旧版策略 · 请重新选择").tag("legacy") }
                        ForEach(AGYApprovalMode.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    Text(AGYApprovalMode(rawValue: store.approvalMode)?.detail ?? "旧会话尚未选择新版审批策略。").font(.footnote).foregroundStyle(.secondary)
                }.disabled(store.busy || store.selected?.running == true || !store.gatewayReady)
                Section("执行方式") {
                    Picker("执行方式", selection: Binding(get: { store.mode }, set: { value in Task { await store.configure(agentMode: value) } })) {
                        Text("先做计划").tag("plan"); Text("直接实施").tag("accept-edits")
                    }
                    Text("执行方式决定先计划还是直接工作；审批策略单独控制工具是否需要你确认。").font(.footnote).foregroundStyle(.secondary)
                }.disabled(store.busy || store.selected?.running == true || !store.gatewayReady)
                Section("工作空间") {
                    Picker("目录", selection: $store.cwd) { ForEach(store.roots, id: \.self) { Text($0).tag($0) } }
                    if store.selected != nil { Text("工作目录在新建会话时设置。").font(.footnote).foregroundStyle(.secondary) }
                }.disabled(store.selected != nil || store.busy)
                if !store.gatewayReady { Text("此服务器尚未启用新版账号与审批后端，见源码包中的部署说明。").foregroundStyle(.orange) }
            }.navigationTitle("模型与任务配置").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                .task { await store.refreshModels() }
        }
    }
}
struct AGYApprovalCard: View {
    let request: AGYApproval
    @EnvironmentObject private var store: AGYStore
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("等待审批 · " + request.tool, systemImage: "hand.raised.fill").font(.headline)
            if !request.parameters["CommandLine"].string.isEmpty {
                Text(request.parameters["CommandLine"].string).font(.system(.callout, design: .monospaced)).lineLimit(6).textSelection(.enabled)
            } else if let path = ["AbsolutePath", "TargetFile", "path", "Url"].map({ request.parameters[$0].string }).first(where: { !$0.isEmpty }) {
                Text(path).font(.callout).textSelection(.enabled)
            }
            Text("只有这一次操作会被批准，不会记住为始终允许。").font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("查看完整操作参数") { Text(request.parameters.pretty).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            Text("到期：" + Date(timeIntervalSince1970: request.expiresAt).formatted(date: .omitted, time: .standard)).font(.caption)
            HStack {
                Button("拒绝", role: .destructive) { Task { await store.answer(request, allow: false) } }.buttonStyle(.bordered)
                Spacer()
                Button("仅允许本次") { Task { await store.answer(request, allow: true) } }.buttonStyle(.borderedProminent)
            }.disabled(store.approvalBusy || request.expiresAt <= Date().timeIntervalSince1970)
        }.padding(16).background(NativeTheme.surface, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(.orange.opacity(0.6)))
    }
}
struct AGYHistory: View {
    @EnvironmentObject private var store: AGYStore
    @State private var search = ""
    @State private var renaming: AGYSession?
    @State private var newName = ""
    @State private var deleting: AGYSession?
    private var filtered: [AGYSession] { store.sessions.filter { search.isEmpty || $0.name.localizedStandardContains(search) || $0.cwd.localizedStandardContains(search) } }
    private var groups: [NativeSessionHistory.Group] {
        let formatter = ISO8601DateFormatter()
        let rows = filtered.map { PiSession(id: $0.id, cwd: $0.cwd, name: $0.name, firstMessage: nil, modified: formatter.string(from: Date(timeIntervalSince1970: $0.modified)), relation: nil) }
        return NativeSessionHistory.groups(rows)
    }
    var body: some View {
        NavigationStack {
            List {
                ForEach(groups) { group in
                    Section(group.title) {
                        ForEach(group.sessions) { entry in
                            if let s = filtered.first(where: { $0.id == entry.id }) {
                Button { Task { await store.select(s.id); store.tab = 0 } } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack { Text(s.name).font(.headline).foregroundStyle(.primary).lineLimit(2); if s.running { ProgressView().controlSize(.small) } }
                        Text(s.cwd).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Text(Date(timeIntervalSince1970: s.modified), style: .relative).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 5)
                }.swipeActions {
                    Button("删除", role: .destructive) { deleting = s }.disabled(s.running)
                    Button("重命名") { renaming = s; newName = s.name }.tint(.blue)
                }
                            }
                        }
                    }
                }
            }.navigationTitle("历史对话").searchable(text: $search, prompt: "搜索名称或目录").refreshable { await store.reload() }
                .overlay { if filtered.isEmpty { ContentUnavailableView("还没有对话", systemImage: "bubble.left.and.bubble.right", description: Text("在对话页发送第一条消息。")) } }
                .toolbar { Button { Task { await store.reload() } } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("刷新历史") }
                .alert("重命名", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                    TextField("名称", text: $newName)
                    Button("保存") { if let s = renaming { Task { await store.rename(s, name: newName) } }; renaming = nil }
                    Button("取消", role: .cancel) { renaming = nil }
                }
                .confirmationDialog("删除此对话？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                    Button("删除", role: .destructive) { if let s = deleting { Task { await store.delete(s) } }; deleting = nil }
                } message: { Text("删除 App 网关中的历史记录；不会删除 AGY 自己保存的原始会话。") }
        }
    }
}
struct AGYSettings: View {
    @EnvironmentObject private var store: AGYStore
    @State private var disconnect = false
    @AppStorage("nativeOutputMode") private var settingsOutputMode = NativeOutputMode.original.rawValue
    var body: some View {
        NavigationStack {
            Form {
                Section("服务器") {
                    LabeledContent("地址", value: store.storedURL).textSelection(.enabled)
                    LabeledContent("状态", value: store.connection)
                    ForEach(store.roots, id: \.self) { Text($0).font(.caption).textSelection(.enabled) }
                }
                Section { NavigationLink { AGYLimitsView() } label: { Label("账户额度", systemImage: "chart.bar") } }
                Section("输出展示") {
                    Picker("展示方式", selection: $settingsOutputMode) { ForEach(NativeOutputMode.allCases) { Text($0.title).tag($0.rawValue) } }
                    Text("步骤摘要和结论优先保留真实过程，随时可以展开。").font(.footnote).foregroundStyle(.secondary)
                }
                Section("账号") {
                    Text("Google 账号在服务器独立配置中登录；更换账号后会重新读取模型和额度，并隔离历史及草稿。").font(.footnote)
                }
                Section("关于") {
                    LabeledContent("版本", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                    Text("独立的原生 AGY 客户端，沿用 Pi iPhone 的聊天体验。Google 登录与任务运行在服务器上完成。").font(.footnote)
                    Text("App 会话由独立网关管理，当前不导入官方 Remote Control 的会话列表。切到后台后服务器任务继续，回到前台重新同步。").font(.footnote).foregroundStyle(.secondary)
                }
                Section { Button("断开并清除本机连接", role: .destructive) { disconnect = true } }
            }.navigationTitle("设置").confirmationDialog("断开连接？", isPresented: $disconnect, titleVisibility: .visible) {
                Button("断开连接", role: .destructive) { store.disconnect() }
            } message: { Text("服务器上的会话与正在执行的任务会保留。") }
        }
    }
}
