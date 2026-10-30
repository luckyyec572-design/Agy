import Foundation
@main struct NativeScrollPolicyTests {
    static func main() {
        var p = NativeScrollPolicy()
        precondition(p.mayFollow)
        p.beginGesture(); precondition(!p.mayFollow)
        p.endGesture(distance: 400); precondition(!p.mayFollow)
        // Idle refresh, disappearing lazy bottom marker, image decode, output
        // expansion, and keyboard resize must never re-enable a paused follow.
        for _ in 0..<100 { _ = NativeScrollPolicy.target(content: 8000, viewport: 300, top: 10, bottom: 34); precondition(!p.mayFollow) }
        p.beginGesture(); p.endGesture(distance: 20); precondition(p.mayFollow)
        p.beginGesture(); p.endGesture(distance: .nan); precondition(!p.mayFollow)
        p.returnToLatest(); precondition(p.mayFollow)
        precondition(NativeScrollPolicy.target(content: 100, viewport: 600, top: 20, bottom: 34) == -20)
        precondition(NativeScrollPolicy.target(content: 2000, viewport: 600, top: 20, bottom: 34) == 1434)
        p.beginGesture(); p.endGesture(distance: 1000); p.reset(); precondition(p.mayFollow)
        print("Passed scroll ownership, idle refresh, geometry and gesture policy checks")
    }
}
