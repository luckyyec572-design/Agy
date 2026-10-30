import SwiftUI
import PhotosUI

struct AGYDraftAttachment: Identifiable {
    let id = UUID()
    let imported: ImportedAttachment
    var uploaded: AGYAttachment?
}

@MainActor final class AGYStore: ObservableObject {
    @Published var tab = 0
    @Published var connected = false
    @Published var busy = false
    @Published var sessions: [AGYSession] = []
    @Published var selected: AGYSession?
    @Published var models: [AGYModel] = []
    @Published var families: [AGYModelFamily] = []
    @Published var approvalMode = "review"
    @Published var gatewayReady = false
    @Published var approvalBusy = false
    @Published var accountProfile = ""
    @Published var roots: [String] = []
    @Published var cwd = ""
    @Published var model = ""
    @Published var mode = "plan"
    @Published var draft = ""
    @Published var error: String?
    @Published var connection = "尚未连接"
    @Published var pending: PendingSend?
    @Published var attachments: [AGYDraftAttachment] = []
    @Published var importing = false
    @Published var uploadProgress = ""
    @Published var limits: AGYLimits?
    @Published var limitsLoading = false
    @Published var limitsError: String?
    @Published var modelsLoading = false
    private(set) var attachmentContext = UUID()
    private(set) var api: AGYAPI?
    let cache = NativeCache()
    private var streamTask: Task<Void, Never>?
    private var epoch = UUID()
    private var selectionEpoch = UUID()
    private var foreground = true
    struct PendingSend: Codable {
        let sessionID: String
        let requestID: String
        let text: String
        var attachments: [String]?
    }
    var canSend: Bool { connected && gatewayReady && !busy && !importing && selected?.running != true && pending == nil && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty) }
    var currentFamily: AGYModelFamily? { families.first { $0.variants.contains { $0.id == model } } }
    var baseModel: String { currentFamily?.id ?? selected?.baseModel ?? model }
    var effort: String { currentFamily?.variants.first { $0.id == model }?.effort ?? selected?.effort ?? "" }
    var presentedMessages: [ChatMessage] { (selected?.messages ?? []).flatMap(\.presented) }
    var draftKey: String { "draft-" + (selected?.id ?? "new") }
    var storedURL: String {
        guard let data = SecureStore.read("connection"), let c = try? JSONDecoder().decode(AGYCredentials.self, from: data) else { return "" }
        return c.url.absoluteString
    }
    init() {
        draft = cache.read("draft-new", as: String.self) ?? ""
        sessions = cache.read("sessions", as: [AGYSession].self) ?? []
        if let data = SecureStore.read("pending-send") { pending = try? JSONDecoder().decode(PendingSend.self, from: data) }
    }
    func restore() async {
        guard let data = SecureStore.read("connection"), let c = try? JSONDecoder().decode(AGYCredentials.self, from: data) else { return }
        await connect(c)
    }
    func connect(_ credentials: AGYCredentials) async {
        epoch = UUID(); let token = epoch
        streamTask?.cancel(); api?.invalidate()
        let client = AGYAPI(credentials: credentials)
        api = client; busy = true; connection = "正在连接"; error = nil; connected = false
        defer { if epoch == token { busy = false } }
        do {
            let status: AGYStatus = try await client.json("status")
            let available: AGYModels = try await client.json("models")
            guard epoch == token else { return }
            guard status.version == 1, !available.models.isEmpty else { throw AGYError.message("服务器协议不兼容或没有可用模型") }
            roots = status.roots; cwd = roots.first ?? ""; models = available.models
            families = available.families ?? []
            gatewayReady = status.capabilities?.nativeApprovals == true && status.capabilities?.separateEffort == true
            let profile = credentials.url.absoluteString + "#" + (status.accountProfile ?? "legacy")
            if UserDefaults.standard.string(forKey: "activeAccountProfile") != profile {
                cache.clear(); sessions = []; selected = nil; draft = ""; attachments = []; pending = nil; limits = nil
                SecureStore.delete("pending-send"); attachmentContext = UUID()
                UserDefaults.standard.removeObject(forKey: "draft")
            }
            accountProfile = status.accountProfile ?? "legacy"
            UserDefaults.standard.set(profile, forKey: "activeAccountProfile")
            model = available.models.first(where: { $0.id == status.defaultModel })?.id ?? available.models[0].id
            guard SecureStore.write(try JSONEncoder().encode(credentials), account: "connection") else { throw AGYError.message("无法将连接信息保存到钥匙串") }
            connected = true; connection = "已就绪"
            if !gatewayReady { error = "请先部署本包新版后端并完成独立账号登录，才能使用模型/思考强度与原生审批。历史仍可查看。" }
            await reload()
            if let pending { await select(pending.sessionID) }
        } catch { if epoch == token { self.error = error.localizedDescription; connection = "连接失败" } }
    }
    func reload() async {
        guard let api else { return }
        let token = epoch
        do {
            let reply: AGYSessions = try await api.json("sessions")
            guard epoch == token else { return }
            sessions = reply.sessions
            cache.write(sessions, key: "sessions")
        } catch { if epoch == token { self.error = error.localizedDescription } }
    }
    func select(_ id: String) async {
        let switching = selected?.id != id
        if switching { saveDraft(); attachmentContext = UUID(); attachments = []; importing = false }
        selectionEpoch = UUID(); let token = selectionEpoch, account = epoch
        streamTask?.cancel()
        guard let api else { return }
        busy = true; error = nil
        if switching, let cached = cache.read("session-" + id, as: AGYSession.self) { selected = cached; connection = "显示本机缓存" }
        defer { if selectionEpoch == token { busy = false } }
        do {
            let s: AGYSession = try await api.json("sessions/\(id)")
            guard token == selectionEpoch, epoch == account else { return }
            selected = s; cwd = s.cwd; model = s.model; mode = s.mode
            approvalMode = s.approvalMode ?? "legacy"
            if switching { draft = cache.read(draftKey, as: String.self) ?? "" }
            cache.write(s, key: "session-" + id)
            reconcilePending(s)
            watch(id)
        } catch { if token == selectionEpoch { self.error = error.localizedDescription } }
    }
    func newConversation() {
        guard pending == nil else { error = "请先核对上一条发送结果。"; return }
        saveDraft(); selectionEpoch = UUID(); streamTask?.cancel(); selected = nil; error = nil; connection = "已就绪"
        draft = cache.read(draftKey, as: String.self) ?? ""
        if approvalMode == "legacy" { approvalMode = "review" }
        attachmentContext = UUID(); attachments = []; importing = false
    }
    private func reconcilePending(_ s: AGYSession) {
        if let p = pending, p.sessionID == s.id, s.messages?.contains(where: { $0.id == p.requestID }) == true {
            if draft == p.text { draft = ""; saveDraft() }
            pending = nil; SecureStore.delete("pending-send")
            attachments.removeAll { item in p.attachments?.contains(item.uploaded?.id ?? "") == true }
        }
    }
    func send() async {
        guard canSend, let api else { return }
        let textToSend = draft
        busy = true; error = nil
        let account = epoch, selection = selectionEpoch
        defer { if epoch == account, selection == selectionEpoch { busy = false } }
        do {
            if selected == nil {
                let s: AGYSession = try await api.json("sessions", method: "POST", body: .object(["cwd": .string(cwd), "baseModel": .string(baseModel), "effort": .string(effort), "mode": .string(mode), "approvalMode": .string(approvalMode)]))
                guard epoch == account, selection == selectionEpoch else { return }
                selected = s
            }
            guard let id = selected?.id else { return }
            for i in attachments.indices {
                if attachments[i].uploaded == nil {
                    uploadProgress = "正在上传 \(i + 1)/\(attachments.count)：\(attachments[i].imported.name)"
                    let uploaded = try await api.upload(attachments[i].imported, sessionID: id)
                    guard epoch == account, selection == selectionEpoch, selected?.id == id else { return }
                    attachments[i].uploaded = uploaded
                }
            }
            uploadProgress = ""
            let p = PendingSend(sessionID: id, requestID: UUID().uuidString.lowercased(), text: textToSend, attachments: attachments.compactMap { $0.uploaded?.id })
            guard SecureStore.write(try JSONEncoder().encode(p), account: "pending-send") else { throw AGYError.message("无法保存发送编号，消息尚未发送。") }
            pending = p
            try await submit(p, api: api, account: account)
        } catch { if epoch == account { uploadProgress = ""; self.error = pending == nil ? error.localizedDescription : "发送结果待确认。请核对会话，或使用相同编号重试。\n" + error.localizedDescription } }
    }
    private func submit(_ p: PendingSend, api: AGYAPI, account: UUID) async throws {
        let s: AGYSession = try await api.json("sessions/\(p.sessionID)/messages", method: "POST", body: .object(["text": .string(p.text), "requestID": .string(p.requestID), "attachments": .array((p.attachments ?? []).map { .string($0) })]))
        guard epoch == account else { return }
        reconcilePending(s)
        if selected?.id == s.id { selected = s; watch(s.id) }
        await reload()
    }
    func retryPending() async {
        guard let p = pending, let api, !busy else { return }
        busy = true; let account = epoch
        defer { if epoch == account { busy = false } }
        do { try await submit(p, api: api, account: account); error = nil }
        catch { if epoch == account { self.error = error.localizedDescription } }
    }
    func stop() async {
        guard let id = selected?.id, let api else { return }
        do { let _: AGYSession = try await api.json("sessions/\(id)/stop", method: "POST", body: .object([:])); await select(id) }
        catch { self.error = error.localizedDescription }
    }
    func add(_ imported: ImportedAttachment, context: UUID) throws {
        guard context == attachmentContext else { return }
        guard attachments.count < 8, attachments.reduce(0, { $0 + $1.imported.data.count }) + imported.data.count <= 50 * 1024 * 1024 else { throw AttachmentImportError.limit }
        guard imported.data.count <= NativeAttachmentReader.maxFileBytes else { throw AttachmentImportError.tooLarge }
        attachments.append(AGYDraftAttachment(imported: imported))
    }
    func importFiles(_ urls: [URL], context: UUID) async {
        guard context == attachmentContext else { return }
        importing = true
        defer { if context == attachmentContext { importing = false } }
        for url in urls {
            do { let item = try await Task.detached { try NativeAttachmentReader.read(url) }.value; try add(item, context: context) }
            catch { if context == attachmentContext { self.error = error.localizedDescription } }
        }
    }
    func importPhotos(_ photos: [PHPickerResult], context: UUID) async {
        guard context == attachmentContext else { return }
        importing = true
        defer { if context == attachmentContext { importing = false } }
        for photo in photos {
            do { let item = try await NativePhotoImport.load(photo); try add(item, context: context) }
            catch { if context == attachmentContext { self.error = error.localizedDescription } }
        }
    }
    func refreshModels() async {
        guard let api, !modelsLoading else { return }
        modelsLoading = true; let account = epoch
        defer { if account == epoch { modelsLoading = false } }
        do { let result: AGYModels = try await api.json("models", query: ["refresh": "1"]); if account == epoch { models = result.models; families = result.families ?? [] } }
        catch { if account == epoch { self.error = error.localizedDescription } }
    }
    func setModel(_ value: String) async {
        guard let family = families.first(where: { $0.id == value }) else { return }
        let level = family.efforts.contains(effort) ? effort : family.defaultEffort
        await configure(base: family.id, thinking: level)
    }
    func setThinking(_ value: String) async { await configure(thinking: value) }
    func configure(base: String? = nil, thinking: String? = nil, agentMode: String? = nil, permission: String? = nil) async {
        guard gatewayReady, !busy, selected?.running != true, pending == nil, let api else { return }
        let base = base ?? baseModel, level = thinking ?? effort
        guard let family = families.first(where: { $0.id == base }), let variant = family.variants.first(where: { $0.effort == level }) else { error = "此模型不支持所选思考强度"; return }
        let agent = agentMode ?? mode, approval = permission ?? approvalMode
        if selected == nil { model = variant.id; mode = agent; approvalMode = approval; return }
        guard let id = selected?.id else { return }
        let account = epoch
        busy = true
        defer { if account == epoch { busy = false } }
        do {
            let updated: AGYSession = try await api.json("sessions/\(id)", method: "PATCH", body: .object(["baseModel": .string(base), "effort": .string(level), "mode": .string(agent), "approvalMode": .string(approval)]))
            guard account == epoch, selected?.id == id else { return }
            selected = updated; model = updated.model; mode = updated.mode; approvalMode = updated.approvalMode ?? "legacy"; await reload()
        } catch { if account == epoch { self.error = error.localizedDescription } }
    }
    func answer(_ request: AGYApproval, allow: Bool) async {
        guard let api, selected?.id == request.sessionID, !approvalBusy else { return }
        approvalBusy = true; defer { approvalBusy = false }
        do {
            let updated: AGYSession = try await api.json("sessions/\(request.sessionID)/approvals/\(request.id)", method: "POST", body: .object(["decision": .string(allow ? "allow" : "deny")]))
            if selected?.id == updated.id, updated.revision >= (selected?.revision ?? 0) { selected = updated }
        } catch { self.error = error.localizedDescription }
    }
    func refreshLimits() async {
        guard let api, !limitsLoading else { return }
        limitsLoading = true; limitsError = nil; let account = epoch
        defer { if account == epoch { limitsLoading = false } }
        do { let result: AGYLimits = try await api.json("limits", query: ["refresh": "1"]); if account == epoch { limits = result } }
        catch { if account == epoch { limitsError = error.localizedDescription } }
    }
    func rename(_ s: AGYSession, name: String) async {
        guard let api else { return }
        do { let _: AGYSession = try await api.json("sessions/\(s.id)", method: "PATCH", body: .object(["name": .string(name)])); await reload(); if selected?.id == s.id { await select(s.id) } }
        catch { self.error = error.localizedDescription }
    }
    func delete(_ s: AGYSession) async {
        guard let api else { return }
        do { let _: WireValue = try await api.json("sessions/\(s.id)", method: "DELETE"); if selected?.id == s.id { newConversation() }; await reload() }
        catch { self.error = error.localizedDescription }
    }
    func watch(_ id: String) {
        streamTask?.cancel()
        guard let api, foreground else { return }
        let token = selectionEpoch, account = epoch
        streamTask = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                guard let self, self.selected?.id == id, self.epoch == account, self.selectionEpoch == token else { return }
                do {
                    self.connection = "正在同步"
                    try await api.events(id) { [weak self] snapshot in
                        guard let self, self.selected?.id == id, self.epoch == account, self.selectionEpoch == token,
                              snapshot.revision >= (self.selected?.revision ?? 0) else { return }
                        self.selected = snapshot; self.reconcilePending(snapshot)
                        self.cache.write(snapshot, key: "session-" + id)
                        self.connection = snapshot.approvals?.isEmpty == false ? "等待你审批" : snapshot.running ? "AGY 正在运行" : "已就绪"
                    }
                    failures = 0
                    if self.selected?.running != true { await self.reload(); return }
                } catch {
                    if Task.isCancelled { return }
                    failures += 1; self.connection = "连接中断 · 正在重连"
                    if failures >= 3 { self.error = error.localizedDescription }
                }
                do { try await Task.sleep(for: .seconds(min(10, 1 + failures * 2))) } catch { return }
            }
        }
    }
    func scene(_ phase: ScenePhase) {
        if phase == .background { foreground = false; streamTask?.cancel(); connection = "后台已暂停同步" }
        if phase == .active { foreground = true; if let id = selected?.id { Task { await select(id) } } else if connected { Task { await reload() } } }
    }
    func saveDraft() { cache.write(draft, key: draftKey) }
    func disconnect() {
        epoch = UUID(); selectionEpoch = UUID(); streamTask?.cancel(); api?.invalidate(); api = nil
        SecureStore.delete("connection"); SecureStore.delete("pending-send"); pending = nil
        connected = false; busy = false; sessions = []; selected = nil; draft = ""; saveDraft(); error = nil; connection = "尚未连接"
        attachmentContext = UUID(); attachments = []; importing = false; uploadProgress = ""; limits = nil; limitsLoading = false; modelsLoading = false
        cache.clear(); gatewayReady = false; families = []; accountProfile = ""; UserDefaults.standard.removeObject(forKey: "activeAccountProfile")
    }
}
