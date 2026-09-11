import Foundation
import CoreModels
import CoreNetworking

extension JellyfinProvider: ServerLiveTVProviding {
    public func liveTVAvailability() async throws -> ServerLiveTVAvailability {
        do {
            let info = try JSONDecoder().decode(
                JellyfinLiveTVInfo.self,
                from: await client.liveTVSend(Endpoint(path: "/LiveTv/Info"))
            )
            guard info.IsEnabled != false else {
                return ServerLiveTVAvailability(status: .notConfigured)
            }
            if let users = info.EnabledUsers, !users.contains(where: {
                Self.liveTVUserIdentity($0) == Self.liveTVUserIdentity(session.userID)
            }) {
                return ServerLiveTVAvailability(status: .permissionDenied)
            }
            let channels = try await liveTVChannels()
            let unavailable = !(info.Services ?? []).isEmpty
                && (info.Services ?? []).allSatisfy { $0.Status == "Unavailable" }
            return ServerLiveTVAvailability(
                status: channels.isEmpty ? (unavailable ? .serviceUnavailable : .noChannels) : .available,
                channelCount: channels.count
            )
        } catch ServerLiveTVError.permissionDenied {
            return ServerLiveTVAvailability(status: .permissionDenied)
        } catch ServerLiveTVError.subscriptionRequired {
            return ServerLiveTVAvailability(status: .subscriptionRequired)
        } catch AppError.notFound {
            return ServerLiveTVAvailability(status: .unsupportedAPI, supportsGuide: false)
        }
    }

    public func liveTVChannels() async throws -> [ServerLiveTVChannel] {
        let items = try await liveTVItems(
            path: "/LiveTv/Channels",
            query: [
                URLQueryItem(name: "AddCurrentProgram", value: "true"),
                URLQueryItem(name: "EnableUserData", value: "false")
            ]
        )
        return items.compactMap { item in
            guard let id = item.Id, Self.validLiveTVItemID(id) else { return nil }
            let current = item.CurrentProgram.flatMap { programme in
                Self.liveTVProgramme(
                    id: programme.Id,
                    channelID: programme.ChannelId ?? id,
                    title: programme.Name,
                    subtitle: programme.EpisodeTitle,
                    overview: programme.Overview,
                    start: programme.StartDate,
                    end: programme.EndDate,
                    categories: programme.Genres
                )
            }

            return ServerLiveTVChannel(
                id: id,
                name: item.Name?.nilIfLiveTVEmpty ?? id,
                number: item.ChannelNumber,
                imageURL: client.imageURL(
                    itemID: id, kind: .primary, maxWidth: 400,
                    tag: item.ImageTags?["Primary"]
                ),
                isRadio: item.ChannelType?.caseInsensitiveCompare("Radio") == .orderedSame,
                currentProgramme: current?.channelID == id ? current : nil
            )
        }
    }

    private static func liveTVUserIdentity(_ value: String) -> String {
        let compact = value.replacingOccurrences(of: "-", with: "").lowercased()
        guard compact.utf8.count == 32, compact.utf8.allSatisfy({
            (48...57).contains($0) || (97...102).contains($0)
        }) else { return value }
        return compact
    }

    public func liveTVGuide(
        channelIDs: [String],
        from: Date,
        to: Date
    ) async throws -> [ServerLiveTVProgramme] {
        guard !channelIDs.isEmpty else { return [] }
        guard from.timeIntervalSince1970.isFinite, to.timeIntervalSince1970.isFinite,
              to > from, to.timeIntervalSince(from) <= 172_800,
              channelIDs.count <= 2_000 else {
            throw ServerLiveTVError.invalidGuideWindow
        }
        guard channelIDs.allSatisfy(Self.validLiveTVItemID) else {
            throw ServerLiveTVError.invalidChannel
        }
        let ids = Array(Set(channelIDs)).sorted()
        let requested = Set(ids)
        let formatter = ISO8601DateFormatter()
        var programmes: [String: ServerLiveTVProgramme] = [:]
        for offset in stride(from: 0, to: ids.count, by: 80) {
            let batch = ids[offset..<min(ids.count, offset + 80)]
            let items = try await liveTVItems(
                path: "/LiveTv/Programs",
                query: [
                    URLQueryItem(name: "ChannelIds", value: batch.joined(separator: ",")),
                    // Overlap, rather than start-within, preserves in-progress airings.
                    URLQueryItem(name: "MinEndDate", value: formatter.string(from: from)),
                    URLQueryItem(name: "MaxStartDate", value: formatter.string(from: to)),
                    URLQueryItem(name: "SortBy", value: "StartDate"),
                    URLQueryItem(name: "EnableUserData", value: "false")
                ]
            )
            for item in items {
                guard let channelID = item.ChannelId, requested.contains(channelID),
                      let programme = Self.liveTVProgramme(
                        id: item.Id, channelID: channelID, title: item.Name,
                        subtitle: item.EpisodeTitle, overview: item.Overview,
                        start: item.StartDate, end: item.EndDate, categories: item.Genres
                      ),
                      programme.startDate < to, programme.endDate > from else { continue }
                programmes[programme.id] = programme
            }
        }
        return programmes.values.sorted {
            ($0.startDate, $0.channelID, $0.id) < ($1.startDate, $1.channelID, $1.id)
        }
    }

