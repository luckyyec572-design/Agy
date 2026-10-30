// Standard app-icon packaging of the original Google Press Assets PNG.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = root.appendingPathComponent("Brand/antigravity-icon__full-color.png")
guard let input = CGImageSourceCreateWithURL(source as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(input, 0, nil) else { fatalError("Official PNG could not be decoded") }
guard let context = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8,
                              bytesPerRow: 1024 * 4, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { fatalError("RGB icon canvas could not be allocated") }
context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
context.interpolationQuality = .high
context.draw(image, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
guard let icon = context.makeImage() else { fatalError("Icon rendering failed") }
let output = root.appendingPathComponent("Sources/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else { fatalError("Icon output could not be created") }
CGImageDestinationAddImage(destination, icon, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("Icon encoding failed") }
try FileManager.default.createDirectory(at: root.appendingPathComponent("dist"), withIntermediateDirectories: true)
try Data(contentsOf: output).write(to: root.appendingPathComponent("dist/official-icon.png"))
print("Packaged original Google Antigravity mark: 1024×1024 RGB, opaque white background")
