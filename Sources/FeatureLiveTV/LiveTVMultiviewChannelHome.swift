#if DEBUG
import CoreUI
import FeatureLiveTVCore
import SwiftUI

struct LiveTVMultiviewChannelSections {
    let recent: [LiveTVPrototypeChannel]
    let favorites: [LiveTVPrototypeChannel]
    let all: [LiveTVPrototypeChannel]

    init(channels: [LiveTVPrototypeChannel], favoriteIDs: Set<String>, recentChannelIDs: [String]) {
        var seen: Set<String> = []
        all = channels.filter { seen.insert($0.id).inserted }
        let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        seen.removeAll()
        recent = recentChannelIDs.filter { seen.insert($0).inserted }.compactMap { byID[$0] }
        favorites = all.filter { favoriteIDs.contains($0.id) }
    }
}

struct LiveTVMultiviewChannelHome: View {
    #if os(tvOS)
    static let pageInset: CGFloat = 80
    #else
    static let pageInset: CGFloat = 24
    #endif
    let channels: [LiveTVPrototypeChannel]
    let favoriteIDs: Set<String>
    let recentChannelIDs: [String]
    let selectedIDs: Set<String>
    var search: (() -> Void)?
    var cancel: (() -> Void)?
    let select: (LiveTVPrototypeChannel) -> Void
    @Environment(\.themePalette) private var palette
    @Namespace private var entryFocusScope

    var body: some View {
        let sections = LiveTVMultiviewChannelSections(
            channels: channels, favoriteIDs: favoriteIDs, recentChannelIDs: recentChannelIDs)
        let entry = [sections.recent, sections.favorites, sections.all]
            .enumerated().compactMap { index, channels in
                channels.first { !selectedIDs.contains($0.id) }.map { (index, $0.id) }
            }.first
        VStack(spacing: 0) {
            if let search, let cancel {
                HStack(spacing: 24) {
                    Text("Choose channel").font(.title2.bold())
                    Spacer()
                    Button("Search channels", systemImage: "magnifyingglass", action: search)
                        .plozzActionButton(role: .secondary)
                        .accessibilityIdentifier("live-multiview-channel-search")
                    Button("Cancel", systemImage: "xmark", action: cancel)
                        .plozzActionButton(role: .secondary)
                }
                .padding(.horizontal, Self.pageInset)
                .padding(.vertical, 24)
                #if os(tvOS)
                .focusSection()
                .padding(.top, 36)
                #endif
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 28) {
                        if !sections.recent.isEmpty {
                            LiveTVMultiviewChannelShelf(
                                title: "Recent channels", identifier: "recent", channels: sections.recent,
                                selectedIDs: selectedIDs, focusScope: entryFocusScope,
                                preferredID: entry?.0 == 0 ? entry?.1 : nil, select: select)
                                .id(0)
                        }
                        if !sections.favorites.isEmpty {
                            LiveTVMultiviewChannelShelf(
                                title: "Favorites", identifier: "favorites", channels: sections.favorites,
                                selectedIDs: selectedIDs, focusScope: entryFocusScope,
                                preferredID: entry?.0 == 1 ? entry?.1 : nil, select: select)
                                .id(1)
                        }
                        LiveTVMultiviewChannelShelf(
                            title: "All channels", identifier: "all", channels: sections.all,
                            selectedIDs: selectedIDs, focusScope: entryFocusScope,
                            preferredID: entry?.0 == 2 ? entry?.1 : nil, select: select)
                            .id(2)
                    }
                    .padding(.vertical, 28)
                }
                .task {
                    guard let entry else { return }
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    proxy.scrollTo(entry.0, anchor: .top)
                }
            }
        }
        .foregroundStyle(palette.primaryText)
        .background(palette.backgroundBase.ignoresSafeArea())
        #if os(tvOS)
        .focusScope(entryFocusScope)
        #endif
    }
}

