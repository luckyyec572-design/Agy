import SwiftUI
import UIKit

/// Single contentOffset writer for iOS 17+. No per-token scrollTo, lazy bottom
/// preference, or competing defaultScrollAnchor. UIKit reports gesture state.
struct NativeScrollFollow: UIViewRepresentable {
    let conversation: String
    let jump: Int
    @Binding var following: Bool
    func makeCoordinator() -> Coordinator { Coordinator(following: $following) }
    func makeUIView(context: Context) -> Probe {
        let probe = Probe()
        probe.isUserInteractionEnabled = false
        probe.moved = { [weak probe, weak coordinator = context.coordinator] in
            DispatchQueue.main.async { if let probe { coordinator?.attach(probe) } }
        }
        return probe
    }
    func updateUIView(_ view: Probe, context: Context) {
        let coordinator = context.coordinator
        coordinator.following = $following
        if coordinator.conversation != conversation {
            coordinator.conversation = conversation; coordinator.policy.reset(); coordinator.publish(); coordinator.schedule()
        }
        if coordinator.jump != jump {
            coordinator.jump = jump
            coordinator.ticker?.invalidate(); coordinator.ticker = nil
            if let scroll = coordinator.scroll { scroll.setContentOffset(scroll.contentOffset, animated: false) }
            coordinator.policy.returnToLatest(); coordinator.publish(); coordinator.schedule()
        }
        DispatchQueue.main.async { coordinator.attach(view) }
    }
    static func dismantleUIView(_ view: Probe, coordinator: Coordinator) { coordinator.detach() }
    final class Probe: UIView {
        var moved: (() -> Void)?
        override func didMoveToWindow() { super.didMoveToWindow(); if window != nil { moved?() } }
    }
    final class Coordinator: NSObject {
        var following: Binding<Bool>
        var conversation = ""
        var jump = 0
        var policy = NativeScrollPolicy()
        weak var scroll: UIScrollView?
        var observations: [NSKeyValueObservation] = []
        var ticker: CADisplayLink?
        var scheduled = false
        init(following: Binding<Bool>) { self.following = following }
        func attach(_ probe: UIView) {
            var candidate = probe.superview
            while candidate != nil && !(candidate is UIScrollView) { candidate = candidate?.superview }
            guard let found = candidate as? UIScrollView, found !== scroll else { return }
            detach(); scroll = found
            observations = [found.observe(\.contentSize, options: [.new]) { [weak self] _, _ in DispatchQueue.main.async { self?.schedule() } },
                            found.observe(\.bounds, options: [.old, .new]) { [weak self] _, change in
                                // bounds.origin changes while scrolling. Only a size
                                // change (keyboard/rotation) is a geometry follow.
                                if change.oldValue?.size != change.newValue?.size {
                                    DispatchQueue.main.async { self?.schedule() }
                                }
                            }]
            found.panGestureRecognizer.addTarget(self, action: #selector(panned))
            schedule()
        }
        func detach() {
            if let scroll { scroll.panGestureRecognizer.removeTarget(self, action: #selector(panned)) }
            observations.removeAll(); ticker?.invalidate(); ticker = nil; scroll = nil
        }
        @objc func panned(_ gesture: UIPanGestureRecognizer) {
            if gesture.state == .began {
                policy.beginGesture(); publish()
                ticker?.invalidate(); ticker = CADisplayLink(target: self, selector: #selector(tick))
                ticker?.preferredFramesPerSecond = 30; ticker?.add(to: .main, forMode: .common)
            }
        }
        @objc func tick() {
            guard let scroll else { ticker?.invalidate(); ticker = nil; return }
            guard !scroll.isTracking, !scroll.isDragging, !scroll.isDecelerating else { return }
            let target = NativeScrollPolicy.target(content: Double(scroll.contentSize.height), viewport: Double(scroll.bounds.height), top: Double(scroll.adjustedContentInset.top), bottom: Double(scroll.adjustedContentInset.bottom))
            policy.endGesture(distance: target - Double(scroll.contentOffset.y))
            publish(); ticker?.invalidate(); ticker = nil
            if policy.follows { schedule() }
        }
        func publish() {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.following.wrappedValue != self.policy.follows else { return }
                self.following.wrappedValue = self.policy.follows
            }
        }
        func schedule() {
            guard !scheduled else { return }; scheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }; self.scheduled = false
                guard let scroll = self.scroll, self.policy.mayFollow, !scroll.isTracking, !scroll.isDragging, !scroll.isDecelerating else { return }
                let y = NativeScrollPolicy.target(content: Double(scroll.contentSize.height), viewport: Double(scroll.bounds.height), top: Double(scroll.adjustedContentInset.top), bottom: Double(scroll.adjustedContentInset.bottom))
                if abs(Double(scroll.contentOffset.y)-y) > 1 { scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: CGFloat(y)), animated: false) }
            }
        }
    }
}
