#if canImport(SwiftUI)
import SwiftUI

/// A shared, layout-visible lift driven by the caller's animation transaction.
public struct HomeVerticalMotion: ViewModifier {
    private let y: CGFloat

    public init(y: CGFloat) {
        self.y = y
    }

    public func body(content: Content) -> some View {
        content.offset(y: y)
    }
}
#endif
