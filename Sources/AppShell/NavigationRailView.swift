#if os(tvOS)
import SwiftUI
import CoreModels
import CoreUI
import FeatureProfiles

/// Fixed geometry for the custom navigation rail. Collected here so the shell's
/// content inset and the rail's own layout can never drift apart.
enum NavigationRailMetrics {
    /// How far a row's icon sits from the **physical** left edge of the screen.
    ///
    /// The rail deliberately breaks out of the tvOS title-safe area. That margin is
    /// the empty band down the side of the picture, and it is exactly where this
    /// navigation belongs — sitting inside the safe area instead put the icons on
    /// top of the page's own left-aligned content, which is what made the rail read
    /// as floating over the page rather than beside it.
    static let leadingInset: CGFloat = 28
    /// The icon column inside a row.
    static let iconColumnWidth: CGFloat = 42
    /// Total width of the collapsed rail, measured from the physical screen edge.
    static let collapsedWidth: CGFloat = leadingInset + iconColumnWidth + 18

    /// Extra inset applied to the page's content, ON TOP of the title-safe area it
    /// already respects.
    ///
    /// Small on purpose: the rail lives in the safe-area margin, so the page only
    /// has to give up the sliver where the two would otherwise touch. Applied as
    /// real padding rather than a safe-area inset because the Home hero sizes its
    /// foreground to the full screen width by design, and a safe-area inset leaves
    /// that column exactly where it was — under the icons.
    static let contentInset: CGFloat = 64
    static let searchHeaderHeight: CGFloat = 80
    static let pageButtonTopInset: CGFloat = 12

    /// Width the rail grows to once focus enters it.
    static let expandedWidth: CGFloat = 426
    /// Floating-menu geometry. The open panel sits 32 points from each physical
    /// screen edge. Row pills sit exactly 14 points inside every panel edge. The
    /// outer radius adds that same inset to the pill radius, keeping their corner
    /// centres concentric.
    static let expandedPanelOuterMargin: CGFloat = 32
    /// Device-calibrated correction between the panel's layout boundary and its
    /// visible glass edge.
    static let expandedPanelEdgeCompensation: CGFloat = 4
    static let expandedPanelLayoutInset: CGFloat =
        expandedPanelOuterMargin + expandedPanelEdgeCompensation
    static let expandedRowBackgroundOutset: CGFloat = 4
    static let expandedPanelContentInset: CGFloat = 14
    static let expandedContentHorizontalPadding: CGFloat =
        expandedPanelLayoutInset + expandedPanelContentInset + expandedRowBackgroundOutset
    static let expandedContentHorizontalOffset: CGFloat =
        expandedContentHorizontalPadding - leadingInset
    static let expandedTrailingPadding: CGFloat =
        expandedContentHorizontalPadding + expandedContentHorizontalOffset
    static func expandedPanelVerticalPadding(safeAreaInset: CGFloat) -> CGFloat {
        expandedPanelLayoutInset - safeAreaInset
    }
    static func expandedContentVerticalPadding(safeAreaInset: CGFloat) -> CGFloat {
        expandedPanelLayoutInset
            + expandedPanelContentInset
            - bumperHeight
            - itemVerticalPadding
            - safeAreaInset
    }
    static let rowInnerPadding: CGFloat = 10
    static let expandedRowHeight: CGFloat =
        rowContentHeight + (rowInnerPadding * 2)
    static let expandedRowCornerRadius: CGFloat =
        expandedRowHeight / 2
    /// Aligns the icon centre with the centre of the capsule's leading arc.
    static let rowHorizontalPadding: CGFloat =
        expandedRowCornerRadius - (iconColumnWidth / 2)
    static let expandedRowContentWidth: CGFloat =
        expandedWidth
            - leadingInset
            - expandedTrailingPadding
            - (rowHorizontalPadding * 2)
    static let expandedLabelOffset: CGFloat = iconColumnWidth + PlozzTheme.Spacing.medium
    static let expandedLabelWidth: CGFloat =
        expandedRowContentWidth - expandedLabelOffset
    static let expandedPanelCornerRadius: CGFloat =
        expandedRowCornerRadius + expandedPanelContentInset
    static let itemIconSize: CGFloat = 24
    static let labelFont: Font = .system(size: 25, weight: .semibold)
    static let itemSpacing: CGFloat = 10
    /// Two points on each row edge creates four points between adjacent items.
    static let itemVerticalPadding: CGFloat = 2
    /// Matches ``iconColumnWidth`` exactly. Any larger and the avatar overflows the
    /// glyph column it shares with every other row, so it sits off the axis the
    /// icons below it line up on — and steals from the gap before the label.
    static let avatarSize: CGFloat = iconColumnWidth
    /// Fixed height of a destination row's content, collapsed AND expanded.
    ///
    /// Without this a row was only as tall as what it contained, and a label is
    /// taller than a glyph — so every row grew on expand and the gaps between them
    /// visibly opened up (~11pt a row, which over a dozen libraries is a lot of
    /// drift). Pinning the height to the taller of the two states means rows are
    /// already the right size before focus arrives, and expanding changes width
    /// only.
    static let rowContentHeight: CGFloat = 44
    /// The profile is a navigation row too: avatar + one label, matching every
    /// destination's vertical rhythm.
    static let profileRowHeight: CGFloat = rowContentHeight
    static let verticalPadding: CGFloat = 14
    /// Height of the invisible focus walls at each end of the rail.
    ///
    /// They sit IN the stack, so whatever height they take pushes the profile down
    /// and Settings up by the same amount. Only enough is needed for the focus
    /// engine to find one directly beyond the end row — it picks the nearest
    /// candidate in the direction of travel, and nothing else is closer.
    static let bumperHeight: CGFloat = 10
    /// How far the destination list dissolves at its top and bottom edges. Roughly
    /// one row tall, so a row is fully gone by the time it reaches either edge.
    static let listEdgeFade: CGFloat = 44
    /// How far the fade mask overhangs the list horizontally, so a focused row's
    /// pill and its shadow are not clipped by the mask that feathers the ends.
    static let listFadeHorizontalOverhang: CGFloat = 40
    static let dividerHorizontalInset: CGFloat = 20
    static let expandAnimationDuration: Double = 0.22
    static let expandAnimation = Animation.easeOut(duration: expandAnimationDuration)
}

