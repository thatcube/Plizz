#if DEBUG
import CoreModels
import Foundation
import XCTest
@testable import FeatureLiveTVCore

final class LiveTVPortableIdentityExportTests: XCTestCase {
    @MainActor
    func testTwoDevicesResolvePortableMappingToDifferentLocalDiscoveredGuideIDs() async throws {
        let deviceA = try await guideDevice()
        let deviceB = try await guideDevice()
        let idA = try XCTUnwrap(deviceA.model.channels.first?.id)
        let idB = try XCTUnwrap(deviceB.model.channels.first?.id)
        // The sender must retire its original ID regardless of random UUID order.
        let first = idA > idB ? deviceA : deviceB
        let second = idA > idB ? deviceB : deviceA
        let firstGuideID = try XCTUnwrap(first.imports.guideSources.first?.id)
        let secondGuideID = try XCTUnwrap(second.imports.guideSources.first?.id)
        let firstID = try XCTUnwrap(first.model.channels.first?.id)
        let secondID = try XCTUnwrap(second.model.channels.first?.id)
        XCTAssertNotEqual(firstGuideID, secondGuideID)
        XCTAssertNotEqual(firstID, secondID)
        let firstHints = first.imports.portableIdentityHints
        let secondHints = second.imports.portableIdentityHints
        try await first.cache.applyPortableIdentityHints(secondHints.mapValues(Optional.some))
        try await second.cache.applyPortableIdentityHints(firstHints.mapValues(Optional.some))
        await first.imports.reload(into: first.model)
        await second.imports.reload(into: second.model)
        let channelID = try XCTUnwrap(first.model.channels.first?.id)
        XCTAssertNotEqual(channelID, firstID)
        XCTAssertEqual(channelID, secondID)
        XCTAssertEqual(second.model.channels.first?.id, channelID)
        XCTAssertEqual(first.imports.guideSources.first?.id, firstGuideID)
        XCTAssertEqual(second.imports.guideSources.first?.id, secondGuideID)
        XCTAssertEqual(first.model.currentProgram(for: channelID)?.title, "Automatic programme")
        XCTAssertEqual(second.model.currentProgram(for: channelID)?.title, "Automatic programme")
        try await first.imports.setGuideMapping(
            channelID: channelID, guideSourceID: firstGuideID, guideChannelID: "manual"
        )
        XCTAssertEqual(first.model.currentProgram(for: channelID)?.title, "Manual programme")
        let exported = try await first.cache.portableSyncGuideMappings(configuration: first.configuration)
        let mapping = try XCTUnwrap(exported.mappings[channelID])
        XCTAssertTrue(exported.unresolvedChannelIDs.isEmpty)
        XCTAssertTrue(mapping.hasBoundSourceIdentity)
        XCTAssertEqual(first.imports.portableGuideMappings[channelID], mapping)
        let bytes = try LiveTVPortableRecord(channel: .init(isFavorite: true, guideMapping: mapping)).encoded()
        let text = String(decoding: bytes, as: UTF8.self)
        for secret in ["https://", "playlist-secret", "guide-secret", firstGuideID, secondGuideID] {
            XCTAssertFalse(text.contains(secret))
        }
        let key = LiveTVPortableRecordKey(profileID: "profile", kind: .channel, entityID: channelID)
        let received = try XCTUnwrap(LiveTVPortableRecord.decode(bytes, key: key).channel?.guideMapping)
        let applied = try await second.imports.applyPortableGuideState(
            mappings: [channelID: received], identityHints: [:], into: second.model
        )
        XCTAssertEqual(applied, [channelID])
        XCTAssertEqual(second.imports.mappingOverrides[channelID]?.guideSourceID, secondGuideID)
        XCTAssertEqual(second.model.currentProgram(for: channelID)?.title, "Manual programme")
        let recaptured = try await second.cache.portableSyncGuideMappings(configuration: second.configuration)
        XCTAssertEqual(recaptured.mappings[channelID], mapping, "Local IDs must not cause sync ping-pong")
    }

