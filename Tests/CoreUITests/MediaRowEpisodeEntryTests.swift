import CoreModels
import SwiftUI
import XCTest
@testable import CoreUI
#if canImport(UIKit)
import UIKit
#endif

final class MediaRowEpisodeEntryPolicyTests: XCTestCase {
    func testLoadedDataDoesNotRetireThePlaceholderUntilTheTargetIsOnScreen() {
        let id = "episode-998"
        let offscreen = MediaRowEntryLayout(
            target: .init(id: id, frame: CGRect(x: 4000, y: 0, width: 496, height: 380)),
            viewportWidth: 1920
        )
        XCTAssertFalse(MediaRowEpisodeEntryPolicy.targetReady(id, layout: offscreen))
        XCTAssertTrue(MediaRowEpisodeEntryPolicy.showsPlaceholder(
            phase: .ready, targetReady: false, focusEngaged: false
        ))
        let onscreen = MediaRowEntryLayout(
            target: .init(id: id, frame: CGRect(x: 100, y: 0, width: 496, height: 380)),
            viewportWidth: 1920
        )
        XCTAssertTrue(MediaRowEpisodeEntryPolicy.targetReady(id, layout: onscreen))
        XCTAssertFalse(MediaRowEpisodeEntryPolicy.showsPlaceholder(
            phase: .ready, targetReady: true, focusEngaged: false
        ))
        XCTAssertFalse(MediaRowEpisodeEntryPolicy.targetReady("other-season", layout: onscreen))
    }

    #if canImport(UIKit)
    @MainActor
    final class EpisodeRowEntryPlaceholderRenderingTests: XCTestCase {
        func testStatusStaysBelowAnOpaqueThumbnailInEveryFocusStyle() throws {
            for focusStyle in CardFocusStyle.allCases {
                for phase in [
                    MediaRowEpisodeEntry.Phase.loading, .ready, .empty, .failed
                ] {
                    for focused in [false, true] {
                        let renderer = ImageRenderer(content:
                            EpisodeRowEntryPlaceholder(phase: phase, showsStatus: true, isFocused: focused)
                                .environment(\.themePalette, .dark)
                                .environment(\.plozzCardFocusStyle, focusStyle)
                                .transaction { $0.animation = nil }
                                .padding(80)
                        )
                        renderer.scale = 1
                        let image = try XCTUnwrap(renderer.uiImage)
                        let bitmap = try pixels(image)
                        // The center remains one opaque surface, without loading text
                        // or the focus backing showing through the thumbnail.
                        for y in stride(from: 120, through: 300, by: 12) {
                            for x in stride(from: 140, through: 500, by: 12) {
                                let pixel = (y * bitmap.width + x) * 4
                                if focusStyle == .highlight && focused {
                                    XCTAssertLessThan(bitmap.bytes[pixel], 100)
                                    XCTAssertLessThan(bitmap.bytes[pixel + 1], 100)
                                    XCTAssertLessThan(bitmap.bytes[pixel + 2], 100)
                                } else {
                                    XCTAssertEqual(Int(bitmap.bytes[pixel]), 26, accuracy: 2)
                                    XCTAssertEqual(Int(bitmap.bytes[pixel + 1]), 26, accuracy: 2)
                                    XCTAssertEqual(Int(bitmap.bytes[pixel + 2]), 31, accuracy: 2)
                                }
                                XCTAssertEqual(bitmap.bytes[pixel + 3], 255)
                            }
                        }
                        XCTAssertEqual(image.size.width, EpisodeColumnCard.slotWidth + 160, accuracy: 1)
                    }
                }
            }
        }

        func testLoadingAndRetryStatesKeepTheSameLayoutOnFocus() throws {
            var expected: CGSize?
            for phase in [
                MediaRowEpisodeEntry.Phase.loading, .ready, .empty, .failed
            ] {
                for focused in [false, true] {
                    let renderer = ImageRenderer(content:
                        EpisodeRowEntryPlaceholder(phase: phase, showsStatus: true, isFocused: focused)
                            .transaction { $0.animation = nil }
                    )
                    let size = try XCTUnwrap(renderer.uiImage).size
                    if let expected {
                        XCTAssertEqual(size, expected)
                    } else {
                        expected = size
                    }
                }
            }
        }

        private func pixels(_ image: UIImage) throws -> (width: Int, bytes: [UInt8]) {
            let cgImage = try XCTUnwrap(image.cgImage)
            var bytes = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
            try bytes.withUnsafeMutableBytes { buffer in
                let context = try XCTUnwrap(CGContext(
                    data: buffer.baseAddress, width: cgImage.width, height: cgImage.height,
                    bitsPerComponent: 8, bytesPerRow: cgImage.width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ))
                context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
            }
            return (cgImage.width, bytes)
        }
    }
    #endif

    func testUnknownGeometryNeverCountsAsARealizedTarget() {
        XCTAssertFalse(MediaRowEpisodeEntryPolicy.targetReady("episode", layout: .init()))
        XCTAssertFalse(MediaRowEpisodeEntryPolicy.targetReady("episode", layout: .init(
            target: .init(id: "episode", frame: .zero), viewportWidth: 1920
        )))
        XCTAssertFalse(MediaRowEpisodeEntryPolicy.targetReady("episode", layout: .init(
            target: .init(id: "episode", frame: CGRect(x: -250, y: 0, width: 496, height: 380)),
            viewportWidth: 1920
        )))
    }

    func testBrowsingDoesNotResurrectAnEntryGateDuringLazyRecycling() {
        XCTAssertFalse(MediaRowEpisodeEntryPolicy.showsPlaceholder(
            phase: .ready, targetReady: false, focusEngaged: true
        ))
    }

    func testFirstEntryUsesResumeAndLaterEntryRemembersTheBrowsedEpisode() {
        let ids = Set((0..<1000).map { "episode-\($0)" })
        XCTAssertEqual(MediaRowEpisodeEntryPolicy.target(
            rememberedID: nil, defaultID: "episode-998", itemIDs: ids, firstID: "episode-0"
        ), "episode-998")
        XCTAssertEqual(MediaRowEpisodeEntryPolicy.target(
            rememberedID: "episode-650", defaultID: "episode-998", itemIDs: ids, firstID: "episode-0"
        ), "episode-650")
        XCTAssertEqual(MediaRowEpisodeEntryPolicy.target(
            rememberedID: "other-season", defaultID: "episode-998", itemIDs: ids, firstID: "episode-0"
        ), "episode-998")
        XCTAssertNil(MediaRowEpisodeEntryPolicy.target(
            rememberedID: nil, defaultID: "not-loaded-yet", itemIDs: ids, firstID: "episode-0"
        ))
    }

    func testLoadingEmptyAndFailedStatesKeepAnHonestFocusableDestination() {
        for phase in [MediaRowEpisodeEntry.Phase.loading, .empty, .failed] {
            XCTAssertTrue(MediaRowEpisodeEntryPolicy.showsPlaceholder(
                phase: phase, targetReady: false, focusEngaged: false
            ))
        }
    }
}
