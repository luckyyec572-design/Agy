import SwiftUI
import PhotosUI

struct AGYFiles: View {
    @EnvironmentObject private var store: AGYStore
    @Environment(\.dismiss) private var dismiss
    var picking = false
    @State private var scope = "workspace"
    @State private var path = ""
    @State private var listing: AGYFileListing?
    @State private var search = ""
    @State private var showHidden = false
    @State private var newest = false
    @State private var loading = false
    @State private var working = false
    @State private var status = ""
    @State private var issue: String?
    @State private var preview: PreviewDocument?
    @State private var picker: AGYAttachmentPicker?
    @State private var requestID = UUID()
    private var context: String { store.accountProfile + ":" + (store.selected?.id ?? "new") + ":" + store.cwd }
    private var visible: [AGYFileEntry] {
        (listing?.entries ?? []).filter {
            (showHidden || !$0.name.hasPrefix(".")) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search))
        }.sorted {
            if $0.directory != $1.directory { return $0.directory }
            return newest ? $0.modified > $1.modified : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("文件来源", selection: $scope) {
                        Text("工作区").tag("workspace")
                        Text("已上传").tag("uploads")
                        Text("AGY 产物").tag("artifacts")
                    }.pickerStyle(.segmented)
                    HStack {
                        Button("根目录", systemImage: "house") { path = ""; Task { await load() } }
                        if !path.isEmpty {
                            Button("上一级", systemImage: "arrow.up") {
                                path = path.split(separator: "/").dropLast().joined(separator: "/")
                                Task { await load() }
                            }
                        }
                        Spacer()
                        Menu {
                            Toggle("显示隐藏文件", isOn: $showHidden)
                            Toggle("最近修改优先", isOn: $newest)
                        } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
                    }
                    Text(path.isEmpty ? "当前工作区" : path + "/").font(.caption).foregroundStyle(.secondary)
                    if scope == "artifacts" { Text("这里显示 AGY 的会话产物；保存在项目里的结果请到“工作区”查看。").font(.caption).foregroundStyle(.secondary) }
                    if scope == "uploads" { Text("上传后可直接引用，不会自动发送任务。文件保留在当前会话的上传区。").font(.caption).foregroundStyle(.secondary) }
                    if scope == "workspace" {
                        Button("@ 引用整个当前文件夹") { referenceCurrentFolder() }
                            .disabled(listing == nil || working || store.busy || store.pending != nil)
                    }
                }
                if loading { ProgressView("正在读取文件…") }
                if working { ProgressView(status.isEmpty ? "正在处理…" : status) }
                if let issue { Section { Text(issue).foregroundStyle(.red); Button("重试") { Task { await load() } } } }
                if !loading, visible.isEmpty, issue == nil {
                    Text(search.isEmpty ? "这里还没有文件" : "没有匹配的文件").foregroundStyle(.secondary)
                }
                ForEach(visible) { entry in
                    HStack(spacing: 12) {
                        Button {
                            if entry.directory { enter(entry) } else { Task { await download(entry) } }
                        } label: {
                            HStack {
                                Image(systemName: entry.directory ? "folder.fill" : "doc")
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(entry.name).foregroundStyle(.primary).lineLimit(2)
                                    Text(entry.directory ? "文件夹" : ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if entry.directory { Image(systemName: "chevron.right").font(.caption) }
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Button { choose(entry) } label: { Text("@").font(.headline).frame(width: 44, height: 44) }
                            .buttonStyle(.borderless).accessibilityLabel(entry.directory ? "引用整个文件夹 " + entry.name : "引用文件 " + entry.name)
                            .disabled(store.busy || store.pending != nil || working)
                    }.contextMenu {
                        Button(entry.directory ? "@ 引用整个文件夹" : "@ 引用此文件") { choose(entry) }
                        if !entry.directory { Button("下载并预览", systemImage: "arrow.down.doc") { Task { await download(entry) } } }
                    }
                }
            }
            .disabled(working)
            .searchable(text: $search, prompt: "搜索当前文件夹")
            .navigationTitle(picking ? "@ 引用文件或文件夹" : "文件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("从文件上传", systemImage: "doc.badge.arrow.up") { picker = .files }
                        Button("从相册上传", systemImage: "photo") { picker = .photos }
                    } label: { Image(systemName: "plus") }.disabled(working || store.busy || store.pending != nil)
                }
                if picking { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
            }
            .refreshable { await load() }
            .task(id: context) { path = ""; listing = nil; await load() }
            .onChange(of: scope) { _, _ in path = ""; listing = nil; Task { await load() } }
            .sheet(item: $preview) { NativeDownloadedFile(url: $0.url) }
            .sheet(item: $picker) { selection in
                if selection == .files {
                    NativeDocumentPicker { urls in picker = nil; Task { await uploadFiles(urls) } }
                } else {
                    NativePhotoPicker(limit: 8) { photos in picker = nil; Task { await uploadPhotos(photos) } }
                }
            }
        }
    }
    private func enter(_ entry: AGYFileEntry) {
        path = [path, entry.name].filter { !$0.isEmpty }.joined(separator: "/")
        search = ""; Task { await load() }
    }
    private func choose(_ entry: AGYFileEntry) {
        let label = AGYFilePresentation.label(scope: scope, folder: path, name: entry.name, directory: entry.directory)
        store.reference(AGYFileEntry(name: label, path: entry.path, directory: entry.directory, size: entry.size, modified: entry.modified))
        if picking { dismiss() }
    }
    private func referenceCurrentFolder() {
        guard let listing, !listing.root.isEmpty else { return }
        let url = URL(fileURLWithPath: listing.root).appendingPathComponent(path)
        let entry = AGYFileEntry(name: path.isEmpty ? "工作区/" : path + "/", path: url.path, directory: true, size: 0, modified: 0)
        store.reference(entry)
        if picking { dismiss() }
    }
    @MainActor private func load() async {
        guard let api = store.api else { return }
        guard store.fileBrowserReady else { issue = "请配套部署本包 1.3.0 网关后，再使用文件管理和目录引用。"; return }
        let token = UUID(), original = context, source = scope, folder = path
        requestID = token; loading = true; issue = nil
        defer { if requestID == token { loading = false } }
        do {
            let result: AGYFileListing
            if let sid = store.selected?.id {
                result = try await api.json("sessions/\(sid)/entries", query: ["scope": source, "path": folder])
            } else if source == "workspace" {
                result = try await api.json("workspace", query: ["cwd": store.cwd, "path": folder])
            } else {
                listing = nil; return
            }
            guard requestID == token, context == original, scope == source, path == folder else { return }
            listing = result
        } catch { if requestID == token, context == original { listing = nil; issue = error.localizedDescription } }
    }
    @MainActor private func download(_ entry: AGYFileEntry) async {
        guard !working, let api = store.api else { return }
        working = true; status = "正在下载 " + entry.name; issue = nil
        let original = store.accountProfile
        defer { working = false }
        do {
            let sid = try await store.prepareFileSession()
            let result = try await api.download(entry.path, sessionID: sid, name: entry.name)
            guard original == store.accountProfile, store.selected?.id == sid else { return }
            preview = PreviewDocument(url: result)
        } catch { issue = error.localizedDescription }
    }
    @MainActor private func uploadFiles(_ urls: [URL]) async {
        await uploadBatch(count: urls.count) { index in try await Task.detached { try NativeAttachmentReader.read(urls[index]) }.value }
    }
    @MainActor private func uploadPhotos(_ photos: [PHPickerResult]) async {
        await uploadBatch(count: photos.count) { index in try await NativePhotoImport.load(photos[index]) }
    }
    @MainActor private func uploadBatch(count: Int, read: (Int) async throws -> ImportedAttachment) async {
        guard count > 0, !working, let api = store.api else { return }
        guard count <= 8 else { issue = AttachmentImportError.limit.localizedDescription; return }
        working = true; issue = nil
        let original = store.accountProfile
        defer { working = false; status = "" }
        var completed = 0
        do {
            let sid = try await store.prepareFileSession()
            for index in 0..<count {
                guard original == store.accountProfile, store.selected?.id == sid else { throw CancellationError() }
                status = "正在上传 \(index + 1)/\(count)"
                let attachment = try await read(index)
                guard original == store.accountProfile, store.selected?.id == sid else { throw CancellationError() }
                let _ = try await api.upload(attachment, sessionID: sid)
                completed += 1
            }
            guard original == store.accountProfile, store.selected?.id == sid else { return }
            scope = "uploads"; path = ""; await load()
        } catch {
            if original == store.accountProfile { scope = "uploads"; path = ""; await load(); issue = "已上传 \(completed)/\(count) 个文件。" + error.localizedDescription }
        }
    }
}