    @MainActor
    func testPortableChannelIdentityMigrationPreservesRequestedGuideWindowRange() async throws {
        let device = try await guideDevice()
        let originalID = try XCTUnwrap(device.model.channels.first?.id)
        let guideID = try XCTUnwrap(device.imports.guideSources.first?.id)
        let canonicalID = "channel-00000000-0000-0000-0000-000000000000"
        XCTAssertNotEqual(originalID, canonicalID)
        let range = DateInterval(start: device.model.now.addingTimeInterval(86_400), duration: 3_600)
        await device.imports.loadGuideWindow(channelIDs: [originalID], range: range, into: device.model)
        XCTAssertEqual(
            device.model.programs(for: originalID, from: range.start, hours: 1).map(\.title),
            ["Later automatic programme"]
        )
        try await device.cache.applyPortableIdentityHints([
            canonicalID: .init(sourceID: "source", nativeID: "station")
        ])
        await device.imports.reload(into: device.model)
        XCTAssertEqual(device.model.channels.map(\.id), [canonicalID])
        XCTAssertEqual(device.imports.guideSources.first?.id, guideID)
        let programs = device.model.programs(for: canonicalID, from: range.start, hours: 1)
        XCTAssertEqual(programs.map(\.title), ["Later automatic programme"])
        XCTAssertEqual(programs.map(\.channelID), [canonicalID])
        XCTAssertTrue(programs.allSatisfy { $0.start < range.end && $0.end > range.start })
    }

    @MainActor
    func testUnavailablePortableFeedPreservesAutomaticListingsAndRetriesAfterAdmission() async throws {
        let device = try await guideDevice()
        let channelID = try XCTUnwrap(device.model.channels.first?.id)
        var source = try XCTUnwrap(device.configuration.playlists.first)
        let newURL = try XCTUnwrap(URL(string: "https://example.test/new-guide.xml?token=guide-secret"))
        let mapping = LiveTVPortableGuideMapping(
            guideSourceID: LiveTVPortableGuideMapping.boundSourceID(playlist: source, guideURL: newURL),
            guideChannelID: "manual"
        )
        let pending = try await device.imports.applyPortableGuideState(
            mappings: [channelID: mapping], identityHints: [:], into: device.model
        )
        XCTAssertTrue(pending.isEmpty)
        XCTAssertNil(device.imports.mappingOverrides[channelID])
        XCTAssertEqual(device.model.currentProgram(for: channelID)?.title, "Automatic programme")
        source.guideURLs = [newURL]
        source.guideSourceIDs = ["recipient-local-guide"]
        try device.imports.applyConfiguration(.init(playlists: [source]), into: device.model)
        await device.imports.reload(into: device.model)
        let applied = try await device.imports.applyPortableGuideState(
            mappings: [channelID: mapping], identityHints: [:], into: device.model
        )
        XCTAssertEqual(applied, [channelID])
        XCTAssertEqual(device.imports.mappingOverrides[channelID]?.guideSourceID, "recipient-local-guide")
        XCTAssertEqual(device.model.currentProgram(for: channelID)?.title, "Manual programme")
    }

