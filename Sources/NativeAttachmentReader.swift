import Foundation
import UniformTypeIdentifiers

struct ImportedAttachment {
    let name: String
    let data: Data
    let mime: String
}

enum AttachmentImportError: LocalizedError {
    case tooLarge, folder, unreadable, unsupportedPhoto, limit
    var errorDescription: String? {
        switch self {
        case .tooLarge: return "文件超过 25 MB，请选择较小的文件。"
        case .folder: return "请选择文件；文件夹请先压缩后添加。"
        case .unreadable: return "无法读取此文件，请确认云端文件已下载后重试。"
        case .unsupportedPhoto: return "无法读取此照片，请选择其他照片或从文件添加。"
        case .limit: return "最多 8 个附件，单个不超过 25 MB，合计不超过 50 MB。"
        }
    }
}

enum NativeAttachmentReader {
    static let maxFileBytes = 25 * 1024 * 1024
    static func read(_ url: URL) throws -> ImportedAttachment {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        // File providers (including iCloud Drive) must materialize a coordinated
        // local copy before we read it. Keep scope alive throughout this read.
        var coordinationError: NSError?
        var result: Result<ImportedAttachment, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readable in
            result = Result {
                let values = try readable.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentTypeKey])
                guard values.isDirectory != true else { throw AttachmentImportError.folder }
                guard (values.fileSize ?? 0) <= maxFileBytes else { throw AttachmentImportError.tooLarge }
                guard let stream = InputStream(url: readable) else { throw AttachmentImportError.unreadable }
                stream.open(); defer { stream.close() }
                var data = Data()
                let chunkSize = 64 * 1024
                var buffer = [UInt8](repeating: 0, count: chunkSize)
                while true {
                    let count = stream.read(&buffer, maxLength: chunkSize)
                    guard count >= 0 else { throw stream.streamError ?? AttachmentImportError.unreadable }
                    if count == 0 { break }
                    guard data.count + count <= maxFileBytes else { throw AttachmentImportError.tooLarge }
                    data.append(contentsOf: buffer.prefix(count))
                }
                let mime = values.contentType?.preferredMIMEType
                    ?? UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                return ImportedAttachment(name: url.lastPathComponent, data: data, mime: mime)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw AttachmentImportError.unreadable }
        return try result.get()
    }
}
