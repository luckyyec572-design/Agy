import Foundation
import SwiftDraw

enum NativeSVGDocument {
    static func parse(_ data: Data) -> SVG? {
        guard data.count <= 2 * 1024 * 1024, let xml = String(data: data, encoding: .utf8) else { return nil }
        let lower = xml.lowercased()
        guard !lower.contains("<!doctype"), !lower.contains("<!entity"),
              !lower.contains("<script"), !lower.contains("<foreignobject") else { return nil }
        // The preview is self-contained. Do not let image/use nodes resolve
        // external or local-file resources from model-supplied markup.
        let pattern = #"(?:xlink:)?href\s*=\s*["']([^"']*)["']"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
            for match in regex.matches(in: xml, range: NSRange(xml.startIndex..., in: xml)) {
                guard let range = Range(match.range(at: 1), in: xml) else { continue }
                let target = String(xml[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !target.hasPrefix("#") && !target.hasPrefix("data:image/") { return nil }
            }
        }
        guard let svg = SVG(data: data), svg.size.width.isFinite, svg.size.height.isFinite,
              svg.size.width > 0, svg.size.height > 0 else { return nil }
        return svg.scaled(min(1, 1600 / max(svg.size.width, svg.size.height)))
    }
}