    @MainActor
    func testCredentialMismatchLegacyIDsAndMissingStationsCannotReplaceAutomaticListings() async throws {
        let device = try await guideDevice()
        let channelID = try XCTUnwrap(device.model.channels.first?.id)
        let source = try XCTUnwrap(device.configuration.playlists.first)
        let guide = try XCTUnwrap(device.imports.guideSources.first)
        let otherCredentials = try XCTUnwrap(URL(string: "https://example.test/guide.xml?token=other-secret"))
        var otherPlaylist = source
        otherPlaylist.playlistURL = try XCTUnwrap(URL(string: "https://example.test/list.m3u?token=other-secret"))
        let mappings: [LiveTVPortableGuideMapping] = [
            .init(guideSourceID: LiveTVPortableGuideMapping.boundSourceID(playlist: source, guideURL: otherCredentials),
                  guideChannelID: "manual"),
            .init(guideSourceID: LiveTVPortableGuideMapping.boundSourceID(playlist: otherPlaylist, guideURL: guide.source.url),
                  guideChannelID: "manual"),
            .init(guideSourceID: guide.id, guideChannelID: "manual"),
            .init(guideSourceID: LiveTVPortableGuideMapping.boundSourceID(playlist: source, guideURL: guide.source.url),
                  guideChannelID: "missing")
        ]
        for mapping in mappings {
            let applied = try await device.imports.applyPortableGuideState(
                mappings: [channelID: mapping], identityHints: [:], into: device.model
            )
            XCTAssertTrue(applied.isEmpty)
            XCTAssertNil(device.imports.mappingOverrides[channelID])
            XCTAssertEqual(device.model.currentProgram(for: channelID)?.title, "Automatic programme")
        }
        let validMapping = LiveTVPortableGuideMapping(
            guideSourceID: LiveTVPortableGuideMapping.boundSourceID(playlist: source, guideURL: guide.source.url),
            guideChannelID: "manual"
        )
        let denied = try await device.cache.applyPortableGuideMappings([channelID: validMapping], configuration: .empty)
        XCTAssertTrue(denied.isEmpty)
        let stored = try await device.cache.mappingOverrides()
        XCTAssertTrue(stored.isEmpty)
    }

    @MainActor
    func testEditedCredentialsCannotResolveAgainstAnOlderBoundGuideGeneration() async throws {
        let device = try await guideDevice()
        let channelID = try XCTUnwrap(device.model.channels.first?.id)
        let guide = try XCTUnwrap(device.imports.guideSources.first)
        var source = try XCTUnwrap(device.configuration.playlists.first)
        let replacementURL = try XCTUnwrap(URL(string: "https://example.test/guide.xml?token=replacement"))
        source.guideURLs = [replacementURL]
        source.guideSourceIDs = [guide.id]
        let mapping = LiveTVPortableGuideMapping(
            guideSourceID: LiveTVPortableGuideMapping.boundSourceID(playlist: source, guideURL: replacementURL),
            guideChannelID: "manual"
        )
        let applied = try await device.cache.applyPortableGuideMappings(
            [channelID: mapping], configuration: .init(playlists: [source])
        )
        XCTAssertTrue(applied.isEmpty)
        let stored = try await device.cache.mappingOverrides()
        XCTAssertTrue(stored.isEmpty)
        XCTAssertEqual(device.model.currentProgram(for: channelID)?.title, "Automatic programme")
    }

    @MainActor
    func testAmbiguousSourceOwnershipLeavesMappingUnresolvedAndCachedAutomaticRowsUntouched() async throws {
        let device = try await guideDevice()
        let channelID = try XCTUnwrap(device.model.channels.first?.id)
        let source = try XCTUnwrap(device.configuration.playlists.first)
        let guide = try XCTUnwrap(device.imports.guideSources.first)
        let cachedPlaylist = try await device.cache.playlist(source: source)
        let playlist = try XCTUnwrap(cachedPlaylist)
        let duplicateSource = LiveTVPlaylistSource(
            id: "other-source", name: "Other",
            playlistURL: try XCTUnwrap(URL(string: "https://example.test/other.m3u"))
        )
        try await device.cache.storePlaylist(playlist, source: duplicateSource, now: device.model.now)
        let mapping = LiveTVPortableGuideMapping(
            guideSourceID: LiveTVPortableGuideMapping.boundSourceID(playlist: source, guideURL: guide.source.url),
            guideChannelID: "manual"
        )
        let applied = try await device.cache.applyPortableGuideMappings(
            [channelID: mapping], configuration: .init(playlists: [source, duplicateSource])
        )
        XCTAssertTrue(applied.isEmpty)
        let stored = try await device.cache.mappingOverrides()
        XCTAssertTrue(stored.isEmpty)
        let programmes = try await device.cache.programs(
            sourceID: guide.id, channelIDs: [channelID],
            range: .init(start: device.model.now, duration: 60), sourceURL: guide.source.url
        )
        XCTAssertEqual(programmes.map(\.title), ["Automatic programme"])
    }

