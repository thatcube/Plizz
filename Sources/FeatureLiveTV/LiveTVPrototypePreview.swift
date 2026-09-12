#if DEBUG
import CoreUI
import FeatureLiveTVCore
import SwiftUI

struct PrototypePreviewLayout {
    let bounds: CGRect
    let contentFrame: CGRect
    let heroHeight: CGFloat
    let videoFrame: CGRect
    let fadeEnd: CGFloat
    let metadataWidth: CGFloat
    let compact: Bool

    var sidebarWidth: CGFloat {
        guard contentFrame.width >= 960,
              contentFrame.height - heroHeight - PrototypeLayout.sectionGap >= 420 else { return 0 }
        return contentFrame.width >= 1_400 ? 272 : 224
    }

    var guideWidth: CGFloat {
        contentFrame.width - (sidebarWidth > 0 ? sidebarWidth + PrototypeLayout.sectionGap : 0)
    }

    var guideBottomExtension: CGFloat {
        #if os(tvOS)
        max(0, bounds.maxY - contentFrame.maxY)
        #else
        0
        #endif
    }

    var guideTrailingExtension: CGFloat {
        #if os(tvOS)
        max(0, bounds.maxX - contentFrame.maxX)
        #else
        0
        #endif
    }

    init(
        size: CGSize, safeAreaInsets: EdgeInsets = EdgeInsets(),
        navigationInset: CGFloat = 0, largeText: Bool = false, isSearching: Bool = false
    ) {
        bounds = CGRect(
            x: -safeAreaInsets.leading, y: -safeAreaInsets.top,
            width: size.width + safeAreaInsets.leading + safeAreaInsets.trailing,
            height: size.height + safeAreaInsets.top + safeAreaInsets.bottom
        )
        compact = bounds.width < 650
        #if os(tvOS)
        let side: CGFloat = 32
        // The pinned rail's published inset is additional to the title-safe area.
        let leading = navigationInset > 0 ? max(side + PrototypeLayout.inset, safeAreaInsets.leading) : side
        let top = max(32, safeAreaInsets.top)
        let bottom: CGFloat = 20
        #else
        let side = max(16, max(safeAreaInsets.leading, safeAreaInsets.trailing))
        let leading = side
        let top = max(12, safeAreaInsets.top)
        let bottom = max(12, safeAreaInsets.bottom)
        #endif
        contentFrame = CGRect(
            x: bounds.minX + leading + navigationInset, y: bounds.minY + top,
            width: max(1, bounds.width - leading - side - navigationInset),
            height: max(1, bounds.height - top - bottom)
        )
        let browsingHeroHeight = min(
            contentFrame.height * (largeText ? 0.48 : 0.30),
            largeText ? 440 : (compact ? 220 : 300)
        )
        heroHeight = isSearching
            ? min(browsingHeroHeight, largeText ? 230 : (compact ? 140 : 180))
            : browsingHeroHeight
        metadataWidth = compact || largeText ? contentFrame.width : contentFrame.width * 0.56
        let videoWidth = bounds.width
        let videoHeight = videoWidth * 9 / 16
        videoFrame = CGRect(
            x: bounds.maxX - videoWidth,
            y: bounds.minY,
            width: videoWidth, height: videoHeight
        )
        fadeEnd = min(bounds.height * 0.82, videoHeight * 0.88)
    }
}

struct PrototypeGuidePlacement<Content: View>: View {
    let frame: CGRect
    let canvasWidth: CGFloat
    @ViewBuilder let content: () -> Content
    @Environment(\.layoutDirection) private var layoutDirection

    var body: some View {
        content()
            .frame(width: frame.width, height: frame.height)
            .position(
                x: layoutDirection == .rightToLeft ? canvasWidth - frame.midX : frame.midX,
                y: frame.midY
            )
    }
}

/// The player stays mounted beneath this scrim; watching only removes the guide.
struct PrototypePreviewScrim: View {
    let layout: PrototypePreviewLayout
    let reduceTransparency: Bool
    @Environment(\.themePalette) private var palette

    var body: some View {
        ZStack(alignment: .top) {
            HeroLegibilityScrim(
                tone: palette.backgroundBase, edgePeak: 0.96, wash: 0.08,
                edges: [.leading], bottomFadeTop: 0.3
            )
            VStack(spacing: 0) {
                LinearGradient(
                    stops: (0 ... 24).map { step in
                        let t = Double(step) / 24
                        return .init(color: palette.backgroundBase.opacity(t * t * (3 - 2 * t)), location: t)
                    },
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: layout.fadeEnd)
                palette.backgroundBase
            }
            if reduceTransparency {
                palette.backgroundBase
                    .frame(width: layout.metadataWidth + 48, height: layout.heroHeight)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, layout.contentFrame.minY - layout.bounds.minY)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct PrototypePreviewHero: View {
    let channel: LiveTVPrototypeChannel?
    let program: LiveTVPrototypeProgram?
    let layout: PrototypePreviewLayout
    let watch: () -> Void
    var watchTitle: LocalizedStringResource?
    @Environment(\.themePalette) private var palette
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: layout.compact ? PrototypeLayout.smallGap : PrototypeLayout.rowGap) {
            if let channel {
                HStack(spacing: PrototypeLayout.gap) {
                    PrototypeStationMark(channel: channel, size: layout.compact ? 48 : 72)
                    if program != nil { Text(channel.name).lineLimit(1) }
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(palette.secondaryText)
                Text(program?.title ?? channel.name)
                    .font((layout.compact ? Font.title2 : Font.title).weight(.semibold))
                    .lineLimit(2)
                HStack(spacing: PrototypeLayout.gap) {
                    Text(channel.category).lineLimit(1)
                    if let program {
                        Text(verbatim: "\(program.start.formatted(.dateTime.hour().minute().locale(locale))) – \(program.end.formatted(.dateTime.hour().minute().locale(locale)))")
                            .monospacedDigit().lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(palette.secondaryText)
                #if os(iOS)
                Button(action: watch) {
                    Label {
                        Text(watchTitle ?? "Watch channel")
                    } icon: {
                        Image(systemName: watchTitle == nil ? "arrow.up.left.and.arrow.down.right" : "rectangle.split.2x2")
                    }
                }
                    .font(.subheadline)
                    .plozzGlassPillButton()
                #endif
            } else {
                Text("Find your next channel")
                    .font(.title.weight(.semibold))
                Text("Browse by channel, genre or what's on.")
                    .font(.subheadline).foregroundStyle(palette.secondaryText)
            }
        }
        .frame(width: layout.metadataWidth, alignment: .leading)
        .frame(width: layout.contentFrame.width, height: layout.heroHeight, alignment: .bottomLeading)
        .clipped()
    }
}

struct PrototypeSearchSummary: View {
    let channelCount: Int
    let category: String?
    @Environment(\.themePalette) private var palette

    var body: some View {
        HStack(spacing: PrototypeLayout.smallGap) {
            Text("\(channelCount) channels")
            if let category {
                Text("in \(category)", comment: "Search summary: channels in the named category or genre. %@ is a category, not a time duration.")
            }
        }
        .font(.subheadline)
        .foregroundStyle(palette.secondaryText)
        .lineLimit(1)
    }
}

#endif