/// Plozz's own top-level navigation: a slim rail down the leading edge that shows
/// **icons only** until focus enters it, then expands over the content to reveal
/// every label.
///
/// Layout, top to bottom:
/// 1. the active profile's avatar — opens the existing profile switcher;
/// 2. every visible built-in and library destination in the viewer's chosen order,
///    scrolling as one list when there are many. Settings is required but may be
///    moved like every other visible destination.
///
/// Everything about the list is data: which libraries appear and in what order
/// comes from the profile's ``NavigationLibraryLayout``, so re-arranging is a value
/// change rather than a code change.
struct NavigationRailView: View {
    let profile: Profile
    let entries: [NavigationRailLibraryEntry]
    let destinations: [NavigationRailDestination]
    @Binding var selection: NavigationRailDestination
    /// Mirrors "focus is inside the rail" outward, so the shell can coordinate
    /// preferred focus and directional fallback while the overlay is open.
    @Binding var isExpandedOutward: Bool
    let onOpenProfileSwitcher: () -> Void
    /// Bumped by the shell when its leading-edge catcher takes a Left press, so the
    /// rail pulls focus onto the current destination.
    var focusRequestToken: Int = 0
    /// Bumped when a Right press inside the rail resolved to nothing, so the rail
    /// gives focus back to the page.
    var focusReleaseToken: Int = 0
    /// A page-button activation presents the full menu before focus arrives.
    var opensExpanded: Bool = false
    /// Search keeps full menu geometry while its shared surface morphs to a capsule.
    var usesPageButtonSurface: Bool = false
    var onFocusRequestFailed: (Int) -> Void = { _ in }
    var preventsAccidentalExit: Bool = false

