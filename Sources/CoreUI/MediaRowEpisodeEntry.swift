import CoreModels
import SwiftUI

/// Opt-in episode-row entry. Ordinary Home and library rows keep native focus.
public struct MediaRowEpisodeEntry {
    public enum Phase: Equatable, Sendable {
        case loading
        case ready
        case empty
        case failed
    }

    public let phase: Phase
    public let isActive: Bool
    public let isEnabled: Bool
    public let onPlaceholderFocus: (@MainActor () -> Void)?
    public let onRetry: (@MainActor () -> Void)?

    public init(
        phase: Phase,
        isActive: Bool,
        isEnabled: Bool = true,
        onPlaceholderFocus: (@MainActor () -> Void)? = nil,
        onRetry: (@MainActor () -> Void)? = nil
    ) {
        self.phase = phase
        self.isActive = isActive
        self.isEnabled = isEnabled
        self.onPlaceholderFocus = onPlaceholderFocus
        self.onRetry = onRetry
    }
}

struct MediaRowEntryLayout: Equatable {
    struct Target: Equatable {
        let id: String
        let frame: CGRect
    }
    var target: Target?
    var viewportWidth: CGFloat?
}

struct MediaRowEntryLayoutKey: PreferenceKey {
    static let defaultValue = MediaRowEntryLayout()
    static func reduce(value: inout MediaRowEntryLayout, nextValue: () -> MediaRowEntryLayout) {
        let next = nextValue()
        if let target = next.target { value.target = target }
        if let width = next.viewportWidth { value.viewportWidth = width }
    }
}

enum MediaRowEpisodeEntryPolicy {
    static func targetReady(_ targetID: String?, layout: MediaRowEntryLayout) -> Bool {
        guard let targetID, let target = layout.target, target.id == targetID,
              let width = layout.viewportWidth, width > 0,
              !target.frame.isEmpty, !target.frame.isNull, !target.frame.isInfinite else { return false }
        return target.frame.minX >= -1 && target.frame.maxX <= width + 1
    }

    static func showsPlaceholder(
        phase: MediaRowEpisodeEntry.Phase, targetReady: Bool, focusEngaged: Bool
    ) -> Bool {
        phase != .ready || (!focusEngaged && !targetReady)
    }

    static func target(
        rememberedID: String?, defaultID: String?, itemIDs: Set<String>, firstID: String?
    ) -> String? {
        if let rememberedID, itemIDs.contains(rememberedID) { return rememberedID }
        if let defaultID { return itemIDs.contains(defaultID) ? defaultID : nil }
        return firstID
    }
}

struct EpisodeRowEntryPlaceholder: View {
    var phase: MediaRowEpisodeEntry.Phase = .loading
    var showsStatus = false
    var isFocused = false
    @Environment(\.themePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let metrics = PlozzMetrics.standard

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RoundedRectangle(cornerRadius: metrics.landscapeCardCornerRadius)
                // Like real artwork, the tile must hide the center of its
                // expanding focus halo rather than reveal a second surface.
                .fill(palette.cardOpaqueSurface)
                .frame(width: EpisodeColumnCard.artworkSize.width, height: EpisodeColumnCard.artworkSize.height)
                .plozzMediaEdge(cornerRadius: metrics.landscapeCardCornerRadius)
                .plozzFocusHalo(
                    cornerRadius: metrics.landscapeCardCornerRadius,
                    focusScale: reduceMotion ? 1 : PlozzTheme.Metrics.mediumFocusedCardScale,
                    isFocused: isFocused
                )
            VStack(alignment: .leading, spacing: 10) {
                Group {
                    if showsStatus {
                        switch phase {
                        case .loading, .ready:
                            Label("Loading episodes", systemImage: "hourglass")
                        case .empty:
                            Text("No episodes available")
                        case .failed:
                            Text("Unable to load episodes")
                        }
                    } else {
                        Capsule().fill(palette.fill).frame(width: 250, height: 20)
                    }
                }
                .font(.system(size: metrics.cardTitleFontSize, weight: .semibold))
                .foregroundStyle(palette.primaryText)
                .lineLimit(1)
                .frame(height: metrics.cardTitleFontSize * 1.25, alignment: .leading)
                Capsule().fill(palette.fill).frame(width: 440, height: 15)
                Capsule().fill(palette.fill).frame(width: 390, height: 15)
                Group {
                    if showsStatus && phase == .failed {
                        Label("Retry", systemImage: "arrow.clockwise")
                            .font(.system(size: 20))
                            .foregroundStyle(palette.secondaryText)
                    } else {
                        Capsule().fill(palette.fill).frame(width: 310, height: 15)
                    }
                }
                .frame(height: 24, alignment: .leading)
            }
            .padding(.top, metrics.landscapeCaptionTopSpacing + metrics.focusCaptionPush)
            .offset(y: reduceMotion || isFocused ? 0 : -metrics.focusCaptionPush)
        }
        .frame(width: EpisodeColumnCard.artworkSize.width, alignment: .leading)
        .padding(.horizontal, EpisodeColumnCard.sideMargin)
        .compositingGroup()
        .plozzCardFocusTransition(isFocused: isFocused, animates: !reduceMotion)
    }
}
