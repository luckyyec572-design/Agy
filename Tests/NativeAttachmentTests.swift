import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@main struct NativeAttachmentTests {
    static func main() throws {
        var checks = 0
        func check(_ value: Bool, _ label: String) { precondition(value, label); checks += 1 }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("中文 # +.txt")
        let bytes = Data("完整附件\nhello".utf8)
        try bytes.write(to: file)
        let read = try NativeAttachmentReader.read(file)
        check(read.name == file.lastPathComponent && read.data == bytes, "Coordinated read preserves filename and exact bytes")
        check(read.mime == "text/plain", "Document MIME type survives selection")
        let empty = directory.appendingPathComponent("empty.bin")
        try Data().write(to: empty)
        let emptyAttachment = try NativeAttachmentReader.read(empty)
        check(emptyAttachment.data.isEmpty, "Empty files are valid attachments")
        do { _ = try NativeAttachmentReader.read(directory); preconditionFailure("Folder must fail") }
        catch AttachmentImportError.folder { checks += 1 }
        let large = directory.appendingPathComponent("large.bin")
        FileManager.default.createFile(atPath: large.path, contents: nil)
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: UInt64(NativeAttachmentReader.maxFileBytes + 1)); try handle.close()
        do { _ = try NativeAttachmentReader.read(large); preconditionFailure("Oversize file must fail") }
        catch AttachmentImportError.tooLarge { checks += 1 }
        do { _ = try NativeAttachmentReader.read(directory.appendingPathComponent("missing")); preconditionFailure("Missing provider file must fail") }
        catch { checks += 1 }
        // Large camera image with EXIF rotation, using actual ImageIO encoding.
        let context = CGContext(data: nil, width: 3000, height: 1500, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 3000, height: 1500))
        let image = context.makeImage()!
        let photo = directory.appendingPathComponent("camera.jpg")
        let output = CGImageDestinationCreateWithURL(photo as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(output, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
        check(CGImageDestinationFinalize(output), "Photo fixture saved")
        let converted = try NativePhotoEncoding.encode(photo, name: "假日.heic")
        check(converted.name == "假日.jpg" && converted.mime == "image/jpeg", "Normalized name and image MIME")
        let source = CGImageSourceCreateWithData(converted.data as CFData, nil)!
        let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        check(decoded.width == 1024 && decoded.height == 2048, "Downsampling respects EXIF orientation and 2048px limit")
        try FileManager.default.removeItem(at: photo)
        check(CGImageSourceCreateWithData(converted.data as CFData, nil) != nil, "Imported image survives provider temporary URL removal")
        do { _ = try NativePhotoEncoding.encode(file, name: nil); preconditionFailure("Non-image must fail") }
        catch AttachmentImportError.unsupportedPhoto { checks += 1 }
        print("Passed \(checks) coordinated attachment and photo import checks")
    }
}
