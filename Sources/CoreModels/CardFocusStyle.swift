import Foundation

/// How a media card shows that it holds focus (pure data model).
///
/// A per-profile display preference that sits alongside `CardStyle`: it doesn't
/// change what a card looks like at rest, only what happens when focus lands on
/// it. Persisted **per profile** like `CardStyle` / `UIDensity`; the concrete
/// rendering lives in `CoreUI` (`plozzCardFocusLift`, `plozzFocusHalo`), so this
/// stays Foundation-only and the Settings screen can edit it without importing
/// SwiftUI.
///
/// Only the tvOS shell reads it — iOS has no focus engine — but it lives here
/// with every other card preference so the two shells share one settings model.
public enum CardFocusStyle: String, CaseIterable, Identifiable, Codable, Sendable {
    /// The platform owns projection, lighting, motion and accessibility behavior.
    case system
    /// Plozz's custom growth, specular sweep and arrival lean.
    case highlight
    /// A focused card lights its glass surface, and an artwork-only card blooms a
    /// glass halo around its edge.
    case outlined

    public var id: String { rawValue }

    /// Whether this style draws a focus outline (a glass frame or halo) at all.
    /// The single question every card asks, so no view has to switch on the case.
    public var drawsFocusOutline: Bool { self == .outlined }
    public var usesSystemEffect: Bool { self == .system }

    /// Short, user-facing option label for the Settings picker.
    public var displayName: LocalizedStringResource {
        switch self {
        case .system:
            return LocalizedStringResource(
                "cardFocusStyle.system",
                defaultValue: "System",
                comment: "Card focus-style option using the native tvOS focus effect, rather than Plozz's custom effects."
            )
        case .outlined:
            return LocalizedStringResource(
                "cardFocusStyle.outlined",
                defaultValue: "Outline",
                comment: "Card focus-style option in Settings > Appearance: the focused card is framed by a glass outline."
            )
        case .highlight:
            return LocalizedStringResource(
                "cardFocusStyle.highlight",
                defaultValue: "Highlight",
                comment: "Card focus-style option in Settings > Appearance: the focused card grows and catches the light instead of being outlined."
            )
        }
    }

    /// Tiny line shown beneath the picker, updated live as focus moves.
    public var detail: LocalizedStringResource {
        switch self {
        case .system:
            return LocalizedStringResource(
                "cardFocusStyle.detail.system",
                defaultValue: "Native Apple TV focus.",
                comment: "One-line explanation shown under the System card focus-style option. No claim of improved performance."
            )
        case .outlined:
            return LocalizedStringResource(
                "cardFocusStyle.detail.outlined",
                defaultValue: "Outlined in glass.",
                comment: "One-line explanation shown under the card focus-style picker."
            )
        case .highlight:
            return LocalizedStringResource(
                "cardFocusStyle.detail.highlight",
                defaultValue: "Grows and catches the light.",
                comment: "One-line explanation shown under the card focus-style picker."
            )
        }
    }

    /// Only an absent preference uses this default; saved custom styles stay intact.
    public static let `default`: CardFocusStyle = .system
}
