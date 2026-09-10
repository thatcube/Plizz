#if canImport(UIKit)
import CoreModels
import SwiftUI
import UIKit
import XCTest
@testable import CoreUI

@MainActor
final class EpisodeArtworkPreparationTests: XCTestCase {
    func testPrewarmerUsesTheCardsExplicitReferenceBeforeLegacyURLs() {
        let explicit = URL(string: "https://art.example.test/selected.jpg")!
        let legacy = URL(string: "https://art.example.test/legacy.jpg")!
        var episode = MediaItem(id: "e1", title: "Episode", kind: .episode, posterURL: legacy)
        episode.artworkSelections = [
            ArtworkSelection(placement: .episodeThumbnail, references: [.remote(explicit)])
        ]
        let source = EpisodeArtworkSource(item: episode, spoilerSettings: .default)
        XCTAssertEqual(source.references, episode.artworkReferences(for: .episodeThumbnail))
        XCTAssertEqual(source.references.first, .remote(explicit))
    }

    func testSpoilerSafePreparationNeverUsesTheEpisodeFrame() {
        let still = URL(string: "https://art.example.test/episode.jpg")!
        let show = URL(string: "https://art.example.test/show.jpg")!
        let episode = MediaItem(
            id: "e1", title: "Episode", kind: .episode,
            posterURL: still, fallbackArtworkURL: show
        )
        let visible = EpisodeArtworkSource(item: episode, spoilerSettings: .default)
        let hidden = EpisodeArtworkSource(
            item: episode, spoilerSettings: .init(isEnabled: true, mode: .placeholder)
        )
        XCTAssertEqual(visible.references.first, .remote(still))
        XCTAssertEqual(hidden.references.first, .remote(show))
        XCTAssertFalse(hidden.references.contains(.remote(still)))
        XCTAssertNotEqual(visible.pinIdentity, hidden.pinIdentity)
    }

    func testPosterlessSpoilerModesCannotShareAPreparedImage() {
        let episode = MediaItem(id: "e1", title: "Episode", kind: .episode)
        let visible = EpisodeArtworkSource(item: episode, spoilerSettings: .default)
        let hidden = EpisodeArtworkSource(
            item: episode, spoilerSettings: .init(isEnabled: true, mode: .placeholder)
        )
        XCTAssertTrue(visible.references.isEmpty)
        XCTAssertTrue(hidden.references.isEmpty)
        XCTAssertNotEqual(key(visible), key(hidden))
    }

    func testPreparedOnlineWinnerPaintsSynchronouslyWithoutStartingItsResolver() throws {
        let settingsStore = MetadataProviderSettingsStore()
        let originalSettings = settingsStore.load()
        defer { settingsStore.save(originalSettings) }
        var settings = originalSettings
        settings.preferOnlineArtwork = true
        settingsStore.save(settings)
        let library = URL(string: "https://art.example.test/\(UUID()).jpg")!
        let online = URL(string: "https://art.example.test/\(UUID()).jpg")!
        let episode = MediaItem(id: UUID().uuidString, title: "Episode", kind: .episode, posterURL: library)
        let source = EpisodeArtworkSource(item: episode, spoilerSettings: .default)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let red = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 9), format: format).image {
            UIColor.red.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 16, height: 9))
        }
        ArtworkSeedMemo.store(
            FirstPaintArtwork(image: red, reference: .remote(online), variant: .landscapeCard),
            for: key(source)
        )
        let renderer = ImageRenderer(content:
            FallbackAsyncImage(
                references: source.references, variant: .landscapeCard,
                asyncFallbackURL: { nil }, pinIdentity: source.pinIdentity
            ) {
                Color.blue
            }
            .frame(width: 16, height: 9)
        )
        renderer.scale = 1
        let rendered = try XCTUnwrap(renderer.uiImage)
        let color = try centerPixel(rendered)
        XCTAssertGreaterThan(color[0], 240)
        XCTAssertLessThan(color[1], 10)
        XCTAssertLessThan(color[2], 10)
        XCTAssertEqual(
            ArtworkSeedMemo.prepared(for: key(source), variant: .landscapeCard)?.reference,
            .remote(online)
        )
    }

    func testPreparedWinnerIsIsolatedByPolicyAndSourceAccount() {
        let episode = MediaItem(id: "same-id", title: "Episode", kind: .episode)
        let first = EpisodeArtworkSource(item: episode.taggingSource("one"), spoilerSettings: .default)
        let second = EpisodeArtworkSource(item: episode.taggingSource("two"), spoilerSettings: .default)
        XCTAssertNotEqual(key(first), key(second))
        var settings = MetadataProviderSettings.default
        let onlineKey = key(first, settings: settings)
        settings.preferOnlineArtwork = false
        XCTAssertNotEqual(onlineKey, key(first, settings: settings))
    }

    func testPreparedImagesStayWithinTheDecodedMemoryBudget() {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1600, height: 900), format: format).image {
            UIColor.red.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 1600, height: 900))
        }
        let prefix = UUID().uuidString
        for index in 0..<30 {
            ArtworkSeedMemo.store(image, for: "\(prefix)-\(index)")
            XCTAssertLessThanOrEqual(ArtworkSeedMemo.residentCostBytes, ArtworkSeedMemo.maximumCostBytes)
        }
        XCTAssertNil(ArtworkSeedMemo.value(for: "\(prefix)-0"))
        XCTAssertNotNil(ArtworkSeedMemo.value(for: "\(prefix)-29"))
        ArtworkSeedMemo.removeAll()
        XCTAssertEqual(ArtworkSeedMemo.residentCostBytes, 0)
    }

    private func key(
        _ source: EpisodeArtworkSource,
        settings: MetadataProviderSettings = MetadataProviderSettingsStore().load()
    ) -> String {
        ArtworkResolveKey.make(
            references: source.references, variant: .landscapeCard, maxAspectRatio: nil,
            pinIdentity: source.pinIdentity,
            providerPolicyIdentity: ArtworkResolveKey.policyIdentity(settings)
        )
    }

    private func centerPixel(_ image: UIImage) throws -> [UInt8] {
        let cgImage = try XCTUnwrap(image.cgImage)
        var pixel = [UInt8](repeating: 0, count: 4)
        try pixel.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(
                data: bytes.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return pixel
    }
}
#endif
