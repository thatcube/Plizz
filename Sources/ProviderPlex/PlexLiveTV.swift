import Foundation
import CoreModels
import CoreNetworking

extension PlexProvider: ServerLiveTVProviding {
    public func liveTVAvailability() async throws -> ServerLiveTVAvailability {
        do {
            let providers = try await liveTVEPGs()
            if providers.isEmpty {
                return ServerLiveTVAvailability(status: .notConfigured, supportsGuide: false)
            }
            let channels = try await liveTVReferences(providers: providers)
            return ServerLiveTVAvailability(
                status: channels.isEmpty ? .noChannels : .available,
                channelCount: channels.count,
                supportsGuide: providers.contains { $0.gridPath != nil }
            )
        } catch ServerLiveTVError.permissionDenied {
            return ServerLiveTVAvailability(status: .permissionDenied, supportsGuide: false)
        } catch ServerLiveTVError.subscriptionRequired {
            return ServerLiveTVAvailability(status: .subscriptionRequired, supportsGuide: false)
        } catch AppError.notFound {
            return ServerLiveTVAvailability(status: .unsupportedAPI, supportsGuide: false)
        }
    }

    public func liveTVChannels() async throws -> [ServerLiveTVChannel] {
        try await liveTVReferences(providers: liveTVEPGs()).map(\.channel)
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
        let requested = Set(channelIDs)
        let references = try await liveTVReferences(providers: liveTVEPGs())
            .filter { requested.contains($0.channel.id) }
        let dates = Self.liveTVDates(from: from, to: to)
        var requests: [(PlexLiveTVChannelReference, String)] = []
        for reference in references where reference.provider.gridPath != nil {
            guard reference.gridKey != nil else { continue }
            requests += dates.map { (reference, $0) }
        }
        let results = try await withThrowingTaskGroup(
            of: [ServerLiveTVProgramme].self,
            returning: [ServerLiveTVProgramme].self
        ) { group in
            var next = 0
            func enqueue() {
                guard next < requests.count else { return }
                let request = requests[next]
                next += 1
                group.addTask {
                    try await liveTVProgrammes(
                        reference: request.0, date: request.1, from: from, to: to
                    )
                }
            }
            for _ in 0..<min(4, requests.count) { enqueue() }
            var result: [ServerLiveTVProgramme] = []
            while let programmes = try await group.next() {
                result += programmes
                enqueue()
            }
            return result
        }
        let unique = Dictionary(results.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return unique.values.sorted {
            ($0.startDate, $0.channelID, $0.id) < ($1.startDate, $1.channelID, $1.id)
        }
    }

    public func openLiveTVChannel(id: String) async throws -> any LiveTVStreamLease {
        try Task.checkCancellation()
        guard await !liveTVLeases.isRetired else { throw CancellationError() }
        let references = try await liveTVReferences(providers: liveTVEPGs())
        guard let reference = references.first(where: { $0.channel.id == id }),
              let number = reference.channel.number,
              !number.isEmpty, number.utf8.count <= 64,
              number.utf8.allSatisfy({
                  (48...57).contains($0) || (65...90).contains($0)
                      || (97...122).contains($0) || [45, 46, 95].contains($0)
              }) else {
            throw ServerLiveTVError.invalidChannel
        }
        let dvrID = reference.provider.dvrID
        try Task.checkCancellation()
        guard await !liveTVLeases.isRetired else { throw CancellationError() }
        let playbackID = UUID().uuidString
        let openingClient = client
        let resources = PlexLiveTVResources(
            client: openingClient, playbackID: playbackID, store: liveTVLeases
        )
        do {
            // Keep observing a successful allocation even when the caller is
            // cancelled. Losing its response would lose the owned tuner handle.
            let data = try await Task.detached {
                try await openingClient.liveTVSessionRequest(
                    path: "/livetv/dvrs/\(dvrID)/channels/\(number)/tune",
                    method: .post, playbackID: playbackID
                )
            }.value
            let tuned = try PlexLiveTVPlaybackDocument(data: data)
            await resources.adopt(sessionPath: tuned.sessionPath, ratingKey: tuned.ratingKey)
            guard tuned.status == nil || tuned.status == 0 || tuned.status == 200 else {
                throw ServerLiveTVError.tunerUnavailable
            }
            guard let sessionPath = tuned.sessionPath else { throw AppError.invalidResponse }
            try Task.checkCancellation()
            guard await !liveTVLeases.isRetired else { throw CancellationError() }
            let query = Self.liveTVDecisionQuery(sessionPath: sessionPath, playbackID: playbackID)
                + openingClient.liveTVPlaybackIdentityQuery
            let decisionData = try await Task.detached {
                try await openingClient.liveTVSessionRequest(
                    path: "/video/:/transcode/universal/decision",
                    query: query, playbackID: playbackID
                )
            }.value
            let decision = try PlexLiveTVPlaybackDocument(data: decisionData)
            guard decision.sessionPath == nil || decision.sessionPath == sessionPath else {
                throw AppError.invalidResponse
            }
            try Task.checkCancellation()
            guard await !liveTVLeases.isRetired else { throw CancellationError() }
            let resource: AuthenticatedHTTPResource
            if let key = decision.directPlaylist, decision.decisionCode == 1000 {
                resource = try liveTVConsumerResource(
                    key, sessionPath: sessionPath, playbackID: playbackID
                )
            } else {
                guard decision.decisionCode == 1001 else {
                    throw ServerLiveTVError.noCompatibleStream
                }
                resource = try AuthenticatedHTTPResource(
                    pathBase: .configuredBaseURL, path: "video/:/transcode/universal/start.m3u8",
                    queryItems: query.filter { $0.name != "session" }.map {
                        try AuthenticatedHTTPQueryItem(name: $0.name, value: $0.value)
                    }
                )
            }
            // Resolve the server-issued consumer, rather than guessing one from
            // the shared tuner UUID. For transcoding this starts our own job.
            let playlist = try await Task.detached {
                try await openingClient.liveTVSessionRequest(
                    path: "/" + resource.path,
                    query: resource.queryItems.map { URLQueryItem(name: $0.name, value: $0.value) }
                        + [URLQueryItem(name: "session", value: playbackID)],
                    playbackID: playbackID
                )
            }.value
            guard playlist.count <= 2_097_152,
                  String(data: playlist.prefix(128), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") == true else {
                throw AppError.invalidResponse
            }
            try Task.checkCancellation()
            let source = PlaybackSource.authenticatedHTTP(try AuthenticatedHTTPPlaybackLocator(
                provider: .plex, accountID: accountID, credentialRevision: credentialRevision,
                itemID: id, deliveryMode: .hls, formatHint: MediaFormatHint(container: "m3u8"),
                resource: resource, playSessionID: playbackID
            ))
            guard await liveTVLeases.register(resources) else { throw CancellationError() }
            try Task.checkCancellation()
            await resources.startHeartbeat()
            return PlexLiveTVLease(playbackSource: source, resources: resources)
        } catch {
            await resources.close()
            throw error
        }
    }

    private static func liveTVDecisionQuery(
        sessionPath: String, playbackID: String
    ) -> [URLQueryItem] {
        [
            URLQueryItem(name: "path", value: sessionPath),
            URLQueryItem(name: "mediaIndex", value: "0"),
            URLQueryItem(name: "partIndex", value: "0"),
            URLQueryItem(name: "protocol", value: "hls"),
            URLQueryItem(name: "directPlay", value: "1"),
            URLQueryItem(name: "directStream", value: "1"),
            URLQueryItem(name: "directStreamAudio", value: "1"),
            URLQueryItem(name: "hasMDE", value: "1"),
            URLQueryItem(name: "offset", value: "0"),
            URLQueryItem(name: "context", value: "streaming"),
            URLQueryItem(name: "session", value: playbackID),
            URLQueryItem(name: "transcodeSessionId", value: playbackID)
        ]
    }

    private func liveTVConsumerResource(
        _ value: String, sessionPath: String, playbackID: String
    ) throws -> AuthenticatedHTTPResource {
        guard let components = URLComponents(string: value),
              components.user == nil, components.password == nil, components.fragment == nil,
              !value.hasPrefix("//"), !value.contains("\\") else {
            throw AppError.invalidResponse
        }
        if components.scheme != nil || components.host != nil {
            guard let scheme = components.scheme, let host = components.host,
                  let configured = URLComponents(url: client.baseURL, resolvingAgainstBaseURL: false),
                  let configuredScheme = configured.scheme, let configuredHost = configured.host,
                  configured.user == nil, configured.password == nil,
                  configured.query == nil, configured.fragment == nil else {
                throw AppError.invalidResponse
            }
            do {
                guard try NetworkOrigin(scheme: scheme, host: host, port: components.port)
                    == NetworkOrigin(
                        scheme: configuredScheme, host: configuredHost, port: configured.port
                    ) else { throw AppError.invalidResponse }
            } catch is MediaSourceModelError {
                throw AppError.invalidResponse
            }
        }
        let prefix = sessionPath + "/"
        let suffix = "/index.m3u8"
        let basePath = URLComponents(url: client.baseURL, resolvingAgainstBaseURL: false)?
            .percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        var apiPath = components.percentEncodedPath
        if !basePath.isEmpty, apiPath.hasPrefix("/" + basePath + "/") {
            apiPath = String(apiPath.dropFirst(basePath.count + 1))
        }
        guard apiPath.hasPrefix(prefix), apiPath.hasSuffix(suffix) else {
            throw AppError.invalidResponse
        }
        let consumer = String(apiPath.dropFirst(prefix.count).dropLast(suffix.count))
        guard PlexLiveTVPlaybackDocument.validHandle(consumer) else { throw AppError.invalidResponse }
        let identity = client.liveTVPlaybackIdentityQuery
        let identityNames = Set(identity.map { $0.name.lowercased() })
        var query = try (components.queryItems ?? []).compactMap { item -> AuthenticatedHTTPQueryItem? in
            // The resolver supplies this account's current credentials.
            let name = item.name.lowercased()
            if ["x-plex-session-identifier", "session", "transcodesessionid"].contains(name) {
                guard item.value == playbackID else { throw AppError.invalidResponse }
                return nil
            }
            if name == "x-plex-token" { return nil }
            if name == "x-plex-client-identifier", item.value != session.deviceID {
                throw AppError.invalidResponse
            }
            if identityNames.contains(name) { return nil }
            return try AuthenticatedHTTPQueryItem(name: item.name, value: item.value)
        }
        query += try identity.map { try AuthenticatedHTTPQueryItem(name: $0.name, value: $0.value) }
        return try AuthenticatedHTTPResource(
            pathBase: .configuredBaseURL, path: String(apiPath.dropFirst()), queryItems: query
        )
    }

    private func liveTVContainer(
        path: String, query: [URLQueryItem] = []
    ) async throws -> PlexLiveTVContainer {
        try JSONDecoder().decode(
            PlexLiveTVResponse.self,
            from: await client.liveTVGet(path: path, query: query)
        ).MediaContainer
    }

    private func liveTVEPGs() async throws -> [PlexLiveTVEPG] {
        try Task.checkCancellation()
        guard await !liveTVLeases.isRetired else { throw CancellationError() }
        let container = try await liveTVContainer(path: "/media/providers")
        if container.allowTuners?.boolean == false { throw ServerLiveTVError.permissionDenied }
        var seen: Set<String> = []
        return try (container.MediaProvider ?? []).compactMap { provider in
            guard let identifier = provider.identifier,
                  identifier.hasPrefix("tv.plex.providers.epg."),
                  identifier.utf8.count < 256,
                  identifier.utf8.allSatisfy({
                    (48...57).contains($0) || (65...90).contains($0)
                        || (97...122).contains($0) || [45, 46, 58, 95].contains($0)
                  }),
                  provider.protocols?.split(whereSeparator: { $0 == "," || $0 == " " })
                    .contains("livetv") == true,
                  seen.insert(identifier).inserted else { return nil }
            let parts = identifier.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, let dvrID = parts.last, !dvrID.isEmpty,
                  dvrID.utf8.allSatisfy({ (48...57).contains($0) }),
                  provider.parentID == nil || provider.parentID?.string == String(dvrID) else {
                throw AppError.invalidResponse
            }
            let expectedGridPath = "/\(identifier)/grid"
            let gridPath = provider.Feature?.first {
                $0.type == "grid" && $0.key == expectedGridPath
            }?.key
            return PlexLiveTVEPG(identifier: identifier, dvrID: String(dvrID), gridPath: gridPath)
        }
    }

    private func liveTVReferences(providers: [PlexLiveTVEPG]) async throws -> [PlexLiveTVChannelReference] {
        var references: [PlexLiveTVChannelReference] = []
        var seen: Set<String> = []
        for provider in providers {
            let pages = try await liveTVPages(
                path: "/\(provider.identifier)/lineups/dvr/channels",
                query: [], isGuide: false
            )
            for page in pages {
                for channel in page.Channel ?? [] {
                    guard let nativeID = channel.id?.string, !nativeID.isEmpty else { continue }
                    let id = "\(provider.identifier)|\(nativeID)"
                    guard seen.insert(id).inserted else { continue }
                    references.append(PlexLiveTVChannelReference(
                        provider: provider,
                        nativeID: nativeID,
                        gridKey: channel.gridKey,
                        channel: ServerLiveTVChannel(
                            id: id,
                            name: channel.title ?? channel.callSign ?? nativeID,
                            number: channel.vcn?.string,
                            imageURL: liveTVArtwork(channel.thumb)
                        )
                    ))
                }
            }
        }
        return references
    }

    private func liveTVProgrammes(
        reference: PlexLiveTVChannelReference,
        date: String,
        from: Date,
        to: Date
    ) async throws -> [ServerLiveTVProgramme] {
        guard let path = reference.provider.gridPath,
              let gridKey = reference.gridKey else { return [] }
        let pages = try await liveTVPages(
            path: path,
            query: [
                URLQueryItem(name: "channelGridKey", value: gridKey),
                URLQueryItem(name: "date", value: date)
            ],
            isGuide: true
        )
        var result: [ServerLiveTVProgramme] = []
        for programme in pages.flatMap({ $0.Metadata ?? [] }) {
            guard let id = programme.ratingKey?.string ?? programme.guid ?? programme.key,
                  let title = programme.grandparentTitle ?? programme.title else { continue }
            for airing in programme.Media ?? [] {
                guard airing.protocol == nil || airing.protocol == "livetv",
                      airing.channelIdentifier?.string == reference.nativeID
                        || airing.gridKey == gridKey,
                      let start = airing.beginsAt?.number,
                      let end = airing.endsAt?.number
                        ?? airing.duration?.number.map({ start + $0 / 1_000 }),
                      end > start else { continue }
                let startDate = Date(timeIntervalSince1970: start)
                let endDate = Date(timeIntervalSince1970: end)
                guard startDate < to, endDate > from else { continue }
                result.append(ServerLiveTVProgramme(
                    id: "\(reference.channel.id)|\(id)|\(start)",
                    channelID: reference.channel.id,
                    title: title,
                    subtitle: programme.grandparentTitle == nil ? nil : programme.title,
                    overview: programme.summary,
                    startDate: startDate,
                    endDate: endDate,
                    imageURL: liveTVArtwork(programme.thumb),
                    categories: programme.Genre?.compactMap(\.tag) ?? []
                ))
            }
        }
        return result
    }

    private func liveTVPages(
        path: String, query: [URLQueryItem], isGuide: Bool
    ) async throws -> [PlexLiveTVContainer] {
        let limit = 200
        var offset = 0
        var pages: [PlexLiveTVContainer] = []
        var seen: Set<String> = []
        for _ in 0..<100 {
            try Task.checkCancellation()
            let page = try await liveTVContainer(
                path: path,
                query: query + [
                    URLQueryItem(name: "X-Plex-Container-Start", value: String(offset)),
                    URLQueryItem(name: "X-Plex-Container-Size", value: String(limit))
                ]
            )
            let ids: [String]
            if isGuide {
                ids = (page.Metadata ?? []).compactMap { item in
                    item.ratingKey?.string ?? item.guid ?? item.key
                }
            } else {
                ids = (page.Channel ?? []).compactMap { $0.id?.string }
            }
            let count = isGuide ? (page.Metadata?.count ?? 0) : (page.Channel?.count ?? 0)
            let total = page.totalSize?.integer
            if count == 0 {
                guard total == nil || offset >= total! else { throw AppError.invalidResponse }
                return pages
            }
            let before = seen.count
            seen.formUnion(ids)
            guard seen.count > before else { throw AppError.invalidResponse }
            pages.append(page)
            offset += count
            if let total {
                guard total >= 0 else { throw AppError.invalidResponse }
                if offset >= total { return pages }
            } else if count < limit {
                return pages
            }
        }
        throw AppError.invalidResponse
    }

    private func liveTVArtwork(_ value: String?) -> URL? {
        guard let value, let components = URLComponents(string: value),
              !value.hasPrefix("//") else { return nil }
        let url: URL?
        if components.scheme != nil {
            url = components.url
        } else {
            guard value.hasPrefix("/"), !value.contains("\\"),
                  !components.path.split(separator: "/").contains(".."),
                  var base = URLComponents(url: client.baseURL, resolvingAgainstBaseURL: false) else {
                return nil
            }
            base.percentEncodedPath = components.percentEncodedPath
            base.queryItems = components.queryItems
            base.fragment = components.fragment
            url = base.url
        }
        return url.flatMap { try? SecretFreeURLSource(url: $0).url }
    }

    private static func liveTVDates(from: Date, to: Date) -> [String] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        // PMS lineup timezone is not exposed by this API. Adjacent dates avoid
        // losing a boundary airing; returned epoch times are filtered precisely.
        var day = calendar.startOfDay(for: from).addingTimeInterval(-86_400)
        let last = calendar.startOfDay(for: to).addingTimeInterval(86_400)
        var result: [String] = []
        while day <= last, result.count < 6 {
            result.append(formatter.string(from: day))
            day = day.addingTimeInterval(86_400)
        }
        return result
    }
}

private struct PlexLiveTVEPG: Sendable {
    let identifier: String
    let dvrID: String
    let gridPath: String?
}

private struct PlexLiveTVChannelReference: Sendable {
    let provider: PlexLiveTVEPG
    let nativeID: String
    let gridKey: String?
    let channel: ServerLiveTVChannel
}
