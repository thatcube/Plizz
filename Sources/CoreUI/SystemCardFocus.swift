import CoreModels
import SwiftUI

public extension View {
    /// Apply to the focus owner; the projection itself belongs to its artwork.
    func plozzCardFocusEffect() -> some View {
        modifier(CardFocusEffectAvailability())
    }

    /// Native tvOS projection, outside the visual's clip/rasterization boundary.
    func plozzSystemCardProjection(cornerRadius: CGFloat) -> some View {
        #if os(tvOS)
        contentShape(.hoverEffect, RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .hoverEffect(.lift)
            // tvOS uses ButtonBorderShape for its projection plate, not just
            // the hover content shape (which alone leaves circular art square).
            .buttonBorderShape(.roundedRectangle(radius: cornerRadius))
        #else
        self
        #endif
    }

    func plozzRestingCardShadow(isFocused: Bool) -> some View {
        modifier(RestingCardShadow(isFocused: isFocused))
    }
}

private struct CardFocusEffectAvailability: ViewModifier {
    @Environment(\.plozzCardFocusStyle) private var style

    func body(content: Content) -> some View {
        content.focusEffectDisabled(!style.usesSystemEffect)
    }
}

private struct RestingCardShadow: ViewModifier {
    let isFocused: Bool
    @Environment(\.plozzCardFocusStyle) private var style

    func body(content: Content) -> some View {
        let customFocus = isFocused && !style.usesSystemEffect
        content.shadow(
            color: .black.opacity(customFocus ? 0.36 : 0.15),
            radius: customFocus ? 20 : 8,
            y: customFocus ? 10 : 4
        )
    }
}
