#if os(iOS)
import CoreModels
import CoreUI
import SwiftUI
import UIKit
import XCTest

@MainActor
final class AdaptiveMediaMetadataRowTests: XCTestCase {
    private let facts = ["2025", "1h"]
    private let ratings: [ExternalRating] = [
        .init(source: .rottenTomatoes, value: 99, scale: .percent),
        .init(source: .rottenTomatoesAudience, value: 68, scale: .percent),
        .init(source: .imdb, value: 7.9, scale: .outOfTen),
        .init(source: .tmdb, value: 7.9, scale: .outOfTen)
    ]
    private let badges: [MediaBadge] = [
        .init("4K", style: .prominent),
        .init("Dolby Vision", style: .dolby),
        .init("Dolby Atmos", style: .dolby),
        .init("HDR10", style: .hdr)
    ]

    private func size(of view: some View, width: CGFloat = 2_000) -> CGSize {
        UIHostingController(rootView: view
            .environment(\.horizontalSizeClass, .compact)
            .environment(\.dynamicTypeSize, .large)
        ).sizeThatFits(in: CGSize(width: width, height: 2_000))
    }

    private func inlineRow(
        facts: [String],
        ratings: [ExternalRating],
        badges: [MediaBadge]
    ) -> some View {
        HStack(spacing: 12) {
            if !facts.isEmpty {
                Text(facts.joined(separator: "  \u{00B7}  "))
                    .font(.subheadline.weight(.medium))
                    .fixedSize()
            }
            ForEach(ratings) { RatingBadge(rating: $0) }
            ForEach(badges) { MetadataMediaBadgeChip(badge: $0) }
        }
        .fixedSize()
    }

    func testUsesOneRowUntilTheActualContentNoLongerFits() {
        let inline = size(of: inlineRow(facts: facts, ratings: ratings, badges: badges))
        let view = AdaptiveMediaMetadataRow(facts: facts, ratings: ratings, badges: badges, centered: true)
        let fits = size(of: view, width: inline.width + 1)
        let overflows = size(of: view, width: inline.width - 1)
        XCTAssertEqual(fits.height, inline.height, accuracy: 0.5)
        XCTAssertGreaterThan(overflows.height, fits.height)
    }

    func testCrowdedPhoneRowMovesAllRatingsBelowFactsAndFormats() {
        let top = size(of: inlineRow(facts: facts, ratings: [], badges: badges))
        let bottom = size(of: inlineRow(facts: [], ratings: ratings, badges: []))
        for width in [CGFloat(320), 393] {
            XCTAssertLessThanOrEqual(top.width, width)
            XCTAssertLessThanOrEqual(bottom.width, width)
            let actual = size(of: AdaptiveMediaMetadataRow(
                facts: facts, ratings: ratings, badges: badges, centered: true
            ), width: width)
            XCTAssertEqual(actual.height, top.height + 8 + bottom.height, accuracy: 1)
            XCTAssertLessThanOrEqual(actual.width, width)
        }
    }

    func testSparseAndMissingGroupsDoNotCreateReservedRows() {
        for factValues in [[], ["2025"]] {
            for ratingValues in [[], Array(ratings.prefix(1))] {
                for badgeValues in [[], Array(badges.prefix(1))] {
                    let expected = size(of: inlineRow(
                        facts: factValues, ratings: ratingValues, badges: badgeValues
                    ))
                    let actual = size(of: AdaptiveMediaMetadataRow(
                        facts: factValues, ratings: ratingValues, badges: badgeValues, centered: true
                    ), width: expected.width + 1)
                    XCTAssertEqual(actual.height, expected.height, accuracy: 0.5)
                }
            }
        }
    }

    func testRatingsOnlyUseAvailableWidthWithoutAnEmptyUpperRow() {
        let expected = size(of: RatingsBadgeRow(ratings: ratings), width: 180)
        let actual = size(of: AdaptiveMediaMetadataRow(
            facts: [], ratings: ratings, badges: [], centered: true
        ), width: 180)
        XCTAssertEqual(actual.height, expected.height, accuracy: 0.5)
    }

    func testFormatsOnlyWrapWithoutAnEmptyFactsOrRatingsRow() {
        let expected = size(of: WrappingHStackLayout(
            alignment: .center, spacing: 12, lineSpacing: 8,
            balancesLastRow: true
        ) {
            ForEach(badges) { MetadataMediaBadgeChip(badge: $0) }
        }, width: 140)
        let actual = size(of: AdaptiveMediaMetadataRow(
            facts: [], ratings: [], badges: badges, centered: true
        ), width: 140)
        XCTAssertEqual(actual.height, expected.height, accuracy: 0.5)
    }

    func testWrappedGroupsBalanceAnOrphanWithoutAddingAnotherRow() throws {
        let items = [
            CGSize(width: 80, height: 20),
            CGSize(width: 80, height: 20),
            CGSize(width: 80, height: 60),
            CGSize(width: 80, height: 60)
        ]
        func row(balanced: Bool) -> some View {
            WrappingHStackLayout(spacing: 10, lineSpacing: 8, balancesLastRow: balanced) {
                ForEach(items.indices, id: \.self) { index in
                    Color.white.frame(width: items[index].width, height: items[index].height)
                }
            }
        }
        let unbalanced = size(of: row(balanced: false), width: 260)
        let balanced = size(of: row(balanced: true), width: 260)
        XCTAssertEqual(unbalanced.height, 128, accuracy: 0.5, "Default flow remains 3+1")
        XCTAssertEqual(balanced.height, 88, accuracy: 0.5, "Grouped fallback uses 2+2")
    }

    func testRendersContentDrivenLayoutsAndAccessibilityWithoutOverflow() throws {
        for (name, width, textSize) in [
            ("phone", CGFloat(393), DynamicTypeSize.large),
            ("narrow-phone", CGFloat(280), DynamicTypeSize.large),
            ("tablet", CGFloat(768), DynamicTypeSize.large),
            ("accessibility", CGFloat(320), DynamicTypeSize.accessibility3)
        ] {
            let content = AdaptiveMediaMetadataRow(
                facts: facts, ratings: ratings, badges: badges, centered: true
            )
            .environment(\.horizontalSizeClass, .compact)
            .environment(\.dynamicTypeSize, textSize)
            .environment(\.themePalette, .dark)
            .environment(\.colorScheme, .dark)
            .frame(width: width)
            .padding(16)
            .background(.black)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 3
            let image = try XCTUnwrap(renderer.uiImage)
            XCTAssertEqual(image.size.width, width + 32, accuracy: 0.5)
            XCTAssertLessThan(image.size.height, 350)
            let attachment = XCTAttachment(image: image)
            attachment.name = "adaptive-metadata-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}
#endif
