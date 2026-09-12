#if canImport(SwiftUI)
import SwiftUI
import CoreModels

/// The active profile's `CardFocusStyle`, injected into the SwiftUI environment
/// at the app root (see `RootView`) alongside `\.plozzCardStyle`. Every focusable
/// media card reads this so the selected effect follows the active profile.
private struct PlozzCardFocusStyleKey: EnvironmentKey {
    static let defaultValue: CardFocusStyle = .default
}

public extension EnvironmentValues {
    /// The live, per-profile System, custom Highlight or custom Outline effect.
    /// Set once at the app root; read by
    /// `plozzCardFocusLift`, `plozzCardFocusTransition` and `plozzFocusHalo`.
    var plozzCardFocusStyle: CardFocusStyle {
        get { self[PlozzCardFocusStyleKey.self] }
        set { self[PlozzCardFocusStyleKey.self] = newValue }
    }
}
#endif
