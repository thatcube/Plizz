#if os(tvOS)
import SwiftUI
import CoreModels
import CoreUI
import FeatureProfiles

/// The container for ``NavigationStyle/rail``: the custom navigation rail on the
/// leading edge with the selected destination filling the rest of the screen.
///
/// Two layout rules make this feel right on a TV:
/// - the content clears the **collapsed** rail, while the expanded rail overlays
///   stationary content, so opening navigation never moves or relayouts a poster
///   grid mid-scroll; and
/// - the whole rail — and its inset — goes away while a detail page is pushed, so
///   a title page is full-bleed exactly as it is under the native chrome.
///
/// `Content` is a stored value, not a `@ViewBuilder` closure: the chrome model
/// this view observes ticks on every push/pop, and storing the built content means
/// the destination is handed back unchanged rather than rebuilt from scratch on
/// each of those ticks.
struct NavigationRailShell<Content: View>: View {
    let profile: Profile
    let entries: [NavigationRailLibraryEntry]
    let destinations: [NavigationRailDestination]
    @Binding var selection: NavigationRailDestination
    let onOpenProfileSwitcher: () -> Void
    let chrome: NavigationChromeModel
    let content: Content
    var preventsAccidentalExit: Bool = false

    /// Scopes appearance-time default focus so the CONTENT is focused first. Without
    /// it the rail — a stack of focusable rows sitting at the leading edge — can win
    /// the initial pick, which would open the navigation every time the app launches
    /// or the viewer switches destination.
    @Namespace private var focusScopeID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var pinnedSidebarInteraction = PlozzPinnedSidebarInteraction()
    /// Whether focus is inside the rail, reported up from it.
    @State private var railExpanded = false
    /// Bumped each time the catcher takes a Left press, so the rail claims focus.
    @State private var focusRequestToken = 0
    /// Bumped each time a Right press inside the rail resolves to nothing, so focus
    /// returns to the page.
    @State private var railReturnToken = 0
    @State private var isOpeningNavigation = false
    @State private var hasEnteredSearchContent = false

