#if os(iOS)
import CoreUI
import SwiftUI
import UIKit
import Vision
import XCTest

@MainActor
final class InlineOverviewTests: XCTestCase {
    private let longText = Array(repeating:
        "A [traveler](https://example.test/person) follows a quiet river through the mountains, discovering old stories and unexpected friendships.",
        count: 5
    ).joined(separator: " ")

    private func referenceHeight(
        text: String, width: CGFloat, typeSize: DynamicTypeSize, lineLimit: Int = 3
    ) -> CGFloat {
        let view = Text(text.overviewMarkdownWithLegibleLinks(textColor: .white, accent: .white))
            .font(.body)
            .lineLimit(lineLimit)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .environment(\.dynamicTypeSize, typeSize)
        return UIHostingController(rootView: view).sizeThatFits(
            in: CGSize(width: width, height: 2_000)
        ).height
    }

    private func render(
        _ text: String,
        width: CGFloat,
        typeSize: DynamicTypeSize = .large,
        direction: LayoutDirection = .leftToRight,
        lineLimit: Int = 3
    ) async throws -> UIImage {
        let content = ExpandableOverviewText(
            text: text, title: "A story", lineLimit: lineLimit,
            font: .body, alignment: .center, style: .inline
        )
        .environment(\.dynamicTypeSize, typeSize)
        .environment(\.layoutDirection, direction)
        .environment(\.locale, Locale(identifier: "en"))
        .environment(\.colorScheme, .dark)
        .environment(\.themePalette, .dark)
        .frame(width: width)
        .background(.black)
        .ignoresSafeArea()
        let host = UIHostingController(rootView: content)
        host.safeAreaRegions = []
        let proposal = CGSize(width: width, height: 2_000)
        let initial = host.sizeThatFits(in: proposal)
        let previousKeyWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow)
        let window = UIWindow(frame: CGRect(origin: .zero, size: initial))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        let finalSize = host.sizeThatFits(in: proposal)
        window.frame.size = finalSize
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        host.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let image = UIGraphicsImageRenderer(size: finalSize, format: format).image {
            host.view.layer.render(in: $0.cgContext)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "inline-overview-\(Int(width))-\(typeSize)-\(direction)"
        attachment.lifetime = .keepAlways
        add(attachment)
        return image
    }

    private func recognizedText(in image: UIImage) throws -> [VNRecognizedText] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first }
    }

    private func moreBounds(in image: UIImage) throws -> CGRect {
        for candidate in try recognizedText(in: image) {
            if let range = candidate.string.range(of: "More", options: .caseInsensitive) {
                return try XCTUnwrap(candidate.boundingBox(for: range)).boundingBox
            }
        }
        XCTFail("The truncated preview must visibly include More")
        throw NSError(domain: "InlineOverviewTests", code: 1)
    }

    func testMoreAppearsOnTheThirdLineWithoutAddingHeight() async throws {
        for width in [CGFloat(280), 386] {
            let image = try await render(longText, width: width)
            XCTAssertEqual(image.size.height, referenceHeight(text: longText, width: width, typeSize: .large), accuracy: 1)
            let more = try moreBounds(in: image)
            XCTAssertLessThan(more.maxY, 0.38, "Vision coordinates start at the bottom; More belongs on line three.")
            XCTAssertGreaterThan(more.minX, 0.65, "More stays at the trailing end, not a separate row.")
            let text = try recognizedText(in: image).map(\.string).joined(separator: " ")
            XCTAssertFalse(text.contains("https"), "Markdown renders its link label, not its raw URL.")
        }
    }

    func testTwoLineDetailPreviewKeepsMoreOnItsSecondLine() async throws {
        for typeSize in [DynamicTypeSize.large, .accessibility3] {
            let image = try await render(longText, width: 320, typeSize: typeSize, lineLimit: 2)
            XCTAssertEqual(
                image.size.height,
                referenceHeight(text: longText, width: 320, typeSize: typeSize, lineLimit: 2),
                accuracy: 1
            )
            let more = try moreBounds(in: image)
            XCTAssertLessThan(more.maxY, 0.55, "More must stay within the second line.")
            XCTAssertGreaterThan(more.minX, 0.4)
        }
    }

    func testShortTextHasNoMoreAndNoReservedExtraLines() async throws {
        let image = try await render("A short synopsis.", width: 320)
        XCTAssertEqual(image.size.height, referenceHeight(text: "A short synopsis.", width: 320, typeSize: .large), accuracy: 1)
        let text = try recognizedText(in: image).map(\.string).joined(separator: " ")
        XCTAssertFalse(text.localizedCaseInsensitiveContains("More"))
    }

    func testMoreFitsOnLineThreeAtLargeTextAndMirrorsInRTL() async throws {
        let image = try await render(longText, width: 320, typeSize: .accessibility3, direction: .rightToLeft)
        XCTAssertEqual(image.size.height, referenceHeight(text: longText, width: 320, typeSize: .accessibility3), accuracy: 1)
        let more = try moreBounds(in: image)
        XCTAssertLessThan(more.maxY, 0.38)
        XCTAssertLessThan(more.maxX, 0.5)
    }

    func testDefaultCardKeepsItsExistingPadding() {
        let card = ExpandableOverviewText(
            text: "Short.", title: "A story", lineLimit: 3, font: .body
        ).environment(\.dynamicTypeSize, .large)
        let height = UIHostingController(rootView: card).sizeThatFits(
            in: CGSize(width: 320, height: 2_000)
        ).height
        XCTAssertEqual(height, referenceHeight(text: "Short.", width: 320, typeSize: .large) + 32, accuracy: 1)
    }
}
#endif