    public func openLiveTVChannel(id: String) async throws -> any LiveTVStreamLease {
        guard Self.validLiveTVItemID(id) else { throw ServerLiveTVError.invalidChannel }
        try Task.checkCancellation()
        guard await !liveTVLeases.isRetired else { throw CancellationError() }

        // A non-cancelled request must observe even a late successful response:
        // cancelling URLSession mid-open can otherwise lose the allocated tuner ID.
        let openingClient = client
        let userID = session.userID
        let negotiationData = try await Task.detached {
            try await openingClient.liveTVPlaybackInfo(userID: userID, itemID: id)
        }.value
        let raw = (try? JSONSerialization.jsonObject(with: negotiationData)) as? [String: Any]
        let playSessionID = (raw?["PlaySessionId"] as? String)?.nilIfLiveTVEmpty
        let resources = JellyfinLiveTVResources(
            client: openingClient, itemID: id, playSessionID: playSessionID,
            store: liveTVLeases
        )
        let selectedSource = (raw?["MediaSources"] as? [[String: Any]])?.first
        await resources.adopt(liveStreamID: selectedSource?["LiveStreamId"] as? String)
        do {
            let response = try JSONDecoder().decode(
                JellyfinLiveTVPlaybackResponse.self, from: negotiationData
            )
            switch response.ErrorCode {
            case nil: break
            case "NotAllowed": throw ServerLiveTVError.permissionDenied
            case "NoCompatibleStream": throw ServerLiveTVError.noCompatibleStream
            case "RateLimitExceeded": throw AppError.rateLimited(retryAfter: nil)
            default: throw AppError.invalidResponse
            }
            try Task.checkCancellation()
            guard var source = response.MediaSources?.first else {
                throw ServerLiveTVError.noCompatibleStream
            }
            if source.RequiresOpening == true, source.LiveStreamId?.nilIfLiveTVEmpty == nil {
                guard let token = source.OpenToken?.nilIfLiveTVEmpty else {
                    throw AppError.invalidResponse
                }
                let openedData = try await Task.detached {
                    try await openingClient.liveTVOpen(
                        userID: userID, itemID: id, openToken: token,
                        playSessionID: playSessionID
                    )
                }.value
                // Capture cleanup identity before decoding other fields, which
                // could fail after the server has successfully opened the tuner.
                let opened = (try? JSONSerialization.jsonObject(with: openedData)) as? [String: Any]
                let rawSource = opened?["MediaSource"] as? [String: Any]
                await resources.adopt(liveStreamID: rawSource?["LiveStreamId"] as? String)
                source = try JSONDecoder().decode(
                    JellyfinLiveTVOpenResponse.self, from: openedData
                ).MediaSource
                guard source.LiveStreamId?.nilIfLiveTVEmpty != nil else {
                    throw AppError.invalidResponse
                }
            }
            try Task.checkCancellation()
            guard source.LiveStreamId?.nilIfLiveTVEmpty != nil else {
                // "Direct" describes delivery, not the absence of tuner ownership.
                // Never trigger an implicit tune for which we cannot later close
                // a server-issued handle.
                throw ServerLiveTVError.unsupportedPlaybackMode
            }
            await resources.setSource(
                mediaSourceID: source.Id,
                liveStreamID: source.LiveStreamId
            )
            let playbackSource = try liveTVPlaybackSource(
                source, itemID: id, playSessionID: playSessionID
            )
            guard await liveTVLeases.register(resources) else { throw CancellationError() }
            try Task.checkCancellation()
            return JellyfinLiveTVLease(playbackSource: playbackSource, resources: resources)
        } catch {
            await resources.close()
            throw error
        }
    }

