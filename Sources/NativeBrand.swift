import SwiftUI

struct NativeAGYLogo: View {
    var size: CGFloat = 48
    var body: some View {
        Image("AntigravityMark").resizable().scaledToFit()
            .frame(width: size, height: size).accessibilityLabel("AGY")
    }
}
struct HistorySwipeExclusions: PreferenceKey {
    static var defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value.append(contentsOf: nextValue()) }
}
extension View {
    func reservesHorizontalSwipe() -> some View {
        background(GeometryReader { geometry in Color.clear.preference(key: HistorySwipeExclusions.self, value: [geometry.frame(in: .global)]) })
    }
}
