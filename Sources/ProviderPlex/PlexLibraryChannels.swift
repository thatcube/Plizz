import CoreModels
import Foundation

extension PlexProvider: LibraryChannelCatalogProviding, LibraryChannelPlaybackProviding {
    public func libraryChannelItems(
        in libraryID: String, kind: MediaItemKind, page: PageRequest
    ) async throws -> MediaPage {
        guard [.movie, .episode, .series].contains(kind), (1...500).contains(page.limit), page.startIndex >= 0 else {
            throw LibraryChannelError.invalidRecipe
        }
        // PMS type=4 selects concrete episodes recursively, not type=2 shows.
        let result = try await client.sectionItems(
            sectionID: libraryID, type: kind == .movie ? 1 : (kind == .series ? 2 : 4),
            start: page.startIndex, size: page.limit, sort: page.sort
        )
        guard let total = result.totalSize,
              result.offset.map({ $0 == page.startIndex }) ?? true else { throw LibraryChannelError.invalidSnapshot }
        let items = (result.Metadata ?? []).map { dto in
            var item = map(metadata: dto)
            item.libraryID = libraryID
            if let media = dto.Media?.first, let id = media.id {
                item.selectedVersionID = String(id)
                item.versions = [MediaVersion(
                    id: String(id), edition: dto.editionTitle, sizeBytes: media.Part?.first?.size,
                    duration: media.duration.map { Double($0) / 1_000 },
                    sourceMetadata: MediaSourceMetadata(sourceRevision: media.Part?.first?.id.map(String.init))
                )]
                if let duration = media.duration { item.runtime = Double(duration) / 1_000 }
            }
            return item
        }
        return MediaPage(items: items, startIndex: page.startIndex, totalCount: total)
    }

    public func libraryChannelPlayback(for item: LibraryChannelItem) async throws -> PlaybackRequest {
        guard item.library.accountID == accountID, item.serverID == session.server.id,
              item.userID == session.userID else { throw LibraryChannelError.authorizationChanged }
        let detail = try await client.metadata(ratingKey: item.itemID)
        // Plex's plex-for-kodi PlexPlayer.buildDirectPlay uses the original part
        // key; it is separate from timeline reporting and transcode lifecycle.
        // https://github.com/plexinc/plex-for-kodi/blob/master/lib/_included_packages/plexnet/plexplayer.py
        let media = item.mediaSourceID.flatMap { id in detail.Media?.first { $0.id.map(String.init) == id } }
            ?? (item.mediaSourceID == nil ? detail.Media?.first : nil)
        guard let media, let parts = media.Part, parts.count == 1, let part = parts.first,
              let key = part.key, key.hasPrefix("/library/parts/"),
              let url = client.streamURL(forPartKey: key) else {
            throw LibraryChannelError.incompatiblePlaybackMode
        }
        var mapped = map(metadata: detail)
        guard mapped.kind == item.kind, mapped.id == item.itemID,
              let duration = mapped.runtime, duration.isFinite, (1...604_800).contains(duration),
              Int64(duration.rounded(.down)) == item.durationSeconds,
              item.sourceSizeBytes.map({ $0 == part.size }) ?? true,
              item.sourceRevision.map({ $0 == part.id.map(String.init) }) ?? true,
              item.edition.map({ $0 == detail.editionTitle }) ?? true else {
            throw LibraryChannelError.mediaChanged
        }
        let sourceID = media.id.map(String.init)
        let locator = try authenticatedPlaybackLocator(
            itemID: item.itemID, mediaSourceID: sourceID, url: url,
            deliveryMode: .directFile, purpose: .mediaStream, playSessionID: nil,
            formatHint: media.container ?? part.container
        )
        mapped.resumePosition = nil
        mapped.libraryID = item.library.libraryID
        let streams = part.Stream ?? []
        var request = PlaybackRequest(
            item: mapped, playbackSource: .authenticatedHTTP(locator),
            audioTracks: try streams.filter { $0.streamType == 2 }.map {
                try map(stream: $0, itemID: item.itemID, mediaSourceID: sourceID)
            },
            subtitleTracks: try streams.filter { $0.streamType == 3 }.map {
                try map(stream: $0, itemID: item.itemID, mediaSourceID: sourceID)
            },
            startPosition: 0, deliveryMode: .directPlay, sourceProvider: .plex, serverName: session.server.name
        )
        request.suppressOrdinaryWatchReporting = true
        return request
    }

    public func recordLibraryChannelCompletion(itemID: String) async throws {
        try await client.setWatched(true, ratingKey: itemID)
    }
}