    @MainActor
    func testUnavailableLocalMappingExportRetainsStateAndLegacyForeignOverridesDoNotHideAutomaticGuide() async throws {
        let device = try await guideDevice()
        let channelID = try XCTUnwrap(device.model.channels.first?.id)
        try await device.cache.setMapping(
            .init(guideSourceID: "guide-" + UUID().uuidString.lowercased(), guideChannelID: "manual"),
            channelID: channelID
        )
        await device.imports.reload(into: device.model)
        XCTAssertEqual(device.model.currentProgram(for: channelID)?.title, "Automatic programme")
        let exported = try await device.cache.portableSyncGuideMappings(configuration: device.configuration)
        XCTAssertTrue(exported.mappings.isEmpty)
        XCTAssertEqual(exported.unresolvedChannelIDs, [channelID])
    }

    @MainActor
    private func guideDevice() async throws -> (
        cache: LiveTVIndexedCache, imports: LiveTVPrototypeImportModel,
        model: LiveTVPrototypeModel, configuration: LiveTVSourcesConfiguration
    ) {
        let cache = try fixture()
        let source = LiveTVPlaylistSource(
            id: "source", name: "Local",
            playlistURL: try XCTUnwrap(URL(string: "https://example.test/list.m3u?token=playlist-secret"))
        )
        let guideURL = try XCTUnwrap(URL(string: "https://example.test/guide.xml?token=guide-secret"))
        let configuration = LiveTVSourcesConfiguration(playlists: [source])
        let imports = LiveTVPrototypeImportModel(
            configuration: configuration, loader: PortableGuideFixtureLoader(guideURL: guideURL), cache: cache
        )
        let model = LiveTVPrototypeModel(now: Date(), channels: [])
        await imports.reload(into: model)
        XCTAssertEqual(model.channels.count, 1)
        XCTAssertEqual(imports.programCount, 1)
        return (cache, imports, model, configuration)
    }

    func testOnlyRequestedUniqueNativeIdentitiesAreExportedWithoutLocators() async throws {
        let cache = try fixture()
        let source = LiveTVPlaylistSource(
            id: "source", name: "Local",
            playlistURL: URL(string: "https://example.test/list.m3u?token=playlist-secret")!
        )
        let parsed = try LiveTVPlaylistParser(baseURL: source.playlistURL).parse(Data("""
        #EXTM3U
        #EXTINF:-1 tvg-id="unique@West",Unique
        https://example.test/one.m3u8?token=stream-secret
        #EXTINF:-1 tvg-id="duplicate",Duplicate SD
        https://example.test/two.m3u8
        #EXTINF:-1 tvg-id="duplicate",Duplicate HD
        https://example.test/three.m3u8
        #EXTINF:-1 tvg-id="not-requested",Not requested
        https://example.test/four.m3u8
        """.utf8))
        let resolution = try await cache.reconcile(parsed, sourceID: source.id)
        try await cache.storePlaylist(
            resolution.playlist, sourceID: source.id, now: Date(), sourceURL: source.playlistURL
        )
        let wanted = Set(resolution.playlist.channels.prefix(3).map(\.id))
        let hints = try await cache.portableSyncIdentityHints(configuration: .init(playlists: [source]), channelIDs: wanted)
        XCTAssertEqual(hints.count, 1)
        XCTAssertEqual(hints.values.first?.sourceID, source.id)
        let text = String(decoding: try JSONEncoder().encode(hints), as: UTF8.self)
        XCTAssertFalse(text.contains("secret"))
        XCTAssertFalse(text.contains("https"))
    }

