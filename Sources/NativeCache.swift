import Foundation

struct NativeCachedConversation: Codable {
    var messages: [ChatMessage]
    var context: WireValue
}

@MainActor
final class NativeCache {
    private let folder: URL
    init() {
        folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NativeAGY", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var excluded = folder; var values = URLResourceValues(); values.isExcludedFromBackup = true; try? excluded.setResourceValues(values)
    }
    private func file(_ key: String) -> URL {
        // Encode the key, never interpret a server session id as a filesystem path.
        let name = Data(key.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
        return folder.appendingPathComponent(String(name.prefix(220)) + ".json")
    }
    func read<T: Decodable>(_ key: String, as: T.Type) -> T? { guard let data = try? Data(contentsOf: file(key)) else { return nil }; return try? JSONDecoder().decode(T.self, from: data) }
    func write<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: file(key), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func remove(_ key: String) { try? FileManager.default.removeItem(at: file(key)) }
    func clear() {
        for url in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] { try? FileManager.default.removeItem(at: url) }
    }
}
