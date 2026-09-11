#if canImport(UIKit)
import CoreModels
import CoreUI
import SwiftUI
import UIKit
import XCTest

@MainActor
final class MediaBadgeSizingTests: XCTestCase {
    private let badges: [MediaBadge] = [
        MediaBadge("4K", style: .prominent),
        MediaBadge("Dolby Vision", style: .dolby),
        MediaBadge("Dolby Atmos", style: .dolby),
        MediaBadge("HDR10", style: .hdr),
        MediaBadge("HDR10+", style: .hdr),
        MediaBadge("SDR", style: .sdr),
        MediaBadge("DTS-HD", style: .dts, detail: "5.1"),
        MediaBadge("5.1", style: .spec),
        MediaBadge("1080p", style: .prominent)
    ]

    private func size(of view: some View) -> CGSize {
        UIHostingController(rootView: view).sizeThatFits(
            in: CGSize(width: 2_000, height: 500)
        )
    }

    func testMetadataBadgesUseThreeQuarterScale() {
        for badge in badges {
            let original = size(of: MediaBadgeChip(badge: badge)
                .environment(\.dynamicTypeSize, .large))
            let compact = size(of: MetadataMediaBadgeChip(badge: badge)
                .environment(\.dynamicTypeSize, .large))
            let expected = size(of: MediaBadgeChip(badge: badge)
                .environment(\.mediaBadgeScale, 0.75)
                .environment(\.dynamicTypeSize, .large))
            XCTAssertEqual(compact.width, expected.width, accuracy: 0.5, badge.label)
            // Small system fonts use optical spacing, not a linear transform of larger glyphs.
            XCTAssertLessThan(compact.width, original.width, badge.label)
            XCTAssertEqual(compact.height, original.height * 0.75, accuracy: 1, badge.label)
        }
    }

    func testMetadataBadgesPreserveTheContainerScale() {
        let badge = MediaBadge("4K", style: .prominent)
        let reduced = size(of: MetadataMediaBadgeChip(badge: badge)
            .environment(\.mediaBadgeScale, 0.8)
            .environment(\.dynamicTypeSize, .large))
        let expected = size(of: MediaBadgeChip(badge: badge)
            .environment(\.mediaBadgeScale, 0.6)
            .environment(\.dynamicTypeSize, .large))
        XCTAssertEqual(reduced.width, expected.width, accuracy: 0.5)
        XCTAssertEqual(reduced.height, expected.height, accuracy: 0.5)
    }

    #if os(iOS)
    func testResolutionAndDolbyMarksAreComparableToMetadataTextHeight() {
        let textHeight = size(of: Text("2025")
            .font(.subheadline)
            .environment(\.dynamicTypeSize, .large)).height
        for badge in badges.prefix(3) {
            let badgeHeight = size(of: MetadataMediaBadgeChip(badge: badge)
                .environment(\.dynamicTypeSize, .large)).height
            XCTAssertGreaterThanOrEqual(badgeHeight, textHeight * 0.85, badge.label)
            XCTAssertLessThanOrEqual(badgeHeight, textHeight * 1.2, badge.label)
        }
    }

    func testBadgeHeightTracksTheMetadataTextSize() {
        let badge = MediaBadge("4K", style: .prominent)
        let normalHeight = size(of: MetadataMediaBadgeChip(badge: badge)
            .environment(\.dynamicTypeSize, .large)).height
        let normalTextHeight = size(of: Text("2025")
            .font(.subheadline)
            .environment(\.dynamicTypeSize, .large)).height
        for category in [DynamicTypeSize.xSmall, .xxxLarge, .accessibility3] {
            let badgeHeight = size(of: MetadataMediaBadgeChip(badge: badge)
                .environment(\.dynamicTypeSize, category)).height
            let textHeight = size(of: Text("2025")
                .font(.subheadline)
                .environment(\.dynamicTypeSize, category)).height
            XCTAssertEqual(
                badgeHeight / normalHeight,
                textHeight / normalTextHeight,
                accuracy: 0.08,
                "\(category)"
            )
        }
    }
    #endif

    func testMetadataRowRendersCompactBadgesInBothThemes() throws {
        for scheme in [ColorScheme.light, .dark] {
            let row = HStack(spacing: 12) {
                Text("2025 \u{00B7} 56m")
                    .font(.subheadline.weight(.medium))
                Label("8.3", systemImage: "star.fill")
                    .font(.subheadline.weight(.medium))
                ForEach(Array(badges.prefix(4))) { badge in
                    MetadataMediaBadgeChip(badge: badge)
                }
            }
            .fixedSize()
            .padding(16)
            .background(scheme == .dark ? Color.black : Color.white)
            .environment(\.themePalette, scheme == .dark ? .dark : .light)
            .environment(\.colorScheme, scheme)
            .environment(\.dynamicTypeSize, .large)
            let renderer = ImageRenderer(content: row)
            renderer.scale = 3
            let image = try XCTUnwrap(renderer.uiImage)
            XCTAssertGreaterThan(image.size.width, 0)
            XCTAssertGreaterThan(image.size.height, 0)
            let attachment = XCTAttachment(image: image)
            attachment.name = "compact-metadata-badges-\(scheme)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}
#endif