    private func liveTVItems(
        path: String,
        query: [URLQueryItem]
    ) async throws -> [JellyfinLiveTVItem] {
        let limit = 200
        var offset = 0
        var result: [JellyfinLiveTVItem] = []
        var seen: Set<String> = []
        for _ in 0..<100 {
            try Task.checkCancellation()
            let data = try await client.liveTVSend(Endpoint(
                path: path,
                queryItems: query + [
                    URLQueryItem(name: "UserId", value: session.userID),
                    URLQueryItem(name: "StartIndex", value: String(offset)),
                    URLQueryItem(name: "Limit", value: String(limit))
                ]
            ))
            let page = try JSONDecoder().decode(JellyfinLiveTVPage.self, from: data)
            if page.Items.isEmpty {
                guard page.TotalRecordCount == nil || offset >= page.TotalRecordCount! else {
                    throw AppError.invalidResponse
                }
                return result
            }
            let before = seen.count
            for item in page.Items {
                guard let id = item.Id else { continue }
                let key = "\(id)|\(item.ChannelId ?? "")|\(item.StartDate ?? "")"
                if seen.insert(key).inserted { result.append(item) }
            }
            guard seen.count > before else { throw AppError.invalidResponse }
            offset += page.Items.count
            if let total = page.TotalRecordCount {
                guard total >= 0 else { throw AppError.invalidResponse }
                if offset >= total { return result }
            } else if page.Items.count < limit {
                return result
            }
        }
        throw AppError.invalidResponse
    }

