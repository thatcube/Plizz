#if canImport(UIKit)
import CoreUI
import SwiftUI
import UIKit
import XCTest

@MainActor
final class HeroActionRowTests: XCTestCase {
    private func size(of view: some View, width: CGFloat = 2_000) -> CGSize {
        UIHostingController(rootView: view).sizeThatFits(in: CGSize(width: width, height: 3_000))
    }

    private func row(
        progress: Double,
        fontSize: CGFloat,
        labelledTrailer: Bool,
        stacksVertically: Bool = false
    ) -> some View {
        HeroActionRow(stacksVertically: stacksVertically) {
            DownloadProgressButtonLabel(progress: progress, onLight: false)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.gray.opacity(0.2), in: Capsule())
            if labelledTrailer {
                Label("Trailer", systemImage: "film.fill")
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(.gray.opacity(0.2), in: Capsule())
            } else {
                Image(systemName: "film.fill")
                    .frame(width: 48, height: 48)
            }
            Image(systemName: "bookmark")
                .frame(width: 48, height: 48)
        }
        .font(.system(size: fontSize, weight: .semibold))
        .foregroundStyle(.white)
    }

    private func adaptiveRow(progress: Double, fontSize: CGFloat) -> some View {
        ViewThatFits(in: .horizontal) {
            row(progress: progress, fontSize: fontSize, labelledTrailer: true)
            row(progress: progress, fontSize: fontSize, labelledTrailer: false)
            row(progress: progress, fontSize: fontSize, labelledTrailer: false, stacksVertically: true)
        }
    }

    func testInlineCandidateReportsReadableWidthInsteadOfCompressingLabels() {
        let candidate = row(progress: 0.64, fontSize: 17, labelledTrailer: true)
        let ideal = size(of: candidate)
        let constrained = size(of: candidate, width: 276)
        XCTAssertGreaterThan(ideal.width, 276)
        XCTAssertEqual(constrained.width, ideal.width, accuracy: 0.5)
        XCTAssertEqual(constrained.height, ideal.height, accuracy: 0.5)
    }

    func testTrailerBecomesAnIconBeforePercentageIsCompressed() {
        for progress in [0.0, 0.01, 0.64, 0.99, 1.0] {
            let compact = size(of: row(progress: progress, fontSize: 17, labelledTrailer: false))
            let labelled = size(of: row(progress: progress, fontSize: 17, labelledTrailer: true))
            let width = (compact.width + labelled.width) / 2
            let actual = size(of: adaptiveRow(progress: progress, fontSize: 17), width: width)
            XCTAssertEqual(actual.width, compact.width, accuracy: 0.5)
            XCTAssertEqual(actual.height, compact.height, accuracy: 0.5)
        }
    }

    func testLargePercentageMovesAboveTheBarInsteadOfTruncating() {
        let label = DownloadProgressButtonLabel(progress: 1, onLight: false)
            .font(.system(size: 53, weight: .semibold))
        let ideal = size(of: label)
        let constrained = size(of: label, width: 236)
        XCTAssertGreaterThan(ideal.width, 236)
        XCTAssertLessThanOrEqual(constrained.width, 236)
        XCTAssertGreaterThan(constrained.height, ideal.height)
    }

    func testLongPlayAndRequestLabelsGrowVertically() {
        let label = PlayResumeButtonLabel(
            title: "Start watching this season",
            progress: nil,
            remainingText: nil,
            seasonEpisodeText: "S20, E100",
            onLight: false,
            wrapsText: true
        )
        let content = HeroActionRow(stacksVertically: true) {
            label
            Label("20 Seasons Requested - 3 Seasons Still Processing", systemImage: "clock")
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 34, weight: .semibold))
        let wide = size(of: content)
        let narrow = size(of: content, width: 236)
        // UIKit rounds fitted extents up to physical pixels on 3x iPhones.
        let pixel = 1 / max(1, UIHostingController(rootView: content).view.traitCollection.displayScale)
        XCTAssertLessThanOrEqual(narrow.width, 236 + pixel)
        XCTAssertGreaterThan(narrow.height, wide.height * 2)
    }

    func testRenderedRowsFitPhoneWidthsAndLargeText() throws {
        for width in [CGFloat(276), 331, 386] {
            for fontSize in [CGFloat(17), 34, 53] {
                for progress in [0.64, 1] {
                    let row = adaptiveRow(progress: progress, fontSize: fontSize)
                    XCTAssertLessThanOrEqual(size(of: row, width: width).width, width + 0.5)
                    let renderer = ImageRenderer(
                        content: row.frame(width: width).padding(12).background(.black)
                    )
                    renderer.scale = 2
                    let image = try XCTUnwrap(renderer.uiImage)
                    let attachment = XCTAttachment(image: image)
                    attachment.name = "actions-\(Int(width))pt-font\(Int(fontSize))-\(Int(progress * 100))percent"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
            }
        }
    }
}
#endif
