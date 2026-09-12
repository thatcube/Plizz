#if os(tvOS)
import UIKit
import XCTest
@testable import CoreUI

@MainActor
final class NativeFocusProjectionTests: XCTestCase {
    func testPerspectiveKeepsDepthUntilTheAncestorProjection() throws {
        let root = CALayer()
        root.bounds = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let perspective = CALayer()
        perspective.frame = CGRect(x: 100, y: 200, width: 200, height: 300)
        var transform = CATransform3DIdentity
        transform.m34 = -1 / 900
        perspective.transform = transform
        root.addSublayer(perspective)
        let floating = CALayer()
        floating.frame = perspective.bounds
        floating.transform = CATransform3DMakeTranslation(0, 0, 24)
        perspective.addSublayer(floating)

        let frame = try XCTUnwrap(NativeFocusProjection.frame(of: floating, in: root))
        let scale: CGFloat = 1 / (1 - 24 / 900)
        XCTAssertEqual(frame.width, 200 * scale, accuracy: 0.001)
        XCTAssertEqual(frame.height, 300 * scale, accuracy: 0.001)
        XCTAssertEqual(frame.midX, 200, accuracy: 0.001)
        XCTAssertEqual(frame.midY, 350, accuracy: 0.001)
    }

    func testNonzeroBoundsAndParentSublayerTransform() throws {
        let root = CALayer()
        root.bounds = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        root.sublayerTransform = CATransform3DMakeScale(2, 2, 1)
        let child = CALayer()
        child.bounds = CGRect(x: 10, y: 20, width: 100, height: 50)
        child.position = CGPoint(x: 500, y: 500)
        root.addSublayer(child)
        XCTAssertEqual(
            try XCTUnwrap(NativeFocusProjection.frame(of: child, in: root)),
            CGRect(x: 400, y: 450, width: 200, height: 100)
        )
    }

    func testUnrelatedLayersAndSingularProjectionAreUnavailable() {
        let root = CALayer()
        let child = CALayer()
        child.bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertNil(NativeFocusProjection.frame(of: child, in: root))
        root.addSublayer(child)
        var transform = CATransform3DIdentity
        transform.m44 = 0
        child.transform = transform
        XCTAssertNil(NativeFocusProjection.frame(of: child, in: root))
    }
}
#endif
