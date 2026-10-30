import Foundation

/// Geometry changes can request a follow, but only a USER gesture can change
/// whether we follow. In particular a missing lazy row is never a bottom signal.
struct NativeScrollPolicy {
    private(set) var follows = true
    private(set) var interacting = false
    var mayFollow: Bool { follows && !interacting }
    mutating func beginGesture() { interacting = true; follows = false }
    mutating func endGesture(distance: Double) { interacting = false; follows = distance.isFinite && distance <= 40 }
    mutating func returnToLatest() { interacting = false; follows = true }
    mutating func reset() { self = Self() }
    static func target(content: Double, viewport: Double, top: Double, bottom: Double) -> Double {
        max(-top, content - viewport + bottom)
    }
}
