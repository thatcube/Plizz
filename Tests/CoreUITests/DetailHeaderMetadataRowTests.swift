#if os(iOS)
import CoreModels
import CoreUI
import SwiftUI
import UIKit
import XCTest

@MainActor
final class DetailHeaderMetadataRowTests: XCTestCase {
    private let ratings: [ExternalRating] = [
        .init(source: .rottenTomatoesAudience, value: 89, scale: .percent),
        .init(source: .rottenTomatoes, value: 96, scale: .percent)
    ]
    private let badges: [MediaBadge] = [
        .init("4K", style: .prominent),
        .init("Dolby Vision", style: .dolby),
        .init("HDR10", style: .hdr),
        .init("Dolby Atmos", style: .dolby)
    ]

    private func size(of view: some View, width: CGFloat, textSize: DynamicTypeSize = .large) -> CGSize {
        UIHostingController(rootView: view
            .environment(\.dynamicTypeSize, textSize)
            .environment(\.horizontalSizeClass, .compact)
        ).sizeThatFits(in: CGSize(width: width, height: 2_000))
    }

    func testSparseKorraMetadataRemainsOneLine() {
        let score = ExternalRating(source: .community, value: 8.2, scale: .outOfTen)
        let formats = [
            MediaBadge("1080p", style: .prominent),
            MediaBadge("Dolby Digital", style: .dolby, detail: "5.1"),
            MediaBadge("SDR", style: .sdr)
        ]
        let row = DetailHeaderMetadataRow(ratings: [score], badges: formats)
        let reference = size(of: RatingBadge(rating: score), width: 320)
        let actual = size(of: row, width: 320)
        XCTAssertEqual(actual.height, reference.height, accuracy: 1)
        XCTAssertLessThanOrEqual(actual.width, 320)
    }

    func testEveryCombinationStaysWithinOneLineAtEveryTextSize() {
        for width in [CGFloat(180), 280, 393] {
            for textSize in [DynamicTypeSize.large, .xxxLarge, .accessibility3] {
                let reference = size(of: RatingBadge(rating: ratings[0]), width: 2_000, textSize: textSize)
                for scores in [[], Array(ratings.prefix(1)), ratings] {
                    for formats in [[], Array(badges.prefix(1)), badges] {
                        let result = size(
                            of: DetailHeaderMetadataRow(ratings: scores, badges: formats),
                            width: width, textSize: textSize
                        )
                        XCTAssertLessThanOrEqual(result.width, width + 0.5)
                        XCTAssertLessThanOrEqual(result.height, max(44, reference.height) + 1)
                        if scores.isEmpty && formats.isEmpty {
                            XCTAssertEqual(result.height, 0, accuracy: 0.5)
                        }
                    }
                }
            }
        }
    }

    func testFormatTextYieldsToTheDetailsButtonBeforeWrapping() {
        let actual = size(of: DetailHeaderMetadataRow(ratings: ratings, badges: badges), width: 250)
        let expected = size(of: HStack(spacing: 12) {
            ForEach(ratings) { RatingBadge(rating: $0) }
            Label("Formats", systemImage: "info.circle").font(.subheadline.weight(.medium))
        }.fixedSize(), width: 2_000)
        XCTAssertEqual(actual.height, expected.height, accuracy: 0.5)
        XCTAssertLessThanOrEqual(actual.width, 250)
    }
}
#endif