    private static func validLiveTVItemID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 256
            && id.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0)
                    || (97...122).contains($0) || $0 == 45 || $0 == 95
            }
    }

    private static func liveTVProgramme(
        id: String?, channelID: String, title: String?, subtitle: String?,
        overview: String?, start: String?, end: String?, categories: [String]?
    ) -> ServerLiveTVProgramme? {
        guard let id, let title = title?.nilIfLiveTVEmpty,
              let start, let end else { return nil }
        func date(_ value: String) -> Date? {
            (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value))
                ?? (try? Date.ISO8601FormatStyle().parse(value))
        }
        guard let startDate = date(start), let endDate = date(end),
              endDate > startDate else { return nil }
        return ServerLiveTVProgramme(
            id: "\(id)|\(channelID)|\(startDate.timeIntervalSince1970)",
            channelID: channelID, title: title, subtitle: subtitle,
            overview: overview, startDate: startDate, endDate: endDate,
            categories: categories ?? []
        )
    }

    private func liveTVPlaybackSource(
        _ source: JellyfinLiveTVMediaSource,
        itemID: String,
        playSessionID: String?
    ) throws -> PlaybackSource {
        let resource: AuthenticatedHTTPResource
        let delivery: AuthenticatedHTTPDeliveryMode
        let container: String?
        let advertisedContainer = source.Container?.lowercased().nilIfLiveTVEmpty
        let manifestContainer = ["hls", "m3u", "m3u8", "dash", "mpd"]
            .contains(advertisedContainer ?? "")
        if (source.SupportsDirectPlay == true || source.SupportsDirectStream == true),
           !manifestContainer {
            guard let mediaSourceID = source.Id?.nilIfLiveTVEmpty else {
                throw AppError.invalidResponse
            }
            container = advertisedContainer
            if let container {
                guard container.utf8.count <= 20,
                      container.utf8.allSatisfy({
                        (48...57).contains($0) || (97...122).contains($0)
                      }) else { throw ServerLiveTVError.unsupportedPlaybackMode }
            }
            var query = [
                try AuthenticatedHTTPQueryItem(name: "Static", value: "true"),
                try AuthenticatedHTTPQueryItem(name: "MediaSourceId", value: mediaSourceID),
                try AuthenticatedHTTPQueryItem(name: "DeviceId", value: session.deviceID)
            ]
            if let liveID = source.LiveStreamId?.nilIfLiveTVEmpty {
                query.append(try AuthenticatedHTTPQueryItem(name: "LiveStreamId", value: liveID))
            }
            let suffix = container.map { ".\($0)" } ?? ""
            let streams = source.MediaStreams ?? []
            let audioOnly = streams.contains { $0.Type?.lowercased() == "audio" }
                && !streams.contains { $0.Type?.lowercased() == "video" }
            resource = try AuthenticatedHTTPResource(
                pathBase: .configuredBaseURL,
                path: "\(audioOnly ? "Audio" : "Videos")/\(itemID)/stream\(suffix)",
                queryItems: query
            )
            delivery = .directFile
        } else if let path = source.TranscodingUrl?.nilIfLiveTVEmpty {
            guard let playSessionID, let liveStreamID = source.LiveStreamId else {
                throw ServerLiveTVError.unsupportedPlaybackMode
            }
            resource = try liveTVTranscodingResource(
                path, liveStreamID: liveStreamID, playSessionID: playSessionID
            )
            guard source.TranscodingSubProtocol?.lowercased() == "hls"
                    || resource.path.lowercased().hasSuffix(".m3u8") else {
                throw ServerLiveTVError.unsupportedPlaybackMode
            }
            delivery = .hls
            container = "m3u8"
        } else {
            if manifestContainer { throw ServerLiveTVError.unsupportedPlaybackMode }
            throw ServerLiveTVError.noCompatibleStream
        }
        return .authenticatedHTTP(try AuthenticatedHTTPPlaybackLocator(
            provider: kind, accountID: accountID, credentialRevision: credentialRevision,
            itemID: itemID, mediaSourceID: source.Id, deliveryMode: delivery,
            formatHint: MediaFormatHint(container: container), resource: resource,
            playSessionID: playSessionID
        ))
    }

    private func liveTVTranscodingResource(
        _ value: String, liveStreamID: String, playSessionID: String
    ) throws -> AuthenticatedHTTPResource {
        guard let components = URLComponents(string: value),
              components.user == nil, components.password == nil,
              components.fragment == nil, !value.hasPrefix("//"),
              let origin = URLComponents(url: client.baseURL, resolvingAgainstBaseURL: false) else {
            throw ServerLiveTVError.unsupportedPlaybackMode
        }
        var pathBase: AuthenticatedHTTPResource.PathBase = .configuredBaseURL
        if components.scheme != nil || components.host != nil {
            func port(_ components: URLComponents) -> Int? {
                components.port ?? (components.scheme?.lowercased() == "https" ? 443 : 80)
            }
            guard components.scheme?.lowercased() == origin.scheme?.lowercased(),
                  components.host?.lowercased() == origin.host?.lowercased(),
                  port(components) == port(origin) else {
                throw ServerLiveTVError.unsupportedPlaybackMode
            }
            pathBase = .serverRoot
        } else {
            let prefix = origin.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let path = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !prefix.isEmpty, path == prefix || path.hasPrefix(prefix + "/") {
                pathBase = .serverRoot
            }
        }
        let removed = Set(["api_key", "apikey", "playsessionid", "token", "x-mediabrowser-token"])
        var query = try (components.queryItems ?? []).compactMap { item -> AuthenticatedHTTPQueryItem? in
            if item.name.lowercased() == "livestreamid" {
                guard item.value == liveStreamID else { throw AppError.invalidResponse }
                return nil
            }
            if item.name.lowercased() == "playsessionid", item.value != playSessionID {
                throw AppError.invalidResponse
            }
            if removed.contains(item.name.lowercased()) { return nil }
            return try AuthenticatedHTTPQueryItem(name: item.name, value: item.value)
        }
        query.append(try AuthenticatedHTTPQueryItem(name: "LiveStreamId", value: liveStreamID))
        let relativePath = components.percentEncodedPath.trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        )
        return try AuthenticatedHTTPResource(
            pathBase: pathBase,
            path: pathBase == .serverRoot ? "/" + relativePath : relativePath,
            queryItems: query
        )
    }
}

extension JellyfinProvider: ProviderTeardown {
    public func teardown() async {
        await liveTVLeases.closeAll()
    }
}

private extension String {
    var nilIfLiveTVEmpty: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}

