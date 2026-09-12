#if canImport(UIKit)
import Foundation
import OSLog
import UIKit

/// Passive, opt-in geometry capture; never publishes SwiftUI state or steers scrolling.
@MainActor
public enum HomeMotionDiagnostics {
    private static let enabled = ProcessInfo.processInfo.environment["PLZHOME_MOTION_TRACE"] == "1"
    private static let recorder = Recorder()

    public static func register(_ view: UIView, role: String) {
        guard enabled else { return }
        recorder.register(view, role: role)
    }

    public static func transition(receding: Bool) {
        guard enabled else { return }
        recorder.transition(receding: receding)
    }

    private final class WeakView {
        weak var value: UIView?
        init(_ value: UIView) { self.value = value }
    }

    private struct Position: Encodable {
        let modelY: CGFloat
        let visibleY: CGFloat
        let height: CGFloat
        let visibleHeight: CGFloat
    }

    private struct Sample: Encodable {
        let time: TimeInterval
        let positions: [String: Position]
        let scrollOffset: CGFloat?
        let visibleScrollOffset: CGFloat?
        let contentHeight: CGFloat?
        let topInset: CGFloat?
    }

    private struct Event: Encodable {
        let time: TimeInterval
        let receding: Bool
    }

    private struct Capture: Encodable {
        let samples: [Sample]
        let events: [Event]
    }

    @MainActor
    private final class Recorder: NSObject {
        private let origin = CACurrentMediaTime()
        private var views: [String: WeakView] = [:]
        private weak var scrollView: UIScrollView?
        private var link: CADisplayLink?
        private var samples: [Sample] = []
        private var events: [Event] = []
        private var deadline: TimeInterval?
        private var finished = false

        func register(_ view: UIView, role: String) {
            views[role] = WeakView(view)
            guard link == nil, !finished else { return }
            let link = CADisplayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .common)
            self.link = link
        }

        func transition(receding: Bool) {
            guard !finished else { return }
            let now = CACurrentMediaTime() - origin
            events.append(Event(time: now, receding: receding))
            if deadline == nil { deadline = now + 20 }
        }

        @objc private func tick() {
            let now = CACurrentMediaTime() - origin
            var positions: [String: Position] = [:]
            for (role, reference) in views {
                guard let view = reference.value, let window = view.window else { continue }
                let layer = view.layer.presentation() ?? view.layer
                let windowLayer = window.layer.presentation() ?? window.layer
                let visible = layer.convert(layer.bounds, to: windowLayer)
                positions[role] = Position(
                    modelY: view.convert(view.bounds, to: window).minY,
                    visibleY: visible.minY, height: view.bounds.height,
                    visibleHeight: visible.height
                )
                if scrollView == nil {
                    var ancestor = view.superview
                    while let current = ancestor {
                        if let scroll = current as? UIScrollView,
                           scroll.contentSize.height > scroll.bounds.height,
                           scroll.contentSize.width <= scroll.bounds.width + 1 {
                            scrollView = scroll
                            break
                        }
                        ancestor = current.superview
                    }
                }
            }
            samples.append(Sample(
                time: now, positions: positions,
                scrollOffset: scrollView?.contentOffset.y,
                visibleScrollOffset: scrollView?.layer.presentation()?.bounds.minY,
                contentHeight: scrollView?.contentSize.height,
                topInset: scrollView?.adjustedContentInset.top
            ))
            if let deadline, now >= deadline {
                link?.invalidate()
                link = nil
                finished = true
                save()
            } else if deadline == nil, now >= 120 {
                link?.invalidate()
                link = nil
                finished = true
                Logger(subsystem: "com.plozz.app", category: "homeMotion")
                    .warning("Motion capture expired before a Home transition.")
                print("PLZMOTION ERROR no Home transition before capture deadline")
            } else if deadline == nil, samples.count > 180 {
                samples.removeFirst(samples.count - 180)
            }
        }

        private func save() {
            do {
                let url = URL.cachesDirectory.appendingPathComponent("plozz-home-motion.json")
                let data = try JSONEncoder().encode(Capture(samples: samples, events: events))
                try data.write(to: url, options: .atomic)
                print("PLZMOTION saved \(samples.count) samples, \(events.count) transitions")
            } catch {
                Logger(subsystem: "com.plozz.app", category: "homeMotion")
                    .error("Motion capture failed: \(error.localizedDescription, privacy: .public)")
                print("PLZMOTION ERROR \(error.localizedDescription)")
            }
        }
    }
}
#endif