    @Environment(\.themePalette) private var palette
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @Namespace private var railFocusScope
    @FocusState private var focusedTarget: RailFocusTarget?
    @State private var pendingFocusRequest: Int?
    @State private var pendingFocusTarget: RailFocusTarget?
    @State private var focusRequestGeneration = 0
    /// The last row that actually held focus, so an edge bumper can hand focus
    /// straight back to it.
    @State private var lastFocusedRow: RailFocusTarget?
    /// Makes every row unfocusable while focus is moving to the page. The rows stay
    /// unavailable until the next explicit request to open the rail, so a slow
    /// destination cannot let tvOS fall back into the menu.
    @State private var isReleasingFocus = false
    /// Continuously tracks how much content has moved past each edge, so the mask
    /// follows the scroll instead of flashing on at a threshold.
    @State private var libraryListFade = ListEdgeFade()
    /// Physical offset of the safe-area-constrained rail from the screen edge.
    /// Expanded geometry subtracts this instead of changing safe-area participation,
    /// which keeps every movement inside one smooth layout animation.
    @State private var physicalVerticalInset: CGFloat = 0
    /// One numeric clock drives every animated dimension. A focus change is
    /// discrete; using that Boolean directly let newly revealed labels jump to
    /// their final layout before the icons completed their movement.
    @State private var animatedExpansionProgress: CGFloat = 0

    private var expansionProgress: CGFloat {
        usesPageButtonSurface ? 1 : animatedExpansionProgress
    }

    /// Explicit page-button entry shows the full menu while focus catches up.
    private var isExpanded: Bool { hasFocus || opensExpanded }

    /// Whether focus is currently inside the rail.
    ///
    /// Drives which rows are focusable at all: see ``isRowFocusable(_:)``.
    private var hasFocus: Bool { focusedTarget != nil }

    private var animatedRailWidth: CGFloat {
        NavigationRailMetrics.collapsedWidth
            + (
                NavigationRailMetrics.expandedWidth - NavigationRailMetrics.collapsedWidth
            ) * expansionProgress
    }

    private var animatedVerticalPadding: CGFloat {
        NavigationRailMetrics.verticalPadding
            + (
                NavigationRailMetrics.expandedContentVerticalPadding(
                    safeAreaInset: physicalVerticalInset
                ) - NavigationRailMetrics.verticalPadding
            ) * expansionProgress
    }

    private var animatedRowContentWidth: CGFloat {
        NavigationRailMetrics.iconColumnWidth
            + (
                NavigationRailMetrics.expandedRowContentWidth
                    - NavigationRailMetrics.iconColumnWidth
            ) * expansionProgress
    }

    private var animatedContentOffset: CGFloat {
        NavigationRailMetrics.expandedContentHorizontalOffset * expansionProgress
    }

    private var animatedLabelOpacity: Double {
        Double(min(max(expansionProgress * 6, 0), 1))
    }

    /// Whether a row may hold focus right now.
    ///
    /// **From outside the rail, only the CURRENT destination is focusable.** That
    /// is what makes a Left press land on the tab you are actually on rather than
    /// on whichever row happens to sit nearest the card you came from. Steering
    /// focus by controlling what is focusable is the approach that works on tvOS;
    /// redirecting after the fact visibly flashes the wrong row first.
    ///
    /// Once focus is inside, everything opens up so Up/Down walk the whole rail.
    private func isRowFocusable(_ target: RailFocusTarget) -> Bool {
        // Handing focus back to the page: nothing in the rail may hold it.
        if isReleasingFocus { return false }
        if hasFocus { return true }
        return target == .destination(selection)
    }