private struct JellyfinLiveTVLease: LiveTVStreamLease {
    let playbackSource: PlaybackSource
    let resources: JellyfinLiveTVResources

    func report(_ update: LiveTVPlaybackUpdate) async {
        await resources.report(update)
    }

    func close() async {
        await resources.close()
    }
}

actor JellyfinLiveTVLeaseStore {
    private var resources: [UUID: JellyfinLiveTVResources] = [:]
    private(set) var isRetired = false

    func register(_ resource: JellyfinLiveTVResources) -> Bool {
        guard !isRetired else { return false }
        resources[resource.id] = resource
        return true
    }

    func remove(_ id: UUID) {
        resources.removeValue(forKey: id)
    }

    func closeAll() async {
        isRetired = true
        let pending = Array(resources.values)
        resources.removeAll()
        for resource in pending { await resource.close() }
    }
}

actor JellyfinLiveTVResources {
    nonisolated let id = UUID()
    private let client: JellyfinClient
    private let itemID: String
    private let playSessionID: String?
    private let store: JellyfinLiveTVLeaseStore
    private var mediaSourceID: String?
    private var liveStreamID: String?
    private var ownedLiveStreamIDs: Set<String> = []
    private var started = false
    private var lastPosition: TimeInterval = 0
    private var lastReport: Task<Void, Never>?
    private var cleanup: Task<Void, Never>?

    init(
        client: JellyfinClient, itemID: String, playSessionID: String?,
        store: JellyfinLiveTVLeaseStore
    ) {
        self.client = client
        self.itemID = itemID
        self.playSessionID = playSessionID
        self.store = store
    }

    func adopt(liveStreamID: String?) {
        if let liveStreamID = liveStreamID?.nilIfLiveTVEmpty {
            ownedLiveStreamIDs.insert(liveStreamID)
        }
    }

    func setSource(mediaSourceID: String?, liveStreamID: String?) {
        self.mediaSourceID = mediaSourceID
        self.liveStreamID = liveStreamID
        adopt(liveStreamID: liveStreamID)
    }

    func report(_ update: LiveTVPlaybackUpdate) async {
        guard cleanup == nil else { return }
        if update.state == .started, started { return }
        let path = started ? "/Sessions/Playing/Progress" : "/Sessions/Playing"
        started = true
        lastPosition = update.positionSeconds
        let body = progressBody(position: update.positionSeconds, paused: update.state == .paused)
        let previous = lastReport
        let client = client
        let task = Task.detached {
            await previous?.value
            do {
                try await client.liveTVReport(body, path: path)
            } catch {
                PlozzLog.playback.error("Live TV session report could not be confirmed.")
            }
        }
        lastReport = task
        await task.value
    }

    func close() async {
        if let cleanup {
            await cleanup.value
            return
        }
        let previous = lastReport
        let client = client
        let stopped = started ? progressBody(position: lastPosition, paused: false) : nil
        let liveIDs = ownedLiveStreamIDs.sorted()
        let playSessionID = playSessionID
        let store = store
        let id = id
        let task = Task.detached {
            await previous?.value
            if let stopped {
                do {
                    try await client.liveTVReport(stopped, path: "/Sessions/Playing/Stopped")
                } catch {
                    PlozzLog.playback.error("Live TV playback-stop report could not be confirmed.")
                }
            }
            for liveID in liveIDs {
                do {
                    try await client.liveTVClose(liveStreamID: liveID)
                } catch {
                    PlozzLog.playback.error("Live TV stream release could not be confirmed.")
                }
            }
            if let playSessionID {
                do {
                    try await client.liveTVStopEncoding(playSessionID: playSessionID)
                } catch {
                    PlozzLog.playback.error("Live TV session-scoped encoding stop could not be confirmed.")
                }
            }
            await store.remove(id)
        }
        cleanup = task
        await task.value
    }

    private func progressBody(position: TimeInterval, paused: Bool) -> JellyfinLiveTVProgressBody {
        JellyfinLiveTVProgressBody(
            ItemId: itemID, MediaSourceId: mediaSourceID,
            LiveStreamId: liveStreamID, PlaySessionId: playSessionID,
            PositionTicks: Int64(position * 10_000_000), IsPaused: paused
        )
    }
}
