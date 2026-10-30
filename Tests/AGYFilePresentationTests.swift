import Foundation

@main struct AGYFilePresentationTests {
    static func main() {
        precondition(AGYFilePresentation.label(scope: "workspace", folder: "资料", name: "合同 空格.pdf", directory: false) == "资料/合同 空格.pdf")
        precondition(AGYFilePresentation.label(scope: "workspace", folder: "项目", name: "src", directory: true) == "项目/src/")
        precondition(AGYFilePresentation.label(scope: "uploads", folder: "", name: "图片.png", directory: false) == "上传/图片.png")
        precondition(AGYFilePresentation.label(scope: "artifacts", folder: "", name: "结果.md", directory: false) == "产物/结果.md")
        precondition(AGYFilePresentation.opensMention(old: "分析 ", new: "分析 @"))
        precondition(!AGYFilePresentation.opensMention(old: "分析 @", new: "分析 @"))
        precondition(!AGYFilePresentation.opensMention(old: "", new: "abc@example.com"))
        print("File and directory mention presentation passed")
    }
}
