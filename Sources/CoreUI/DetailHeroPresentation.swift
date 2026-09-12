import SwiftUI

/// Detail artwork occupies the top edge, including any inset contributed by navigation.
public struct DetailTopSafeAreaBreakout: ViewModifier {
    public init() {}

    public func body(content: Content) -> some View {
        // Native top tabs contribute more than the TV's overscan inset, even
        // while hiding. Let SwiftUI remove the actual inset, not a fixed 60pt.
        content.ignoresSafeArea(.container, edges: .top)
    }
}

/// Reveals the foreground without changing its layout or removing focus targets.
public struct DetailHeroContentReveal: ViewModifier {
    private let isVisible: Bool
    private let reduceMotion: Bool

    public init(isVisible: Bool, reduceMotion: Bool) {
        self.isVisible = isVisible
        self.reduceMotion = reduceMotion
    }

    public func body(content: Content) -> some View {
        content.mask {
            Rectangle()
                // Keep focused buttons' scale, shadow and halo outside the layout box.
                .padding(-600)
                .opacity(reduceMotion || isVisible ? 1 : 0)
                .animation(
                    reduceMotion ? nil : .easeOut(duration: 0.35).delay(0.08),
                    value: isVisible
                )
        }
    }
}
