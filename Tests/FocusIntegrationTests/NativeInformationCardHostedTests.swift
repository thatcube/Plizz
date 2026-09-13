import CoreModels
@testable import CoreUI
import SwiftUI
import TVUIKit
import UIKit
import XCTest

@MainActor
final class NativeInformationCardHostedTests: XCTestCase {
    func testInformationGridSettlesWithoutBlockingTheMainThread() async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        var item = MediaItem(id: "native-information", title: "A documentary series", kind: .series)
        item.overview = String(repeating:
            "Two collectors travel across the country looking for unusual objects and the stories behind them. ",
            count: 12
        )
        item.ratings = [
            ExternalRating(source: .imdb, value: 7.9, scale: .outOfTen),
            ExternalRating(source: .tmdb, value: 8.1, scale: .outOfTen),
            ExternalRating(source: .rottenTomatoes, value: 96, scale: .percent),
            ExternalRating(source: .rottenTomatoesAudience, value: 88, scale: .percent)
        ]
        item.genres = ["Documentary", "Reality"]
        let host = UIHostingController(rootView:
            ScrollView {
                DetailInformationSections(item: item, horizontalInset: 80)
            }
            .environment(\.plozzCardFocusStyle, .system)
            .environment(\.themePalette, .dark)
            .environment(\.colorScheme, .dark)
        )
        window.rootViewController = host
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
        }
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .seconds(2))
        let cards = nativeCards(in: window)
        XCTAssertFalse(cards.isEmpty)
        let before = cards.map { $0.convert($0.bounds, to: window) }
        try await Task.sleep(for: .seconds(1))
        let after = cards.map { $0.convert($0.bounds, to: window) }
        for (index, frame) in after.enumerated() {
            XCTAssertGreaterThan(frame.width, 100)
            XCTAssertLessThanOrEqual(frame.maxX, window.bounds.maxX)
            XCTAssertGreaterThanOrEqual(frame.minX, 0)
            XCTAssertLessThan(frame.height, 1080)
            XCTAssertEqual(frame.height, before[index].height, accuracy: 1)
            XCTAssertEqual(frame.width, before[index].width, accuracy: 1)
            XCTAssertEqual(cards[index].intrinsicContentSize.width, frame.width, accuracy: 1)
        }
        let attachment = XCTAttachment(string: after.map(String.init(describing:)).joined(separator: "\n"))
        attachment.name = "native-information-card-frames"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func nativeCards(in view: UIView) -> [TVCardView] {
        (view as? TVCardView).map { [$0] } ?? view.subviews.flatMap(nativeCards(in:))
    }
}