    private struct PortableGuideFixtureLoader: LiveTVIndexedSourceLoading {
        let guideURL: URL

        func loadPlaylist(from url: URL) async throws -> LiveTVPlaylistImport {
            try LiveTVPlaylistParser(baseURL: url).parse("""
            #EXTM3U url-tvg="\(guideURL.absoluteString)"
            #EXTINF:-1 tvg-id="station",Station
            https://example.test/live.m3u8
            """)
        }

        func loadGuide(
            from url: URL, channels: [LiveTVPrototypeChannel], now: Date
        ) async throws -> LiveTVGuideImport {
            try LiveTVXMLTVParser().parseXML(data: xml(now: now), channels: channels, now: now)
        }

        func loadIndexedGuide(
            from url: URL, sourceID: String, channels: [LiveTVPrototypeChannel], now: Date,
            cache: LiveTVIndexedCache, lookbackDays: Int, lookaheadDays: Int
        ) async throws -> LiveTVGuideImport {
            try await cache.importGuide(
                data: xml(now: now), sourceID: sourceID, channels: channels, provider: nil, now: now,
                lookbackDays: lookbackDays, lookaheadDays: lookaheadDays, sourceURL: url
            )
        }

        private func xml(now: Date) -> Data {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyyMMddHHmmss Z"
            let start = formatter.string(from: now.addingTimeInterval(-60))
            let stop = formatter.string(from: now.addingTimeInterval(3_600))
            let laterStart = formatter.string(from: now.addingTimeInterval(86_400))
            let laterStop = formatter.string(from: now.addingTimeInterval(90_000))
            return Data("""
            <tv>
            <channel id="station"><display-name>Station</display-name></channel>
            <channel id="manual"><display-name>Manual station</display-name></channel>
            <programme channel="station" start="\(start)" stop="\(stop)"><title>Automatic programme</title></programme>
            <programme channel="manual" start="\(start)" stop="\(stop)"><title>Manual programme</title></programme>
            <programme channel="station" start="\(laterStart)" stop="\(laterStop)"><title>Later automatic programme</title></programme>
            </tv>
            """.utf8)
        }
    }

    func testChangedSourceAddressCannotExportOldCachedIdentity() async throws {
        let cache = try fixture()
        var source = LiveTVPlaylistSource(
            id: "source", name: "Local", playlistURL: URL(string: "https://example.test/original.m3u")!
        )
        let parsed = try LiveTVPlaylistParser(baseURL: source.playlistURL).parse(Data("""
        #EXTM3U
        #EXTINF:-1 tvg-id="station",Station
        https://example.test/stream.m3u8
        """.utf8))
        let resolution = try await cache.reconcile(parsed, sourceID: source.id)
        try await cache.storePlaylist(
            resolution.playlist, sourceID: source.id, now: Date(), sourceURL: source.playlistURL
        )
        source.playlistURL = URL(string: "https://example.test/replacement.m3u")!
        let hints = try await cache.portableSyncIdentityHints(
            configuration: .init(playlists: [source]),
            channelIDs: Set(resolution.playlist.channels.map(\.id))
        )
        XCTAssertTrue(hints.isEmpty)
    }