    var body: some View {
        let hidden = chrome.isChromeHidden
        let contentEntry = $hasEnteredSearchContent
        let presentation = NavigationRailPresentation(
            destination: selection,
            chromeHidden: hidden,
            isExpanded: railExpanded,
            isOpening: isOpeningNavigation
        )
        return ZStack(alignment: .leading) {
            content
                .background {
                    SearchPageFocusObserver(
                        isEnabled: presentation.shouldEnterSearchContent && !hasEnteredSearchContent,
                        onFocusEntered: { contentEntry.wrappedValue = true }
                    )
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
                // Native Search owns its navigation bar. Reserve actual container
                // space above it, rather than overlaying its field or keyboard.
                .padding(.top, presentation.headerHeight)
                // The rail makes room for itself by PUBLISHING an inset, never by
                // insetting this container.
                //
                // Insetting the container here — with padding or a safe area —
                // narrows the page as a whole, which drags the Home hero's
                // full-bleed artwork in with it and leaves a black band down the
                // side of the picture. Each surface instead applies this to its own
                // CONTENT (a row's cards, the hero's text column) and leaves its
                // artwork alone.
                .environment(
                    \.plozzNavigationContentInset,
                    presentation.contentInset
                )
                .environment(\.plozzPinnedSidebarActive, true)
                .environment(\.plozzPinnedSidebarInteraction, pinnedSidebarInteraction)
                // Reordering puts even Home and Settings inside the scroll view.
                // During explicit entry, only its revealed selected row may win
                // focus; restore directional access to the page once it arrives.
                .disabled(isOpeningNavigation)
                // Content is the scope's preferred focus ONLY while the rail does
                // not hold focus. Opening the rail changes its focusable subtree;
                // leaving this unconditional can re-assert content focus in the
                // same transaction and immediately close the rail again.
                .prefersDefaultFocus(!railExpanded && !isOpeningNavigation, in: focusScopeID)

            ZStack(alignment: .leading) {
                if presentation.showsPageButton {
                    PinnedSidebarPageButton(
                        title: NavigationRailView.searchTitle,
                        symbol: "magnifyingglass",
                        isNavigationExpanded: railExpanded || isOpeningNavigation,
                        isFocusEnabled: presentation.isPageButtonEnabled(
                            hasEnteredContent: hasEnteredSearchContent
                        ),
                        onOpenNavigation: requestNavigationFocus
                    )
                    .padding(.leading, NavigationRailMetrics.expandedContentHorizontalPadding)
                    .padding(.top, NavigationRailMetrics.pageButtonTopInset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .ignoresSafeArea(edges: .leading)
                }

                // Left opens unresolved result/page edges; Right returns from
                // navigation. Hero controls and the Search keyboard own their input.
                if !hidden {
                    NavigationRailEdgeCatcher(
                        onOpenNavigation: requestNavigationFocus,
                        onLeaveNavigation: { railReturnToken &+= 1 },
                        railHasFocus: railExpanded,
                        isEnabled: presentation.isEdgeNavigationEnabled(
                            searchResultsHaveFocus: pinnedSidebarInteraction.searchResultsHaveFocus
                        ) && !pinnedSidebarInteraction.heroHasFocus
                    )
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)

                    SearchBoundaryNavigationObserver(
                        isEnabled: presentation.shouldEnterSearchContent
                            && !pinnedSidebarInteraction.searchResultsHaveFocus,
                        onOpenNavigation: requestNavigationFocus
                    )
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }

                if !hidden {
                    NavigationRailView(
                        profile: profile,
                        entries: entries,
                        destinations: destinations,
                        selection: $selection,
                        isExpandedOutward: $railExpanded,
                        onOpenProfileSwitcher: onOpenProfileSwitcher,
                        focusRequestToken: focusRequestToken,
                        focusReleaseToken: railReturnToken,
                        opensExpanded: presentation.opensExpanded,
                        usesPageButtonSurface: presentation.showsPageButton,
                        onFocusRequestFailed: { token in
                            guard focusRequestToken == token else { return }
                            isOpeningNavigation = false
                        },
                        preventsAccidentalExit: preventsAccidentalExit
                    )
                    // Keep the focus-request observer mounted while Search hides
                    // the collapsed rail, but exclude invisible rows from focus.
                    .disabled(!presentation.isRailEnabled)
                    .opacity(presentation.isRailVisible ? 1 : 0)
                    .animation(
                        reduceMotion || presentation.isRailVisible ? nil : .easeInOut(duration: 0.22),
                        value: presentation.isRailVisible
                    )
                    .accessibilityHidden(!presentation.isRailEnabled)
                    .ignoresSafeArea(edges: .leading)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
            .backgroundPreferenceValue(NavigationGlassAnchors.self) { anchors in
                GeometryReader { geometry in
                    if let menu = anchors[.menu],
                       !geometry[menu].isEmpty,
                       !geometry[menu].isNull,
                       !geometry[menu].isInfinite {
                        NavigationGlassMorph(
                            buttonFrame: anchors[.button].map { geometry[$0] },
                            menuFrame: geometry[menu],
                            isExpanded: railExpanded || presentation.opensExpanded,
                            showsPageButton: presentation.showsPageButton
                        )
                    }
                }
            }
        }
        .focusScope(focusScopeID)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.26), value: hidden)
        .animation(reduceMotion ? nil : NavigationRailMetrics.expandAnimation, value: railExpanded)
        .onChange(of: selection, initial: true) { previous, destination in
            // The outgoing destination's stack is torn down without reporting, so
            // without this the rail would stay hidden after leaving a detail page
            // by switching destinations rather than by pressing Back.
            if previous != destination {
                chrome.resetForDestinationChange()
                isOpeningNavigation = false
                hasEnteredSearchContent = false
                pinnedSidebarInteraction.setSearchResultsFocused(false)
            }
        }
        .onChange(of: railExpanded) { _, _ in
            isOpeningNavigation = false
        }
        .onChange(of: hidden) { _, hidden in
            if hidden {
                isOpeningNavigation = false
                railExpanded = false
            }
        }
        .onChange(of: pinnedSidebarInteraction.openRequest) { _, _ in
            requestNavigationFocus()
        }
    }

    private func requestNavigationFocus() {
        guard !chrome.isChromeHidden, !isOpeningNavigation, !railExpanded else { return }
        hasEnteredSearchContent = false
        isOpeningNavigation = true
        focusRequestToken &+= 1
    }
}

struct NavigationRailPresentation: Equatable {
    let destination: NavigationRailDestination
    let chromeHidden: Bool
    let isExpanded: Bool
    let isOpening: Bool

    var usesPageButton: Bool { destination == .search }
    var showsPageButton: Bool { !chromeHidden && usesPageButton }
    // Only Search needs to reveal a previously invisible menu for entry.
    // A pinned rail expands when a row actually receives focus, not merely
    // because the page requested it.
    var opensExpanded: Bool { showsPageButton && isOpening }
    var shouldEnterSearchContent: Bool { showsPageButton && !isExpanded && !isOpening }
    func isEdgeNavigationEnabled(searchResultsHaveFocus: Bool = false) -> Bool {
        !chromeHidden && (
            !usesPageButton || isExpanded || (!isOpening && searchResultsHaveFocus)
        )
    }
    func isPageButtonEnabled(hasEnteredContent: Bool) -> Bool {
        shouldEnterSearchContent && hasEnteredContent
    }
    // UIKit cannot move focus into a fully transparent view. Reveal the rail
    // before its focus-request observer adopts the selected destination.
    var isRailVisible: Bool { !chromeHidden && (!usesPageButton || isExpanded || isOpening) }
    var isRailEnabled: Bool { isRailVisible }
    var headerHeight: CGFloat { showsPageButton ? NavigationRailMetrics.searchHeaderHeight : 0 }
    var contentInset: CGFloat {
        chromeHidden || usesPageButton ? 0 : NavigationRailMetrics.contentInset
    }
}
#endif
