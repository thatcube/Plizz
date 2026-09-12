#if canImport(SwiftUI)
import SwiftUI

public enum HomeAnimationComparison {
    public static let isolatesMotionTransactions =
        ProcessInfo.processInfo.environment["PLZHOME_ISOLATED_MOTION"] == "1"
}

public struct HomeVerticalMotion: ViewModifier {
    private let y: CGFloat
    private let duration: TimeInterval
    private let isolated: Bool

    public init(y: CGFloat, duration: TimeInterval, isolated: Bool) {
        self.y = y
        self.duration = duration
        self.isolated = isolated
    }

    @ViewBuilder
    public func body(content: Content) -> some View {
        if isolated {
            content
                .modifier(InterpolatedHomeOffset(y: y))
                .animation(.smooth(duration: duration), value: y)
        } else {
            content.offset(y: y)
        }
    }
}

@Animatable
private struct InterpolatedHomeOffset: ViewModifier, Animatable {
    var y: CGFloat

    func body(content: Content) -> some View {
        // Interpolate first: clearing a UIKit child's transaction around a plain
        // offset makes its placement snap directly to the target.
        content
            .transaction { $0.animation = nil }
            .offset(y: y)
    }
}
#endif