    var body: some View {
        return VStack(alignment: .leading, spacing: 0) {
            // Invisible focus walls. Pressing Up from the top row (or Down from
            // Settings) must do NOTHING — the rail is a list you leave sideways,
            // not by falling out of either end. The focus engine will happily jump
            // to a page card that is merely near, so the reliable block is to give
            // it a nearer candidate inside the rail and hand focus straight back.
            // The bumper draws nothing, so the bounce is invisible: the row you
            // were on simply stays put.
            edgeBumper(.topBumper)

            profileButton
                .padding(.bottom, PlozzTheme.Spacing.large)

            destinationList

            edgeBumper(.bottomBumper)
        }
        .padding(.vertical, animatedVerticalPadding)
        .padding(.leading, NavigationRailMetrics.leadingInset)
        .padding(
            .trailing,
            NavigationRailMetrics.expandedTrailingPadding * expansionProgress
        )
        .frame(width: animatedRailWidth, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .onGeometryChange(for: CGFloat.self) { proxy in
            max(proxy.frame(in: .global).minY, 0)
        } action: { inset in
            physicalVerticalInset = inset
        }
        // The panel itself never carries a shadow: blurring a full-height surface
        // forces the whole rail subtree through an offscreen render on every frame.
        .background(alignment: .leading) { backdrop }
        // One focus section, so a Left press from the content lands in the rail as
        // a unit instead of picking whichever row happens to be geometrically
        // nearest, and a Right press returns to the content rather than walking
        // through every remaining rail row.
        .focusSection()
        .focusScope(railFocusScope)
        .tvNavigationExitProtection(
            isEnabled: preventsAccidentalExit,
            navigationHasFocus: hasFocus
        )
        .accessibilityLabel(Text(Self.accessibilityTitle))
        .onChange(of: isExpanded, initial: true) { _, expanded in
            withAnimation(NavigationRailMetrics.expandAnimation) {
                animatedExpansionProgress = expanded ? 1 : 0
            }
        }
        .onChange(of: hasFocus) { _, focused in
            isExpandedOutward = focused
            if !focused {
                pendingFocusRequest = nil
                pendingFocusTarget = nil
            }
        }
        .onDisappear {
            pendingFocusRequest = nil
            pendingFocusTarget = nil
            isExpandedOutward = false
        }
        // The shell's edge catcher took a Left press from the page. Claim focus for
        // the tab you are actually on — the catcher draws nothing, so nothing
        // flashes in between.
        .onChange(of: focusRequestToken) { _, _ in
            adoptFocus(.destination(selection))
        }
        // Right had nothing level with it to move to.
        .onChange(of: focusReleaseToken) { _, _ in
            releaseFocusToPage()
        }
        .onChange(of: focusedTarget) { _, target in
            switch target {
            case .topBumper, .bottomBumper:
                returnFromBumper()
            case .some(let row):
                lastFocusedRow = row
            case nil:
                break
            }
        }
    }

    /// A zero-chrome focus target at each end of the rail. It renders nothing, so
    /// landing on it and bouncing away is invisible.
    private func edgeBumper(_ target: RailFocusTarget) -> some View {
        // A bare focusable, not a Button: on tvOS a Button paints the system focus
        // platter behind its label and `.focusEffectDisabled()` does not fully
        // remove it, which flashed a white slab over the rail as focus passed
        // through. Same reason `CircularFocusTile` and the media cards avoid one.
        Color.clear
            .frame(height: NavigationRailMetrics.bumperHeight)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            // Only a wall while focus is actually inside the rail — otherwise it
            // would be one more thing competing to catch a Left press from the page.
            // It also stands down while focus is being handed BACK to the page: the
            // wall exists to stop focus falling out of the ENDS of the rail, not to
            // stop it leaving sideways, and catching it here trapped the hand-off.
            .focusable(hasFocus && !isReleasingFocus)
            .focusEffectDisabled()
            .focused($focusedTarget, equals: target)
            .accessibilityHidden(true)
    }

    /// Hands focus back to the page.
    ///
    /// Clearing `@FocusState` alone does NOT move focus. Nothing has become
    /// unfocusable, so the focus engine has no reason to run an update and simply
    /// leaves focus where it is — the row stays lit and the press appears to do
    /// nothing. (Pressing Right repeatedly eventually shook it loose, which is
    /// exactly what that looks like from the sofa.)
    ///
    /// Making every row unfocusable is what forces the issue: the engine cannot
    /// leave focus on an item that can no longer hold it, so it runs an update and
    /// re-homes focus. By then the rail has collapsed and the shell has marked the
    /// page as its focus scope's preferred target, so focus lands on the page's own
    /// default rather than somewhere arbitrary. The rows remain unavailable until
    /// the next explicit rail-open request. That matters when a library is still
    /// loading and has no focusable content yet: restoring them on a timer lets
    /// tvOS re-home focus back into the rail and reopen it.
    private func releaseFocusToPage() {
        pendingFocusRequest = nil
        pendingFocusTarget = nil
        isReleasingFocus = true
        focusedTarget = nil
    }

    /// Whether `target` is the row an edge bumper is currently bouncing focus back
    /// to, so it can keep its highlight for that one run-loop turn.
    private func isBouncingOffBumper(_ target: RailFocusTarget) -> Bool {
        guard focusedTarget == .topBumper || focusedTarget == .bottomBumper else {
            return false
        }
        return (lastFocusedRow ?? .destination(selection)) == target
    }

    /// Hands focus back to the row the viewer was on, so an Up/Down press at
    /// either end of the rail is a no-op rather than an exit.
    ///
    /// Deliberately no re-entrancy guard: the destination is never a bumper, so
    /// this cannot recurse — and a guard that latched would leave focus parked on
    /// an invisible row, which is the one outcome worse than the bounce itself.
    /// The hand-back waits a run-loop turn because assigning `@FocusState` from
    /// inside its own `onChange` is dropped (the same reason the reorder list
    /// restores focus after layout).
    private func returnFromBumper() {
        // Never bounce while handing focus to the page. Focus passing through a
        // bumper on its way OUT is the hand-off working; bouncing it back here is
        // what made Right from Home appear to do nothing — focus left the row,
        // landed on the wall, and was immediately returned to the rail.
        guard !isReleasingFocus else { return }
        adoptFocus(lastFocusedRow ?? .destination(selection))
    }

    /// The row's UIKit marker waits for its control to exist before handing off.
    private func adoptFocus(_ target: RailFocusTarget) {
        isReleasingFocus = false
        focusRequestGeneration &+= 1
        pendingFocusTarget = target
        pendingFocusRequest = focusRequestGeneration
    }

    private func focusRequester(for target: RailFocusTarget) -> some View {
        let requestState = $pendingFocusRequest
        let targetState = $pendingFocusTarget
        let shellRequest = focusRequestToken
        let onFailed = onFocusRequestFailed
        return NavigationRowFocusRequester(
            request: isEnabled && !isReleasingFocus && pendingFocusTarget == target
                ? pendingFocusRequest : nil,
            onCompleted: { request, didFocus in
                guard requestState.wrappedValue == request else { return }
                requestState.wrappedValue = nil
                targetState.wrappedValue = nil
                if !didFocus { onFailed(shellRequest) }
            }
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: - Pieces

    /// The complete viewer-arranged destination list. It is one scrollable block
    /// because built-ins may be interleaved with libraries, including moving
    /// Settings away from its historical bottom position.
    private var destinationList: some View {
        ScrollViewReader { proxy in
            scrollingDestinations
                .onChange(of: selection, initial: true) { _, destination in
                    reveal(destination, using: proxy)
                }
                .onChange(of: focusRequestToken) { _, _ in
                    reveal(selection, using: proxy)
                }
                .onChange(of: destinations) { _, _ in
                    if !hasFocus { reveal(selection, using: proxy) }
                }
                .onChange(of: pendingFocusTarget) { _, target in
                    if case let .destination(destination) = target {
                        reveal(destination, using: proxy)
                    }
                }
        }
    }

    private func reveal(_ destination: NavigationRailDestination, using proxy: ScrollViewProxy) {
        // Native focus discovery only sees rows inside the scroll viewport.
        // Reveal the selected row before its UIKit marker requests focus.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            proxy.scrollTo(destination, anchor: .center)
        }
    }

    private var scrollingDestinations: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: NavigationRailMetrics.itemSpacing) {
                ForEach(destinations, id: \.storageValue) { destination in
                    destinationItem(destination)
                        .id(destination)
                }
            }
        }
        .scrollIndicators(.hidden)
        // Takes whatever height is left beneath the fixed profile row.
        .frame(maxHeight: .infinity, alignment: .top)
        // The scroll view must NOT clip: a focused row's pill is wider than the
        // list (and carries a shadow), so the scroll view's own clip sheared its
        // right edge flat. Clipping is the mask's job instead — it cuts the ends
        // vertically, where rows would otherwise cover the chrome, while
        // overhanging horizontally so the pill stays whole.
        .scrollClipDisabled()
        // Rows must never be readable outside this list. The mask both clips and
        // feathers, so a row dissolves as it reaches either end instead of being
        // cut mid-glyph. It overhangs horizontally so a focused row's pill and
        // shadow stay intact.
        //
        // Each end fades in continuously as content travels beneath it. The mask
        // always keeps the same view structure and geometry, avoiding the flicker
        // caused by inserting/removing a gradient at a one-point threshold.
        .verticalEdgeFadeMask(
            fadeHeight: NavigationRailMetrics.listEdgeFade,
            topStrength: libraryListFade.top,
            bottomStrength: libraryListFade.bottom,
            horizontalOverhang: NavigationRailMetrics.listFadeHorizontalOverhang
        )
        .onScrollGeometryChange(for: ListEdgeFade.self) { geometry in
            let top = geometry.contentOffset.y + geometry.contentInsets.top
            let bottom = geometry.contentSize.height
                - (geometry.contentOffset.y + geometry.containerSize.height)
            return ListEdgeFade(
                top: ListEdgeFade.strength(for: top),
                bottom: ListEdgeFade.strength(for: bottom)
            )
        } action: { _, fade in
            libraryListFade = fade
        }
    }

    @ViewBuilder
    private func destinationItem(_ destination: NavigationRailDestination) -> some View {
        switch destination {
        case .home:
            item(.home, symbol: "house.fill", label: Text(Self.homeTitle))
        case .search:
            item(.search, symbol: "magnifyingglass", label: Text(Self.searchTitle))
        case .watchlist:
            item(.watchlist, symbol: "bookmark.fill", label: Text(Self.watchlistTitle))
        #if DEBUG
        case .liveTV:
            item(.liveTV, symbol: "antenna.radiowaves.left.and.right", label: Text(Self.liveTVTitle))
        #endif
        case .music:
            item(.music, symbol: "music.note", label: Text(Self.musicTitle))
        case .settings:
            item(.settings, symbol: "gearshape.fill", label: Text(Self.settingsTitle))
        case .allLibraries, .library:
            if let entry = entries.first(where: { $0.destination == destination }) {
                libraryItem(entry)
            }
        }
    }

    private func libraryItem(_ entry: NavigationRailLibraryEntry) -> some View {
        let symbol = entry.library?.library.navigationSymbolName ?? "square.stack.3d.up.fill"
        let label = entry.library?.library.displayName ?? Text(Self.allLibrariesTitle)
        return item(entry.destination, symbol: symbol, label: label)
    }

    private var profileButton: some View {
        Button(action: onOpenProfileSwitcher) {
            HStack(spacing: 0) {
                ProfileAvatarView(profile: profile, size: NavigationRailMetrics.avatarSize)
                    .frame(width: NavigationRailMetrics.iconColumnWidth)
                Spacer(minLength: 0)
            }
            .frame(height: NavigationRailMetrics.profileRowHeight)
            .frame(width: animatedRowContentWidth, alignment: .leading)
            .overlay(alignment: .leading) {
                railLabel(
                    Text(verbatim: profile.name),
                    color: foregroundColor(for: .profile, isSelected: false),
                    isFocused: focusedTarget == .profile
                )
                .frame(width: NavigationRailMetrics.expandedLabelWidth, alignment: .leading)
                .offset(x: NavigationRailMetrics.expandedLabelOffset)
                .opacity(animatedLabelOpacity)
            }
            .contentShape(Rectangle())
            .background { focusRequester(for: .profile) }
        }
        .focused($focusedTarget, equals: .profile)
        .prefersDefaultFocus(pendingFocusTarget == .profile, in: railFocusScope)
        .disabled(!isRowFocusable(.profile))
        .buttonStyle(
            NavigationRailItemStyle(
                expansionProgress: expansionProgress,
                isSelected: false,
                accent: palette.accent
            )
        )
        .padding(.vertical, NavigationRailMetrics.itemVerticalPadding)
        .offset(x: animatedContentOffset)
        .accessibilityLabel(Text(Self.switchProfileSubtitle))
        .accessibilityValue(Text(verbatim: profile.name))
    }

    private func item(
        _ destination: NavigationRailDestination,
        symbol: String,
        label: Text
    ) -> some View {
        Button {
            selection = destination
            // Activating a destination is the same commitment as selecting it and
            // pressing Right: close the menu and enter the page immediately.
            releaseFocusToPage()
        } label: {
            HStack(spacing: 0) {
                Image(systemName: symbol)
                    .font(.system(size: NavigationRailMetrics.itemIconSize, weight: .semibold))
                    .frame(width: NavigationRailMetrics.iconColumnWidth)
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
            }
            // The row is the SAME height in both states, so expanding does not
            // reflow the rail vertically. See `rowContentHeight`.
            .frame(height: NavigationRailMetrics.rowContentHeight)
            .frame(width: animatedRowContentWidth, alignment: .leading)
            .overlay(alignment: .leading) {
                railLabel(
                    label,
                    color: foregroundColor(
                        for: .destination(destination),
                        isSelected: selection == destination
                    ),
                    isFocused: focusedTarget == .destination(destination)
                )
                .frame(width: NavigationRailMetrics.expandedLabelWidth, alignment: .leading)
                .offset(x: NavigationRailMetrics.expandedLabelOffset)
                .opacity(animatedLabelOpacity)
            }
            .contentShape(Rectangle())
            .background { focusRequester(for: .destination(destination)) }
        }
        // UIKit owns explicit entry; the binding observes actual row focus.
        .focused($focusedTarget, equals: .destination(destination))
        .prefersDefaultFocus(
            pendingFocusTarget.map { $0 == .destination(destination) } ?? (destination == selection),
            in: railFocusScope
        )
        .disabled(!isRowFocusable(.destination(destination)))
        .buttonStyle(
            NavigationRailItemStyle(
                expansionProgress: expansionProgress,
                isSelected: selection == destination,
                accent: palette.accent,
                holdsFocusStyling: isBouncingOffBumper(.destination(destination))
            )
        )
        .padding(.vertical, NavigationRailMetrics.itemVerticalPadding)
        .offset(x: animatedContentOffset)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selection == destination ? [.isSelected] : [])
    }

    private func railLabel(_ text: Text, color: Color, isFocused: Bool) -> some View {
        PlozzMarqueeText(
            text: text,
            font: NavigationRailMetrics.labelFont,
            color: color,
            inset: 0,
            fadeWidth: 16,
            isFocused: isFocused
        )
    }

    private func foregroundColor(
        for target: RailFocusTarget,
        isSelected: Bool
    ) -> Color {
        let focused = focusedTarget == target || isBouncingOffBumper(target)
        if focused {
            return colorScheme == .dark ? .black : .white
        }
        return isSelected ? palette.accent : .primary
    }

    /// The rail's backing.
    ///
    /// The open rail uses the same floating glass surface as playback and source
    /// menus. Collapsed, there is no panel at all: the compact icon column remains
    /// directly over the page artwork.
    private var backdrop: some View {
        expandedBackdrop
            .opacity(Double(expansionProgress))
    }

    private var expandedBackdrop: some View {
        Color.clear
            .anchorPreference(key: NavigationGlassAnchors.self, value: .bounds) { [.menu: $0] }
            .padding(.horizontal, NavigationRailMetrics.expandedPanelLayoutInset)
            .padding(
                .vertical,
                NavigationRailMetrics.expandedPanelVerticalPadding(
                    safeAreaInset: physicalVerticalInset
                )
            )
            .allowsHitTesting(false)
    }

    // MARK: - Copy

    private static let homeTitle = LocalizedStringResource(
        "navigationRail.home",
        defaultValue: "Home",
        comment: "Navigation rail destination."
    )
    static let searchTitle = LocalizedStringResource(
        "navigationRail.search",
        defaultValue: "Search",
        comment: "Navigation rail destination."
    )
    private static let watchlistTitle = LocalizedStringResource(
        "navigationRail.watchlist",
        defaultValue: "Watchlist",
        comment: "Navigation rail destination for the user's universal Watchlist."
    )
    #if DEBUG
    private static let liveTVTitle = LocalizedStringResource(
        "navigationRail.liveTV",
        defaultValue: "Live TV",
        comment: "Development-only Live TV prototype navigation destination."
    )
    #endif
    private static let musicTitle = LocalizedStringResource(
        "navigationRail.music",
        defaultValue: "Music",
        comment: "Navigation rail destination."
    )
    private static let settingsTitle = LocalizedStringResource(
        "navigationRail.settings",
        defaultValue: "Settings",
        comment: "Navigation rail destination."
    )
    static let allLibrariesTitle = LocalizedStringResource(
        "navigationRail.allLibraries",
        defaultValue: "All Libraries",
        comment: "Navigation destination that browses every library at once."
    )
    private static let switchProfileSubtitle = LocalizedStringResource(
        "navigationRail.switchProfile",
        defaultValue: "Switch profile",
        comment: "Subtitle under the profile name in the navigation rail."
    )
    private static let accessibilityTitle = LocalizedStringResource(
        "navigationRail.accessibilityLabel",
        defaultValue: "Navigation",
        comment: "VoiceOver label for the app's left navigation rail."
    )
}