    func testImportedFileIdentityDoesNotExportItsLocatorOrContent() async throws {
        let cache = try fixture()
        let id = UUID()
        let source = LiveTVPlaylistSource(
            id: id.uuidString, name: "File",
            playlistURL: URL(string: "plozz-playlist://" + id.uuidString.lowercased())!
        )
        let parsed = try await cache.storeImportedPlaylist(data: Data("""
        #EXTM3U
        #EXTINF:-1 tvg-id="station",Station
        https://example.test/stream.m3u8?token=file-secret
        """.utf8), id: id)
        let resolution = try await cache.reconcile(parsed, sourceID: source.id)
        try await cache.storePlaylist(
            resolution.playlist, sourceID: source.id, now: Date(), sourceURL: source.playlistURL
        )
        let hints = try await cache.portableSyncIdentityHints(
            configuration: .init(playlists: [source]), channelIDs: Set(resolution.playlist.channels.map(\.id))
        )
        XCTAssertEqual(hints.count, 1)
        let text = String(decoding: try JSONEncoder().encode(hints), as: UTF8.self)
        XCTAssertFalse(text.contains("plozz-playlist"))
        XCTAssertFalse(text.contains("file-secret"))
        try await cache.removeImportedPlaylist(id: id)
        let removed = try await cache.portableSyncIdentityHints(
            configuration: .init(playlists: [source]), channelIDs: Set(resolution.playlist.channels.map(\.id))
        )
        XCTAssertTrue(removed.isEmpty)
    }

    func testConfiguredSourceBindingAllowsRedirectedPlaylistOrigin() async throws {
        let cache = try fixture()
        let source = LiveTVPlaylistSource(
            id: "source", name: "Local", playlistURL: URL(string: "https://example.test/start.m3u")!
        )
        let destination = URL(string: "https://example.test/final.m3u")!
        let parsed = try LiveTVPlaylistParser(baseURL: destination).parse(Data("""
        #EXTM3U
        #EXTINF:-1 tvg-id="station",Station
        https://example.test/stream.m3u8
        """.utf8))
        let resolution = try await cache.reconcile(parsed, sourceID: source.id)
        try await cache.storePlaylist(
            resolution.playlist, sourceID: source.id, now: Date(), sourceURL: source.playlistURL
        )
        let channelIDs = Set(resolution.playlist.channels.map(\.id))
        let hints = try await cache.portableSyncIdentityHints(
            configuration: .init(playlists: [source]), channelIDs: channelIDs
        )
        XCTAssertEqual(hints.count, 1)
        var edited = source
        edited.playlistURL = destination
        let afterEdit = try await cache.portableSyncIdentityHints(
            configuration: .init(playlists: [edited]), channelIDs: channelIDs
        )
        XCTAssertTrue(afterEdit.isEmpty)
    }

    func testMatchingOriginCannotMakeAnUnboundLegacyCachePortable() async throws {
        let cache = try fixture()
        let source = LiveTVPlaylistSource(
            id: "source", name: "Local", playlistURL: URL(string: "https://example.test/list.m3u")!
        )
        let parsed = try LiveTVPlaylistParser(baseURL: source.playlistURL).parse(Data("""
        #EXTM3U
        #EXTINF:-1 tvg-id="station",Station
        https://example.test/stream.m3u8
        """.utf8))
        let resolution = try await cache.reconcile(parsed, sourceID: source.id)
        try await cache.storePlaylist(resolution.playlist, sourceID: source.id, now: Date())
        let hints = try await cache.portableSyncIdentityHints(
            configuration: .init(playlists: [source]), channelIDs: Set(resolution.playlist.channels.map(\.id))
        )
        XCTAssertTrue(hints.isEmpty)
    }

    private func fixture() throws -> LiveTVIndexedCache {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/live-tv-identity-export-tests/" + UUID().uuidString, isDirectory: true)
        addTeardownBlock {
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
        }
        return LiveTVIndexedCache(
            url: directory.appendingPathComponent("catalog.sqlite"), namespace: "profile",
            authorizationScope: "iptv-profile-v1", secureStore: PortableIdentityTestSecrets(),
            importedFilesURL: directory.appendingPathComponent("imports", isDirectory: true)
        )
    }
}

private final class PortableIdentityTestSecrets: SecureStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func readString(for key: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }
    func string(for key: String) -> String? { try? readString(for: key) }
    func setString(_ value: String, for key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        values[key] = value
    }
    func removeValue(for key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        values[key] = nil
    }
}
#endif
