import Foundation

/// Phone labels never use the server's absolute path as display text.
enum AGYFilePresentation {
    static func label(scope: String, folder: String, name: String, directory: Bool) -> String {
        let relative = [folder, name].filter { !$0.isEmpty }.joined(separator: "/")
        let prefix = scope == "uploads" ? "上传/" : scope == "artifacts" ? "产物/" : ""
        return prefix + relative + (directory && !relative.hasSuffix("/") ? "/" : "")
    }
    static func opensMention(old: String, new: String) -> Bool {
        new.hasSuffix("@") && !old.hasSuffix("@")
    }
}
