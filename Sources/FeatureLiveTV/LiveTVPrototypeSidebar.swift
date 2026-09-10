#if DEBUG
import CoreUI
import FeatureLiveTVCore
import SwiftUI

struct PrototypeBrowseSidebar: View {
    @Bindable var model: LiveTVPrototypeModel
    @Binding var active: Bool
    let focusRequest: Int
    var isSearching = false
    let search: () -> Void
    let enterGuide: () -> Void
    var multiviews: (() -> Void)?
    @FocusState private var focused: Control?
    @State private var categoryFade = PrototypeScrollFade()
    @ScaledMetric(relativeTo: .subheadline) private var fontSize = PrototypeLayout.guideFontSize
    @Environment(\.layoutDirection) private var layoutDirection

    private enum Control: Hashable {
        case search
        case multiviews
        case category(String?)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PrototypeLayout.gap) {
            Button(action: search) {
                Label(isSearching ? "Back to guide" : "Search", systemImage: isSearching ? "chevron.backward" : "magnifyingglass")
                    .frame(maxWidth: .infinity, minHeight: PrototypeLayout.controlHeight, alignment: .leading)
                    .padding(.horizontal, PrototypeLayout.gap)
            }
            .buttonStyle(PrototypeButtonStyle(padded: false, surface: .control))
            .focused($focused, equals: .search)
            .accessibilityValue(model.query)
            .accessibilityIdentifier("live-tv-search")
            .padding(PrototypeLayout.controlInset)
            .background { PrototypeControlSurface() }
            if let multiviews {
                Button("Multiviews", systemImage: "rectangle.split.2x2", action: multiviews)
                    .frame(maxWidth: .infinity, minHeight: PrototypeLayout.controlHeight, alignment: .leading)
                    .buttonStyle(PrototypeButtonStyle(surface: .control))
                    .focused($focused, equals: .multiviews)
                    .accessibilityIdentifier("live-tv-multiview-favorites")
            }

            ScrollView {
                LazyVStack(spacing: PrototypeLayout.smallGap) {
                    ForEach([nil] + model.categories.map(Optional.some), id: \.self) { category in
                        Button {
                            model.category = category
                        } label: {
                            HStack(spacing: PrototypeLayout.smallGap) {
                                if let category { Text(category) }
                                else { Text("All categories") }
                                Spacer(minLength: 0)
                                Image(systemName: "checkmark")
                                    .font(.caption)
                                    .opacity(model.category == category ? 1 : 0)
                                    .accessibilityHidden(true)
                            }
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, minHeight: PrototypeLayout.controlHeight, alignment: .leading)
                            .padding(.horizontal, PrototypeLayout.gap)
                        }
                        .buttonStyle(PrototypeButtonStyle(
                            padded: false, surface: .control
                        ))
                        .focused($focused, equals: .category(category))
                        .accessibilityAddTraits(model.category == category ? .isSelected : [])
                    }
                }
                .padding(.vertical, PrototypeLayout.smallGap)
            }
            .scrollIndicators(.hidden)
            .verticalEdgeFadeMask(
                fadeHeight: PrototypeLayout.verticalFade,
                topStrength: categoryFade.leading,
                bottomStrength: categoryFade.trailing
            )
            .onScrollGeometryChange(for: PrototypeScrollFade.self) { geometry in
                PrototypeScrollFade(
                    before: geometry.contentOffset.y + geometry.contentInsets.top,
                    after: geometry.contentSize.height - (geometry.contentOffset.y + geometry.containerSize.height)
                )
            } action: { _, fade in
                categoryFade = fade
            }
            .accessibilityIdentifier("live-tv-category-list")

        }
        .font(.system(size: fontSize, weight: .regular))
        .lineLimit(1)
        .focusEffectDisabled()
        #if os(tvOS)
        .focusSection()
        .onMoveCommand { direction in
            guard focused != nil else { return }
            if direction == (layoutDirection == .rightToLeft ? .left : .right) {
                enterGuide()
            }
        }
        #endif
        .onChange(of: focused) { _, target in
            if target != nil { active = true }
        }
        .onChange(of: focusRequest) { _, _ in focused = .search }
    }
}
#endif