/// What can hold focus inside the rail. The profile row isn't a destination, so it
/// needs its own case rather than being folded into ``NavigationRailDestination``.
/// Normalized fade strength at each edge of the scrolling library list.
private struct ListEdgeFade: Equatable {
    var top: CGFloat = 0
    var bottom: CGFloat = 0

    static func strength(for overflow: CGFloat) -> CGFloat {
        let progress = min(max(overflow / NavigationRailMetrics.listEdgeFade, 0), 1)
        return progress * progress * (3 - 2 * progress)
    }
}

private enum RailFocusTarget: Hashable {
    case profile
    case destination(NavigationRailDestination)
    /// The invisible walls at each end that stop focus falling out of the rail.
    case topBumper
    case bottomBumper
}

/// Rail row chrome. Focus is the standard tvOS inverted card; the *selected*
/// destination keeps a quieter accent wash so you can still see where you are
/// while focus is out in the content.
private struct NavigationRailItemStyle: ButtonStyle {
    let expansionProgress: CGFloat
    let isSelected: Bool
    let accent: Color
    /// Keeps the row drawn as focused while an edge bumper briefly holds focus.
    ///
    /// Pressing Down on the last row must do NOTHING. The block works by giving
    /// the focus engine an invisible row to land on and handing focus straight
    /// back — but that round trip takes a run-loop turn, during which this row is
    /// genuinely unfocused and its highlight dropped. That flicker read as the row
    /// being re-focused on every press. Holding the highlight makes the bounce
    /// invisible, which is what "nothing happens" should look like.
    var holdsFocusStyling: Bool = false
    @Environment(\.isFocused) private var isFocused
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        let isFocused = isFocused || holdsFocusStyling
        let invertedFill: Color = colorScheme == .dark ? .white : .black
        let invertedText: Color = colorScheme == .dark ? .black : .white
        let foreground: AnyShapeStyle = isFocused
            ? AnyShapeStyle(invertedText)
            : AnyShapeStyle(isSelected ? AnyShapeStyle(accent) : AnyShapeStyle(.primary))
        let fill: AnyShapeStyle = isFocused
            ? AnyShapeStyle(invertedFill)
            : AnyShapeStyle(
                isSelected
                    ? accent.opacity(0.20)
                    : Color.clear
            )
        return configuration.label
            // Fixed content geometry keeps the icon perfectly still while the rail
            // expands. Matching insets around the square icon slot makes a circle.
            .padding(.leading, NavigationRailMetrics.rowHorizontalPadding)
            .padding(.trailing, NavigationRailMetrics.rowHorizontalPadding)
            .padding(.vertical, NavigationRailMetrics.rowInnerPadding)
            .foregroundStyle(foreground)
            // The rail sits over artwork, so an unfocused glyph carries its own
            // contrast while collapsed. The open menu panel supplies that contrast.
            .shadow(
                color: .black.opacity(
                    isFocused ? 0 : 0.85 * Double(1 - expansionProgress)
                ),
                radius: 5,
                y: 1
            )
            .background(
                Capsule(style: .continuous)
                    .fill(fill)
                    .padding(
                        .horizontal,
                        -NavigationRailMetrics.expandedRowBackgroundOutset
                            * expansionProgress
                    )
            )
    }
}
#endif
