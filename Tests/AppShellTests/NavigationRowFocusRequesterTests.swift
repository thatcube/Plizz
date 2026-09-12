#if os(tvOS)
import XCTest
import UIKit
import SwiftUI
import CoreModels
@testable import AppShell

@MainActor
final class NavigationRowFocusRequesterTests: XCTestCase {
    func testOpeningLongNavigationRevealsSelectedSettingsBeforeNativeFocus() async throws {
        let profile = Profile(name: "Viewer")
        let entries = (0..<30).map { index in
            NavigationRailLibraryEntry(
                key: "account:\(index)",
                library: AggregatedLibrary(
                    accountID: "account", accountName: "Account", serverName: "Server",
                    providerKind: .jellyfin,
                    library: MediaLibrary(id: "\(index)", title: "Library \(index)", kind: .movie)
                )
            )
        }
        func rail(token: Int, opening: Bool) -> NavigationRailView {
            NavigationRailView(
                profile: profile, entries: entries,
                destinations: [.home] + entries.map(\.destination) + [.settings],
                selection: .constant(.settings), isExpandedOutward: .constant(false),
                onOpenProfileSwitcher: {}, focusRequestToken: token,
                opensExpanded: opening
            )
        }
        let host = UIHostingController(rootView: rail(token: 0, opening: false))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1_920, height: 1_080))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        let scroll = try XCTUnwrap(
            descendantViews(of: host.view).compactMap { $0 as? UIScrollView }
                .first { $0.contentSize.height > $0.bounds.height }
        )
        XCTAssertGreaterThan(scroll.contentOffset.y, 0, "Initial entry must reveal a selected row below the fold")
        scroll.setContentOffset(.zero, animated: false)
        host.rootView = rail(token: 1, opening: true)
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(400))
        host.view.layoutIfNeeded()
        let markers = descendantViews(of: scroll).compactMap { $0 as? NavigationRowFocusRequester.RequestView }
        let lastMarker = try XCTUnwrap(markers.max {
            $0.convert($0.bounds, to: scroll).maxY < $1.convert($1.bounds, to: scroll).maxY
        })
        let lastFrame = lastMarker.convert(lastMarker.bounds, to: scroll)
        XCTAssertGreaterThan(scroll.contentOffset.y, 0)
        XCTAssertGreaterThanOrEqual(lastFrame.minY, scroll.bounds.minY - 1, "\(lastFrame) in \(scroll.bounds)")
        XCTAssertLessThanOrEqual(lastFrame.maxY, scroll.bounds.maxY + 1, "\(lastFrame) in \(scroll.bounds)")
        let target = try XCTUnwrap(NavigationRowFocusRequester.target(for: lastMarker, in: window))
        XCTAssertFalse(target === scroll, "Entry must resolve a destination row, not the scroll container")
    }

    private func descendantViews(of view: UIView) -> [UIView] {
        view.subviews.flatMap { [$0] + descendantViews(of: $0) }
    }

    func testSuccessfulRowHandoffIsNotOverriddenByWindowPreference() {
        let window = UIWindow()
        let row = UIButton()
        let page = UIButton()
        let focusSystem = FocusSystemStub(nextFocusedItems: [row, page])
        XCTAssertTrue(NavigationRowFocusRequester.handoff(to: row, in: window, using: focusSystem))
        XCTAssertEqual(focusSystem.requests.count, 1)
        XCTAssertTrue(focusSystem.requests[0] === row)
        XCTAssertTrue(focusSystem.focusedItem === row)
        XCTAssertEqual(focusSystem.committedRequestCounts, [1])
    }

    func testHandoffReevaluatesWindowOnlyAfterDirectRowRequestFails() {
        let window = UIWindow()
        let row = UIButton()
        let capsule = UIButton()
        let focusSystem = FocusSystemStub(nextFocusedItems: [capsule, row])
        XCTAssertTrue(NavigationRowFocusRequester.handoff(to: row, in: window, using: focusSystem))
        XCTAssertEqual(focusSystem.requests.count, 2)
        XCTAssertTrue(focusSystem.requests[0] === row)
        XCTAssertTrue(focusSystem.requests[1] === window)
        XCTAssertEqual(focusSystem.committedRequestCounts, [1, 2])
    }

    func testHandoffDoesNotAcknowledgeFocusRemainingOnCapsule() {
        let window = UIWindow()
        let row = UIButton()
        let capsule = UIButton()
        let focusSystem = FocusSystemStub(nextFocusedItems: [capsule, capsule])
        XCTAssertFalse(NavigationRowFocusRequester.handoff(to: row, in: window, using: focusSystem))
    }

    func testMissingRowCompletesFailedRequestAndCannotStealFocusOnLaterLayout() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        let marker = NavigationRowFocusRequester.RequestView(
            frame: CGRect(x: 66, y: 152, width: 294, height: 44)
        )
        host.view.addSubview(marker)
        let completed = expectation(description: "Unavailable row releases shell entry")
        var completions = 0
        marker.onCompleted = { request, focused in
            completions += 1
            XCTAssertEqual(request, 7)
            XCTAssertFalse(focused)
            completed.fulfill()
        }
        marker.request = 7
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertNil(marker.request)

        let row = UIButton(frame: CGRect(x: 54, y: 142, width: 318, height: 64))
        host.view.addSubview(row)
        marker.setNeedsLayout()
        marker.layoutIfNeeded()
        await Task.yield()
        XCTAssertEqual(completions, 1, "A failed request must not retry against later page content")
    }

    func testFindsFocusableRowInsideNonFocusableLayoutContainer() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let container = UIView(frame: CGRect(x: 20, y: 100, width: 426, height: 200))
        let row = UIButton(frame: CGRect(x: 54, y: 42, width: 318, height: 64))
        container.addSubview(row)
        window.addSubview(container)
        let marker = UIView(frame: CGRect(x: 86, y: 152, width: 294, height: 44))
        window.addSubview(marker)
        XCTAssertFalse(container.canBecomeFocused)
        XCTAssertTrue(NavigationRowFocusRequester.target(for: marker, in: window) === row)
    }

    func testDetachingBeforeHandoffTerminatesThePendingRequest() async {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let marker = NavigationRowFocusRequester.RequestView(
            frame: CGRect(x: 66, y: 152, width: 294, height: 44)
        )
        window.addSubview(marker)
        let completed = expectation(description: "Detached row releases entry")
        marker.onCompleted = { request, focused in
            XCTAssertEqual(request, 7)
            XCTAssertFalse(focused)
            completed.fulfill()
        }
        marker.request = 7
        marker.removeFromSuperview()
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertNil(marker.request)
    }

    func testChoosesRowRatherThanLargerFocusableContainer() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let broad = UIButton(frame: CGRect(x: 0, y: 100, width: 426, height: 200))
        let row = UIButton(frame: CGRect(x: 54, y: 142, width: 318, height: 64))
        let marker = UIView(frame: CGRect(x: 66, y: 152, width: 294, height: 44))
        [broad, row, marker].forEach { window.addSubview($0) }
        XCTAssertTrue(NavigationRowFocusRequester.target(for: marker, in: window) === row)
    }

    func testFindsCollapsedRowOutsideHostingTitleSafeBoundsAfterScrolling() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let hostingView = UIView(frame: CGRect(x: 96, y: 60, width: 1728, height: 960))
        window.addSubview(hostingView)
        let scroll = UIScrollView(frame: CGRect(x: -96, y: 116, width: 92, height: 820))
        scroll.contentSize = CGSize(width: 92, height: 2486)
        hostingView.addSubview(scroll)
        let row = UIButton(frame: CGRect(x: 28, y: 2420, width: 64, height: 64))
        scroll.addSubview(row)
        let marker = UIView(frame: CGRect(x: 11, y: 10, width: 42, height: 44))
        row.addSubview(marker)
        scroll.contentOffset.y = 1666

        XCTAssertEqual(marker.convert(marker.bounds, to: window), CGRect(x: 39, y: 940, width: 42, height: 44))
        XCTAssertFalse(hostingView.frame.intersects(marker.convert(marker.bounds, to: window)))
        XCTAssertTrue(NavigationRowFocusRequester.target(for: marker, in: window) === row)
    }

    func testVirtualRowFrameUsesItsContainingEnvironmentAfterScrolling() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 176, width: 92, height: 820))
        window.addSubview(scroll)
        scroll.contentSize = CGSize(width: 92, height: 2486)
        scroll.contentOffset.y = 1666
        let marker = UIView(frame: CGRect(x: 39, y: 2430, width: 42, height: 44))
        scroll.addSubview(marker)
        let owner = NavigationItemEnvironment(container: scroll)
        let intermediate = NavigationItemEnvironment(parent: owner)
        let row = VirtualNavigationFocusItem(
            frame: CGRect(x: 28, y: 2420, width: 64, height: 64),
            parent: intermediate
        )
        XCTAssertEqual(
            NavigationRowFocusRequester.frame(of: row, relativeTo: marker),
            CGRect(x: -11, y: -10, width: 64, height: 64)
        )
        let coordinates: any UICoordinateSpace = marker
        XCTAssertFalse(coordinates.convert(row.frame, from: window).contains(marker.bounds))
    }

    func testVirtualRowWithoutContainingCoordinatesIsNotMatchedToAnArbitraryControl() {
        let row = VirtualNavigationFocusItem(frame: CGRect(x: 0, y: 0, width: 64, height: 64))
        XCTAssertNil(NavigationRowFocusRequester.frame(of: row, relativeTo: UIView()))
    }

    func testScrolledVirtualRowCanBeFocusedWhenItsStyledLabelExtendsBeyondItsFocusFrame() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 176, width: 92, height: 820))
        window.addSubview(scroll)
        scroll.contentSize = CGSize(width: 92, height: 2486)
        scroll.contentOffset.y = 1666
        let marker = UIView(frame: CGRect(x: 39, y: 2430, width: 42, height: 44))
        scroll.addSubview(marker)
        let owner = NavigationItemEnvironment(container: scroll)
        let row = VirtualNavigationFocusItem(
            frame: CGRect(x: 0, y: 2420, width: 64, height: 64), parent: owner
        )
        let container = NavigationItemsContainer(coordinateSpace: scroll, items: [row])
        let frame = try XCTUnwrap(NavigationRowFocusRequester.frame(of: row, relativeTo: marker))
        XCTAssertFalse(frame.contains(marker.bounds), "Native focus geometry is not the entire styled label")
        XCTAssertTrue(NavigationRowFocusRequester.target(for: marker, in: container) === row)
    }

    func testScrollingDestinationsContainerCannotAcknowledgeRowEntry() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let scroll = FocusableNavigationScrollView(
            frame: CGRect(x: 20, y: 100, width: 426, height: 700)
        )
        window.addSubview(scroll)
        let marker = UIView(frame: CGRect(x: 66, y: 152, width: 294, height: 44))
        window.addSubview(marker)
        XCTAssertTrue(scroll.canBecomeFocused)
        XCTAssertNil(NavigationRowFocusRequester.target(for: marker, in: window))

        let row = UIButton(frame: CGRect(x: 34, y: 42, width: 318, height: 64))
        scroll.addSubview(row)
        XCTAssertTrue(NavigationRowFocusRequester.target(for: marker, in: window) === row)
    }

    func testDisabledRowAndHeaderCapsuleAreNotTargets() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let header = UIButton(frame: CGRect(x: 83, y: 72, width: 174.5, height: 58))
        let row = UIButton(frame: CGRect(x: 54, y: 142, width: 318, height: 64))
        row.isEnabled = false
        let marker = UIView(frame: CGRect(x: 66, y: 152, width: 294, height: 44))
        [header, row, marker].forEach { window.addSubview($0) }
        XCTAssertNil(NavigationRowFocusRequester.target(for: marker, in: window))
        row.isEnabled = true
        XCTAssertTrue(NavigationRowFocusRequester.target(for: marker, in: window) === row)
    }

    func testUnlaidOutMarkerDoesNotChooseAnArbitraryControl() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let row = UIButton(frame: window.bounds)
        let marker = UIView(frame: .zero)
        window.addSubview(row)
        window.addSubview(marker)
        XCTAssertNil(NavigationRowFocusRequester.target(for: marker, in: window))
    }
}

