import Foundation
import ImageIO
import UniformTypeIdentifiers

enum NativePhotoEncoding {
    static func encode(_ url: URL, name: String?) throws -> ImportedAttachment {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2048,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw AttachmentImportError.unsupportedPhoto }
        let data = NSMutableData()
        guard let output = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { throw AttachmentImportError.unsupportedPhoto }
        CGImageDestinationAddImage(output, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(output) else { throw AttachmentImportError.unsupportedPhoto }
        let stem = ((name ?? "照片") as NSString).deletingPathExtension
        return ImportedAttachment(name: (stem.isEmpty ? "照片" : stem) + ".jpg", data: data as Data, mime: "image/jpeg")
    }
}
