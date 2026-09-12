#if DEBUG && os(tvOS)
import SwiftUI
import UIKit
import XCTest
@testable import FeatureLiveTV

@MainActor
final class LiveTVSearchBoundaryTests: XCTestCase {
    private typealias RowController = UIHostingController<PrototypeSearchRowHost<AnyView>.HostedContent>

    func testSearchRowsHaveTheirOwnRowSizedNativeFocusBoundary() async throws {
        let root = UIHostingController(rootView: rows(isSearch: true))
        let window = makeWindow(root)
        defer { window.isHidden = true }
        await waitForRows(in: root)

        let controllers = rowControllers(in: root)
        XCTAssertEqual(controllers.count, 2)
        for controller in controllers {
            XCTAssertEqual(controller.view.bounds.height, 128, accuracy: 1)
            XCTAssertEqual(controller.view.bounds.width, 1_200, accuracy: 1)
            XCTAssertTrue(controller.safeAreaRegions.isEmpty)
        }
    }

    func testOrdinaryGuideDoesNotAddNativeRowControllers() async throws {
        let root = UIHostingController(rootView: rows(isSearch: false))
        let window = makeWindow(root)
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(rowControllers(in: root).isEmpty)
    }

    func testSearchBoundaryPreservesEnvironmentAndHostedIdentityOnUpdate() async throws {
        let root = UIHostingController(rootView: rows(isSearch: true))
        let window = makeWindow(root)
        defer { window.isHidden = true }
        await waitForRows(in: root)
        let original = try XCTUnwrap(rowControllers(in: root).first)

        XCTAssertEqual(original.rootView.environment.layoutDirection, .rightToLeft)
        XCTAssertEqual(original.rootView.environment.locale.identifier, "ar")
        XCTAssertFalse(original.rootView.environment.isEnabled)
        root.rootView = rows(isSearch: true, label: "Updated")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(rowControllers(in: root).first === original)
    }

    private func rows(isSearch: Bool, label: String = "Row") -> AnyView {
        AnyView(
            VStack(spacing: 16) {
                ForEach(0..<2) { index in
                    PrototypeSearchFocusBoundary {
                        AnyView(Button("\(label) \(index)", action: {}).frame(maxWidth: .infinity).frame(height: 128))
                    }
                }
            }
            .frame(width: 1_200, height: 750, alignment: .top)
            .environment(\.prototypeSearchResults, isSearch)
            .environment(\.layoutDirection, .rightToLeft)
            .environment(\.locale, Locale(identifier: "ar"))
            .disabled(true)
        )
    }

    private func rowControllers(in root: UIViewController) -> [RowController] {
        root.children.flatMap { child -> [RowController] in
            if let row = child as? RowController { return [row] }
            return rowControllers(in: child)
        }
    }

    private func waitForRows(in root: UIViewController) async {
        for _ in 0..<100 {
            if rowControllers(in: root).count == 2 { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func makeWindow(_ root: UIViewController) -> UIWindow {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let window = scene.map(UIWindow.init(windowScene:))
            ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 1_920, height: 1_080))
        window.rootViewController = root
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        root.view.layoutIfNeeded()
        return window
    }
}
#endif