@MainActor
private final class FocusSystemStub: NavigationFocusUpdating {
    private var nextFocusedItems: [any UIFocusItem]
    private(set) var focusedItem: (any UIFocusItem)?
    private(set) var requests: [any UIFocusEnvironment] = []
    private(set) var committedRequestCounts: [Int] = []

    init(nextFocusedItems: [any UIFocusItem]) { self.nextFocusedItems = nextFocusedItems }

    func requestFocusUpdate(to environment: any UIFocusEnvironment) {
        requests.append(environment)
    }

    func updateFocusIfNeeded() {
        committedRequestCounts.append(requests.count)
        if !nextFocusedItems.isEmpty { focusedItem = nextFocusedItems.removeFirst() }
    }
}

private final class FocusableNavigationScrollView: UIScrollView {
    override var canBecomeFocused: Bool { true }
}

@MainActor
private class NavigationItemEnvironment: NSObject, UIFocusEnvironment {
    let preferredFocusEnvironments: [any UIFocusEnvironment] = []
    let parentFocusEnvironment: (any UIFocusEnvironment)?
    let focusItemContainer: (any UIFocusItemContainer)?

    init(parent: (any UIFocusEnvironment)? = nil, container: (any UIFocusItemContainer)? = nil) {
        parentFocusEnvironment = parent
        focusItemContainer = container
        super.init()
    }

    func setNeedsFocusUpdate() {}
    func updateFocusIfNeeded() {}
    func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool { true }
    func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {}
}

@MainActor
private final class VirtualNavigationFocusItem: NavigationItemEnvironment, UIFocusItem {
    let canBecomeFocused = true
    let frame: CGRect

    init(frame: CGRect, parent: (any UIFocusEnvironment)? = nil) {
        self.frame = frame
        super.init(parent: parent)
    }
}

@MainActor
private final class NavigationItemsContainer: NSObject, UIFocusItemContainer {
    let coordinateSpace: any UICoordinateSpace
    let items: [any UIFocusItem]

    init(coordinateSpace: any UICoordinateSpace, items: [any UIFocusItem]) {
        self.coordinateSpace = coordinateSpace
        self.items = items
        super.init()
    }

    func focusItems(in rect: CGRect) -> [any UIFocusItem] {
        items.filter { $0.frame.intersects(rect) }
    }
}
#endif
