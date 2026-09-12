#if DEBUG && os(tvOS)
import CoreUI
import FeatureLiveTVCore
import SwiftUI
import UIKit
import XCTest
@testable import FeatureLiveTV

@MainActor
final class PrototypeNativeGuideListTests: XCTestCase {
    private typealias Guide = PrototypeNativeGuideList<Int, Text>

    func testThousandsOfChannelsOnlyCreateVisibleRowHostsAndReuseUnchangedContent() {
        let rows = (0..<5_000).map { LiveTVGuideRowID(channelID: "channel-\($0)") }
        let scroll = PrototypeGuideScrollController()
        var renders = 0
        let list = Guide(
            rows: rows, scrollController: scroll, scrolled: { _, _ in }, revision: { _ in 0 }
        ) { row in
            renders += 1
            return Text(row.channelID)
        }
        let controller = Guide.Controller()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1920, height: 720))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            Guide.dismantleUIViewController(controller, coordinator: ())
        }
        controller.view.frame = window.bounds
        controller.update(list, environment: EnvironmentValues())
        controller.view.layoutIfNeeded()
        let rendered = renders
        XCTAssertGreaterThan(rendered, 0)
        XCTAssertLessThan(rendered, 100, "Offscreen channels must not materialize a full-catalog focus tree")
        XCTAssertLessThan(controller.children.count, 100)

        controller.update(list, environment: EnvironmentValues())
        controller.view.layoutIfNeeded()
        XCTAssertEqual(renders, rendered, "Unchanged row revisions must reuse their hosted content")

        scroll.scrollTo(rows[4_900], anchor: .top)
        controller.view.layoutIfNeeded()
        XCTAssertLessThan(renders, 200)
        XCTAssertLessThan(controller.children.count, 100, "Offscreen hosts must leave the controller hierarchy")
    }

    func testPresentationEnvironmentIgnoresPrivateFocusChangesButTracksVisiblePreferences() {
        var environment = EnvironmentValues()
        let baseline = Guide.RowEnvironment(environment)
        XCTAssertEqual(baseline, Guide.RowEnvironment(environment))
        environment.isEnabled = false
        XCTAssertNotEqual(baseline, Guide.RowEnvironment(environment))
        environment.isEnabled = true
        environment.layoutDirection = .rightToLeft
        XCTAssertNotEqual(baseline, Guide.RowEnvironment(environment))
    }
}
#endif
