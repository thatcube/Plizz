#if canImport(SwiftUI)
import SwiftUI

/// An opaque page can use an equivalent color fade instead of compositing the
/// whole backdrop through an alpha mask. Leave background nil for other surfaces.
@Animatable
public struct HeroBackdropDissolve: ViewModifier, Animatable {
    private var start: CGFloat
    @AnimatableIgnored private let background: Color?

    public init(start: CGFloat, background: Color? = nil) {
        self.start = start
        self.background = background
    }

    @ViewBuilder
    public func body(content: Content) -> some View {
        if let background {
            content
                .overlay(gradient(tone: background, keepsImage: false))
                // The old alpha mask also clipped video/UIView overdraw. Keep that
                // boundary even though a color overlay alone would not clip it.
                .clipped(antialiased: false)
        } else {
            content.mask(gradient(tone: .white, keepsImage: true))
        }
    }

    private func gradient(tone: Color, keepsImage: Bool) -> LinearGradient {
        let span = max(1 - start, 0.0001)
        let locations: [CGFloat] = [
            0, start, start + span * 0.32, start + span * 0.60, start + span * 0.83, 1
        ]
        let imageAlpha = [1.0, 1.0, 0.72, 0.36, 0.10, 0.0]
        return LinearGradient(
            stops: zip(locations, imageAlpha).map { location, alpha in
                .init(color: tone.opacity(keepsImage ? alpha : 1 - alpha), location: location)
            },
            startPoint: .top,
            endPoint: .bottom
        )
    }
}
#endif