struct AGYWorkspacePicker: View {
    @EnvironmentObject private var store: AGYStore
    @Environment(\.dismiss) private var dismiss
    @State private var root = ""
    @State private var path = ""
    @State private var listing: AGYFileListing?
    @State private var issue: String?
    @State private var token = UUID()
    var body: some View {
        List {
            Picker("工作区", selection: $root) {
                ForEach(store.roots, id: \.self) { value in Text(URL(fileURLWithPath: value).lastPathComponent).tag(value) }
            }
            Text(path.isEmpty ? "工作区" : path + "/").font(.caption).foregroundStyle(.secondary)
            if !path.isEmpty { Button("上一级") { path = path.split(separator: "/").dropLast().joined(separator: "/"); Task { await load() } } }
            Button("使用此文件夹") {
                guard let listing, store.selected == nil else { return }
                store.cwd = URL(fileURLWithPath: listing.root).appendingPathComponent(listing.path).path
                store.references = []; store.saveDraft()
                dismiss()
            }.disabled(listing == nil || store.selected != nil)
            if let issue { Text(issue).foregroundStyle(.red); Button("重试") { Task { await load() } } }
            ForEach((listing?.entries ?? []).filter(\.directory)) { entry in
                Button { path = [path, entry.name].filter { !$0.isEmpty }.joined(separator: "/"); Task { await load() } } label: { Label(entry.name, systemImage: "folder") }
            }
        }.navigationTitle("选择项目文件夹")
            .task { root = store.roots.first ?? ""; await load() }
            .onChange(of: root) { _, _ in path = ""; Task { await load() } }
    }
    @MainActor private func load() async {
        guard let api = store.api, !root.isEmpty else { return }
        let current = UUID(); token = current; listing = nil; issue = nil
        do {
            let result: AGYFileListing = try await api.json("workspace", query: ["cwd": root, "path": path])
            if token == current { listing = result }
        } catch { if token == current { issue = error.localizedDescription } }
    }
}