private struct LiveTVMultiviewChannelShelf: View {
    let title: LocalizedStringKey
    let identifier: String
    let channels: [LiveTVPrototypeChannel]
    let selectedIDs: Set<String>
    let focusScope: Namespace.ID
    let preferredID: String?
    let select: (LiveTVPrototypeChannel) -> Void
    @Environment(\.plozzMetrics) private var metrics

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(PlozzRailTitle.font(sectionHeaderFontSize: metrics.sectionHeaderFontSize))
                .padding(.horizontal, LiveTVMultiviewChannelHome.pageInset)
                .accessibilityAddTraits(.isHeader)
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 20) {
                        ForEach(channels) { channel in
                            LiveTVMultiviewChannelCard(
                                channel: channel, isSelected: selectedIDs.contains(channel.id),
                                focusScope: focusScope, isPreferred: preferredID == channel.id,
                                select: { select(channel) })
                                .id(channel.id)
                        }
                    }
                    .padding(.horizontal, LiveTVMultiviewChannelHome.pageInset)
                    .padding(.vertical, 16)
                }
                .scrollIndicators(.hidden)
                .scrollClipDisabled()
                #if os(tvOS)
                .focusSection()
                #endif
                .task {
                    guard let preferredID else { return }
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    proxy.scrollTo(preferredID, anchor: .leading)
                }
            }
        }
        .accessibilityIdentifier("live-multiview-shelf-\(identifier)")
    }
}

private struct LiveTVMultiviewChannelCard: View {
    let channel: LiveTVPrototypeChannel
    let isSelected: Bool
    let focusScope: Namespace.ID
    let isPreferred: Bool
    let select: () -> Void
    @FocusState private var focused: Bool
    @Environment(\.plozzMetrics) private var metrics
    @Environment(\.plozzCardFocusStyle) private var focusStyle
    @Environment(\.plozzReduceTransparency) private var reduceTransparency

    private var surfaceFocused: Bool { focused && focusStyle.drawsFocusOutline }

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.landscapeCaptionTopSpacing) {
            ChannelLogoArtwork(
                name: channel.name, logoURL: channel.logoURL,
                size: CGSize(width: metrics.landscapeWidth, height: metrics.landscapeHeight),
                cornerRadius: PlozzTheme.Metrics.mediumMediaCornerRadius
            )
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.8))
                        .padding(12)
                }
            }
            Text(channel.name)
                .font(.system(size: metrics.cardTitleFontSize, weight: .semibold))
                .foregroundStyle(PlozzCardCaption.titleColor(
                    isFocused: surfaceFocused, reduceTransparency: reduceTransparency))
                .lineLimit(1)
                .padding(.horizontal, metrics.landscapeCaptionInset)
                .padding(.bottom, metrics.landscapeCaptionInset)
        }
        .frame(width: metrics.landscapeWidth)
        .plozzFramedMediaCard(
            innerCornerRadius: PlozzTheme.Metrics.mediumMediaCornerRadius, isFocused: surfaceFocused)
        .accessibilityElement(children: .ignore)
        .focusableCard(
            isFocused: $focused, cornerRadius: metrics.landscapeCardCornerRadius,
            isEnabled: !isSelected, action: select)
        .plozzCardFocusLift(
            isFocused: focused, cornerRadius: metrics.landscapeCardCornerRadius,
            outlineScale: PlozzTheme.Metrics.mediumFocusedCardScale)
        .plozzCardFocusTransition(isFocused: focused)
        #if os(tvOS)
        .prefersDefaultFocus(isPreferred, in: focusScope)
        .task(id: isPreferred) {
            guard isPreferred else { return }
            await Task.yield()
            guard !Task.isCancelled else { return }
            focused = true
        }
        #endif
        .accessibilityLabel(channel.name)
        .accessibilityValue(channel.category)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("live-multiview-channel-\(channel.id)")
        .disabled(isSelected)
    }
}
#endif
