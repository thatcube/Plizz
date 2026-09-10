import CoreModels
import Foundation
import MetadataKit

/// Shared by the episode card and its warmer so source preference, explicit
/// artwork references, and spoiler protection select the same image.
public struct EpisodeArtworkSource: Sendable {
    public let references: [ArtworkReference]
    public let pinIdentity: String
    public let fallbackURL: @Sendable () async -> URL?

    public init(item: MediaItem, spoilerSettings: SpoilerSettings) {
        let hidesStill = spoilerSettings.mode == .placeholder
            && spoilerSettings.shouldHideThumbnail(for: item)
        references = hidesStill
            ? item.seriesArtworkReferences()
            : item.artworkReferences(for: .episodeThumbnail)
        // Posterless episode and spoiler-safe show art otherwise have the same
        // empty reference list. Their prepared images must never share a key.
        pinIdentity = "\(item.stablePresentationID)|\(hidesStill ? "series-artwork" : "episode-artwork")"
        let subject = hidesStill ? PosterCardView.seriesArtworkItem(for: item) : item
        fallbackURL = {
            if !hidesStill,
               let still = await ArtworkRouter.shared.artworkURL(.thumbnail, for: subject) {
                return still
            }
            return await ArtworkRouter.shared.artworkURL(.hero, for: subject)
                ?? subject.fallbackArtworkURL
        }
    }

    #if canImport(UIKit)
    @MainActor
    public func prepare() async {
        await ArtworkFirstPaintResolver.prepare(
            references: references, variant: .landscapeCard,
            asyncOnlineURL: fallbackURL, pinIdentity: pinIdentity
        )
    }
    #endif
}
