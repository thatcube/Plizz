import CoreModels
import Foundation

extension JellyfinProvider: LibraryChannelCatalogProviding, LibraryChannelPlaybackProviding {
    public func libraryChannelItems(
        in libraryID: String, kind: MediaItemKind, page: PageRequest
    ) async throws -> MediaPage {
        guard [.movie, .episode, .series].contains(kind), (1...500).contains(page.limit), page.startIndex >= 0 else {
            throw LibraryChannelError.invalidRecipe
        }
        let response = try await client.items(
            userID: session.userID, parentID: libraryID,
            includeItemTypes: [kind == .movie ? "Movie" : (kind == .series ? "Series" : "Episode")],
            recursive: true, startIndex: page.startIndex, limit: page.limit, sort: page.sort,
            fields: "Genres,OfficialRating,RunTimeTicks,MediaSources,SeriesId,ParentId"
        )
        guard let total = response.TotalRecordCount else { throw LibraryChannelError.invalidSnapshot }
        let items = response.Items.map { dto in
            var item = map(item: dto)
            item.libraryID = libraryID
            if let source = dto.MediaSources?.first, let sourceID = source.Id {
                item.selectedVersionID = sourceID
                item.versions = [MediaVersion(
                    id: sourceID, sizeBytes: source.Size,
                    duration: source.RunTimeTicks.map { Double($0) / 10_000_000 },
                    sourceMetadata: MediaSourceMetadata(sourceRevision: source.ETag)
                )]
                if let ticks = source.RunTimeTicks { item.runtime = Double(ticks) / 10_000_000 }
            }
            return item
        }
        return MediaPage(items: items, startIndex: page.startIndex, totalCount: total)
    }

    public func libraryChannelPlayback(for item: LibraryChannelItem) async throws -> PlaybackRequest {
        guard item.library.accountID == accountID, item.serverID == session.server.id,
              item.userID == session.userID else { throw LibraryChannelError.authorizationChanged }
        // VideosController.GetVideoStream returns original static files, except
        // disc/infinite sources. SessionManager.OnPlaybackProgress/Stopped mutate
        // user data; Emby's Playback-Check-ins docs specify the same check-ins.
        // https://github.com/jellyfin/jellyfin/blob/master/Jellyfin.Api/Controllers/VideosController.cs
        // https://github.com/jellyfin/jellyfin/blob/master/Emby.Server.Implementations/Session/SessionManager.cs
        // https://github.com/MediaBrowser/Emby/wiki/Playback-Check-ins
        let detail = try await client.item(userID: session.userID, id: item.itemID)
        let sources = detail.MediaSources ?? []
        let source = item.mediaSourceID.flatMap { id in sources.first { $0.Id == id } }
            ?? (item.mediaSourceID == nil ? sources.first : nil)
        guard let source, let container = source.Container, !container.isEmpty,
              detail.LocationType != "Virtual", source.SupportsDirectPlay != false,
              source.RequiresOpening != true, source.RequiresClosing != true,
              source.IsInfiniteStream != true,
              !["bluray", "dvd", "iso"].contains(source.VideoType?.lowercased() ?? ""),
              container.lowercased() != "iso" else {
            throw LibraryChannelError.incompatiblePlaybackMode
        }
        var mapped = map(item: detail)
        guard mapped.id == item.itemID, mapped.kind == item.kind,
              let duration = mapped.runtime, duration.isFinite, (1...604_800).contains(duration),
              Int64(duration.rounded(.down)) == item.durationSeconds,
              source.RunTimeTicks.map({ $0 / 10_000_000 == item.durationSeconds }) ?? true,
              item.sourceSizeBytes.map({ $0 == source.Size }) ?? true,
              item.sourceRevision.map({ $0 == source.ETag }) ?? true else {
            throw LibraryChannelError.mediaChanged
        }
        let locator = try authenticatedPlaybackLocator(
            itemID: item.itemID, source: source, playSessionID: nil,
            didRemux: false, forceDirect: true
        )
        mapped.resumePosition = nil
        mapped.libraryID = item.library.libraryID
        let streams = source.MediaStreams ?? detail.MediaStreams ?? []
        var request = PlaybackRequest(
            item: mapped, playbackSource: .authenticatedHTTP(locator),
            audioTracks: streams.filter { $0.Type == "Audio" }.map(map(stream:)),
            subtitleTracks: try streams.filter { $0.Type == "Subtitle" }.map {
                try map(subtitleStream: $0, itemID: item.itemID, sourceID: source.Id ?? item.itemID)
            },
            startPosition: 0, deliveryMode: .directPlay,
            originalFileSource: .authenticatedHTTP(locator), sourceProvider: kind,
            serverName: session.server.name
        )
        request.suppressOrdinaryWatchReporting = true
        return request
    }

    public func recordLibraryChannelCompletion(itemID: String) async throws {
        try await client.setItemPlayed(true, userID: session.userID, itemID: itemID)
    }
}
