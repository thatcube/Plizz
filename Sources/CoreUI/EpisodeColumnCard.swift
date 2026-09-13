#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import MetadataKit

/// The fixed standard-size, borderless episode column used only on series detail.
///
/// `Equatable` so callers can wrap it in `.equatable()`, and that is a measured
/// requirement rather than a nicety. The card stores its `action` closure, and
/// closures never compare equal, so SwiftUI's structural check on the view value
/// always failed: EVERY card in the rail re-evaluated its body whenever the
/// parent did. `Self._printChanges()` on an A12 Apple TV recorded 2550
/// `@self changed` rebuilds against only 141 real focus changes — an 18×
/// amplification — and most of them fired during hero transitions, when nothing
/// about any card had changed at all.
///
/// Comparing the inputs is sound because everything the card draws is derived
/// from them: `presentation` is built from exactly this pair, and the body's
/// remaining direct reads are all off `item`. Focus, the synopsis animation and
/// environment values are separate graph dependencies, so they still invalidate
/// the body normally — `.equatable()` only short-circuits the *value* check.
public struct EpisodeColumnCard: View, Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.item == rhs.item && lhs.spoilerSettings == rhs.spoilerSettings
    }

    public static let artworkSize = CGSize(width: 480, height: 270)
    public static let sideMargin: CGFloat = 8
    public static let slotWidth = artworkSize.width + sideMargin * 2

    private let item: MediaItem
    private let spoilerSettings: SpoilerSettings
    private let presentation: EpisodeColumnPresentation
    private let action: () -> Void

    @PlozzCardFocus private var isFocused: Bool
    #if os(tvOS)
    @State private var nativeArtwork = NativePosterArtworkState()
    #endif
    @State private var synopsisVisible = false
    @State private var synopsisAtRest = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.plozzWatchStatusIndicator) private var watchStatusIndicator
    @Environment(\.plozzCardFocusStyle) private var focusStyle
    @Environment(\.themePalette) private var palette

    private let metrics = PlozzMetrics.standard

    public init(
        item: MediaItem,
        spoilerSettings: SpoilerSettings = .default,
        action: @escaping () -> Void
    ) {
        self.item = item
        self.spoilerSettings = spoilerSettings
        self.presentation = EpisodeColumnPresentation(
            item: item,
            spoilerSettings: spoilerSettings
        )
        self.action = action
    }

    public var body: some View {
        let _ = plozzTraceBodyChanges { Self._printChanges() }
        VStack(alignment: .leading, spacing: 0) {
            episodeArtwork

            VStack(alignment: .leading, spacing: 0) {
                presentation.titleLine
                    .font(.system(size: metrics.cardTitleFontSize, weight: .semibold))
                    .foregroundStyle(presentation.isUpcoming ? .secondary : .primary)
                    .lineLimit(1)
                    .padding(.top, metrics.landscapeCaptionTopSpacing + metrics.focusCaptionPush)

                SpoilerSafeOverviewText(
                    overview: presentation.overviewTreatment == .blurred
                        ? item.overview
                        : presentation.visibleOverview,
                    hidesSpoilers: presentation.overviewTreatment == .blurred
                        || presentation.overviewTreatment == .placeholder,
                    mode: spoilerSettings.mode,
                    lineCount: 3,
                    fontSize: 20,
                    maxWidth: Self.artworkSize.width
                )
                .opacity(synopsisVisible ? 1 : 0)
                .animation(
                    reduceMotion ? nil : .easeOut(duration: 0.12),
                    value: synopsisVisible
                )
                .offset(y: reduceMotion || synopsisAtRest ? 0 : -metrics.focusCaptionPush)
                .animation(
                    reduceMotion ? nil : .smooth(duration: 0.28),
                    value: synopsisAtRest
                )
                .padding(.top, 10)
            }
            .offset(y: reduceMotion || focusStyle.usesSystemEffect || isFocused ? 0 : -metrics.focusCaptionPush)
        }
        .frame(width: Self.artworkSize.width, alignment: .leading)
        .padding(.horizontal, Self.sideMargin)
        .focusableCard(
            isFocused: $isFocused,
            cornerRadius: metrics.landscapeCardCornerRadius,
            nativeFocusInContent: true,
            action: action
        )
        .compositingGroup()
        .plozzCardFocusTransition(isFocused: isFocused, animates: !reduceMotion)
        .task(id: synopsisTaskID) {
            synopsisVisible = false
            synopsisAtRest = false
            guard isFocused else { return }
            if reduceMotion {
                synopsisVisible = true
                synopsisAtRest = true
                return
            }
            try? await Task.sleep(for: .milliseconds(110))
            guard !Task.isCancelled else { return }
            synopsisVisible = true
            synopsisAtRest = true
        }
        .mediaItemContextMenu(for: item)
        .environment(\.plozzCardStyle, .borderless)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
    }

    private var synopsisTaskID: SynopsisTaskID {
        SynopsisTaskID(isFocused: isFocused, reduceMotion: reduceMotion)
    }

    private struct SynopsisTaskID: Hashable {
        let isFocused: Bool
        let reduceMotion: Bool
    }

    @ViewBuilder
    private var episodeArtwork: some View {
        #if os(tvOS)
        if focusStyle.usesSystemEffect {
            nativeEpisodeArtwork
        } else {
            customEpisodeArtwork
        }
        #else
        customEpisodeArtwork
        #endif
    }

    private var customEpisodeArtwork: some View {
        artwork
            .frame(width: Self.artworkSize.width, height: Self.artworkSize.height)
            .saturation(presentation.isUpcoming ? 0 : 1)
            .opacity(presentation.isUpcoming ? 0.05 : 1)
            .background { if presentation.isUpcoming { palette.cardSurface } }
            .overlay { episodeOverlays }
            .plozzCardArtworkClip(RoundedRectangle(cornerRadius: metrics.landscapeCardCornerRadius, style: .continuous))
            .plozzMediaEdge(
                cornerRadius: metrics.landscapeCardCornerRadius,
                isEnabled: MediaArtworkPlaceholder.Symbol(for: item) == .playback
            )
            .plozzFocusHalo(
                cornerRadius: metrics.landscapeCardCornerRadius,
                focusScale: reduceMotion ? 1 : PlozzTheme.Metrics.mediumFocusedCardScale,
                isFocused: isFocused
            )
    }

    private var episodeOverlays: some View {
        ZStack {
            if presentation.isUpcoming, let air = item.upcomingReleaseText {
                Label(air, systemImage: "clock")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            if presentation.artworkTreatment != .blurred {
                ResumeChipOverlay(item: item).plozzChromeFocused(isFocused)
            }
        }
        .overlay(alignment: .topTrailing) { statusIndicator }
    }

    #if os(tvOS)
    private var nativeEpisodeArtwork: some View {
        let source = EpisodeArtworkSource(item: item, spoilerSettings: spoilerSettings)
        let treatment: NativePosterImageTreatment = presentation.isUpcoming
            ? .upcoming(palette.cardSurface)
            : (presentation.artworkTreatment == .blurred ? .blurred : .original)
        return NativeTVPoster(
            image: nativeArtwork.image, treatment: treatment,
            aspectRatio: Self.artworkSize.width / Self.artworkSize.height,
            fallbackWidth: Self.artworkSize.width, title: nil, subtitle: nil,
            overlay: episodeOverlays, focus: $isFocused, action: action
        )
        .focused($isFocused.focusState)
        .frame(width: Self.artworkSize.width, height: Self.artworkSize.height)
        .background {
            FallbackAsyncImage(
                references: source.references, variant: .landscapeCard,
                asyncFallbackURL: source.fallbackURL, pinIdentity: source.pinIdentity,
                content: { _ in Color.clear }, placeholder: { Color.clear }
            )
            .environment(\.nativePosterArtworkState, nativeArtwork)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
    }
    #endif

    @ViewBuilder
    private var artwork: some View {
        switch presentation.artworkTreatment {
        case .visible:
            realArtwork
        case .blurred:
            realArtwork.blur(radius: 28)
        case .placeholder:
            realArtwork
        }
    }

    private var realArtwork: some View {
        let source = EpisodeArtworkSource(item: item, spoilerSettings: spoilerSettings)
        return FallbackAsyncImage(
            references: source.references,
            variant: .landscapeCard,
            asyncFallbackURL: source.fallbackURL,
            pinIdentity: source.pinIdentity
        ) {
            neutralPlaceholder
        }
    }

    private var neutralPlaceholder: some View {
        MediaArtworkPlaceholder(symbol: .init(for: item), cornerRadius: metrics.landscapeCardCornerRadius)
    }

    @ViewBuilder
    private var statusIndicator: some View {
        // An unaired episode has no watch state to report, so neither the watched
        // tick nor the unwatched dot applies.
        if presentation.artworkTreatment == .visible, !presentation.isUpcoming {
            switch watchStatusIndicator {
            case .watched:
                if presentation.isWatched {
                    let size = metrics.watchedBadgeSize
                    Image(systemName: "checkmark")
                        .font(.system(size: size * 0.53, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: size, height: size)
                        .background(Circle().fill(ThemePalette.brandBlue))
                        .overlay {
                            Circle()
                                .inset(by: -0.5)
                                .stroke(
                                    palette.isLight ? .black.opacity(0.15) : .white.opacity(0.4),
                                    lineWidth: max(1.5, size * 0.04)
                                )
                        }
                        .padding(12)
                        .shadow(color: .black.opacity(0.4), radius: size * 0.08, y: size * 0.026)
                }
            case .unwatched:
                if !presentation.isWatched, presentation.progress == nil {
                    TopTrailingCornerFlag()
                        .fill(ThemePalette.brandBlue)
                        .shadow(color: .black.opacity(0.28), radius: 8)
                        .frame(width: metrics.unwatchedFlagSize, height: metrics.unwatchedFlagSize)
                }
            }
        }
    }
}
#endif
