#if DEBUG
import CoreModels
import FeatureLiveTVCore
import Foundation
import XCTest
@testable import AppRuntime

@MainActor
final class LiveTVPortableSyncBridgeTests: XCTestCase {
    func testOnlyResolvedGuideMappingsAreAcknowledgedAndPendingMappingsRetryOnCapture() async throws {
        let fixture = try makeFixture()
        let profileID = fixture.profiles.activeProfileID
        fixture.consent(profileID).isEnabled = true
        let seeded = try await seedGuideCache(fixture)
        let firstID = try XCTUnwrap(seeded.channels.first?.id)
        let secondID = try XCTUnwrap(seeded.channels.last?.id)
        XCTAssertNotEqual(firstID, secondID)
        let unavailableURL = try XCTUnwrap(URL(string: "https://example.test/later.xml?token=other-secret"))
        let firstMapping = LiveTVPortableGuideMapping(
            guideSourceID: LiveTVPortableGuideMapping.boundSourceID(playlist: seeded.source, guideURL: seeded.guideURL),
            guideChannelID: "mapped"
        )
        let pendingMapping = LiveTVPortableGuideMapping(
            guideSourceID: LiveTVPortableGuideMapping.boundSourceID(playlist: seeded.source, guideURL: unavailableURL),
            guideChannelID: "mapped"
        )
        let bridge = fixture.makeBridge(cache: seeded.cache)
        await bridge.apply([
            record(profileID, firstID): try LiveTVPortableRecord(channel: .init(
                isFavorite: true, guideMapping: firstMapping
            )).encoded(),
            record(profileID, secondID): try LiveTVPortableRecord(channel: .init(
                isFavorite: true, guideMapping: pendingMapping
            )).encoded()
        ])
        let initiallyApplied = try await seeded.cache.mappingOverrides()
        XCTAssertEqual(initiallyApplied[firstID]?.guideSourceID, "local-guide")
        XCTAssertNil(initiallyApplied[secondID])
        XCTAssertEqual(bridge.statuses[profileID], .pendingChannelMatches(1))
        let captured = await bridge.capture(fallback: [:])
        let pendingKey = LiveTVPortableRecordKey(profileID: profileID, kind: .channel, entityID: secondID)
        let pendingBytes = try XCTUnwrap(captured[pendingKey.recordName])
        XCTAssertEqual(try LiveTVPortableRecord.decode(pendingBytes, key: pendingKey).channel?.guideMapping, pendingMapping)
        XCTAssertEqual(bridge.statuses[profileID], .pendingChannelMatches(1))
        var source = seeded.source
        source.guideURLs.append(unavailableURL)
        source.guideSourceIDs = seeded.source.guideSourceIDs + ["recipient-later-guide"]
        XCTAssertEqual(source.guideSourceIDs, ["local-guide", "recipient-later-guide"])
        try fixture.sources.save(.init(playlists: [source]))
        _ = try await seeded.cache.importGuide(
            data: guideMetadata, sourceID: "recipient-later-guide", channels: seeded.channels,
            provider: nil, now: Date(), sourceURL: unavailableURL
        )
        _ = await bridge.capture(fallback: captured)
        let resolved = try await seeded.cache.mappingOverrides()
        XCTAssertEqual(resolved[secondID]?.guideSourceID, "recipient-later-guide")
        XCTAssertEqual(bridge.statuses[profileID], .ready)
    }

    func testCachedGuideMappingCannotBypassKidsSourceApproval() async throws {
        let fixture = try makeFixture()
        let child = fixture.profiles.add(name: "Child", isKidsProfile: true)
        fixture.profiles.select(child.id)
        fixture.consent(child.id).isEnabled = true
        let seeded = try await seedGuideCache(fixture)
        let channelID = try XCTUnwrap(seeded.channels.first?.id)
        let mapping = LiveTVPortableGuideMapping(
            guideSourceID: LiveTVPortableGuideMapping.boundSourceID(playlist: seeded.source, guideURL: seeded.guideURL),
            guideChannelID: "mapped"
        )
        let bridge = fixture.makeBridge(cache: seeded.cache)
        await bridge.apply([record(child.id, channelID): try LiveTVPortableRecord(
            channel: .init(isFavorite: true, guideMapping: mapping)
        ).encoded()])
        _ = await bridge.capture(fallback: [:])
        let stored = try await seeded.cache.mappingOverrides()
        XCTAssertTrue(stored.isEmpty)
        XCTAssertEqual(bridge.statuses[child.id], .pendingChannelMatches(1))
    }

    func testPortableGuideMappingWaitsForPlaybackHold() async throws {
        let fixture = try makeFixture()
        let profileID = fixture.profiles.activeProfileID
        fixture.consent(profileID).isEnabled = true
        let seeded = try await seedGuideCache(fixture)
        let channelID = try XCTUnwrap(seeded.channels.first?.id)
        let mapping = LiveTVPortableGuideMapping(
            guideSourceID: LiveTVPortableGuideMapping.boundSourceID(playlist: seeded.source, guideURL: seeded.guideURL),
            guideChannelID: "mapped"
        )
        let bridge = fixture.makeBridge(cache: seeded.cache)
        let hold = LiveTVPlaybackIdentityHold(profileID: profileID)
        hold.update(true)
        defer { hold.update(false) }
        await bridge.apply([record(profileID, channelID): try LiveTVPortableRecord(
            channel: .init(isFavorite: true, guideMapping: mapping)
        ).encoded()])
        let held = try await seeded.cache.mappingOverrides()
        XCTAssertTrue(held.isEmpty)
        XCTAssertEqual(bridge.statuses[profileID], .pendingChannelMatches(1))
        hold.update(false)
        _ = await bridge.capture(fallback: [:])
        let applied = try await seeded.cache.mappingOverrides()
        XCTAssertEqual(applied[channelID]?.guideSourceID, "local-guide")
        XCTAssertEqual(bridge.statuses[profileID], .ready)
    }

    private var guideMetadata: Data {
        Data("<tv><channel id=\"mapped\"><display-name>Mapped station</display-name></channel></tv>".utf8)
    }

    private func seedGuideCache(_ fixture: PortableRuntimeFixture) async throws -> (
        cache: LiveTVIndexedCache, source: LiveTVPlaylistSource,
        channels: [LiveTVPrototypeChannel], guideURL: URL
    ) {
        var source = try XCTUnwrap(fixture.sources.load().playlists.first)
        let guideURL = try XCTUnwrap(URL(string: "https://example.test/guide.xml?token=guide-secret"))
        source.guideURLs = [guideURL]
        source.guideSourceIDs = ["local-guide"]
        try fixture.sources.save(.init(playlists: [source]))
        let cache = LiveTVIndexedCache(
            url: fixture.directory.appendingPathComponent("guide.sqlite"),
            namespace: fixture.profiles.activeProfileID, authorizationScope: "iptv-profile-v1",
            secureStore: PortableRuntimeSecrets()
        )
        let playlist = try LiveTVPlaylistParser(baseURL: source.playlistURL).parse("""
        #EXTM3U
        #EXTINF:-1 tvg-id="first",First
        https://example.test/first.m3u8
        #EXTINF:-1 tvg-id="second",Second
        https://example.test/second.m3u8
        """)
        let resolution = try await cache.reconcile(playlist, sourceID: source.id)
        try await cache.storePlaylist(resolution.playlist, source: source, now: Date())
        _ = try await cache.importGuide(
            data: guideMetadata, sourceID: "local-guide", channels: resolution.playlist.channels,
            provider: nil, now: Date(), sourceURL: guideURL
        )
        return (cache, source, resolution.playlist.channels, guideURL)
    }

    func testRecordedRootOwnerUsesItsActualProfileIDAndLegacyPreferenceKeys() async throws {
        let fixture = try makeFixture(rootOwner: "owner")
        let owner = fixture.profiles.activeProfileID
        fixture.consent(owner).isEnabled = true
        try LiveTVPreferencesStore(defaults: fixture.defaults).save(.init(favoriteIDs: ["owner-channel"]))
        try LiveTVPreferencesStore(
            defaults: fixture.defaults, namespace: ProfileStore.defaultProfileID
        ).save(.init(favoriteIDs: ["separate-channel"]))

        let records = await fixture.bridge.capture(fallback: [:])
        XCTAssertNotNil(records[record(owner, "owner-channel")])
        XCTAssertNil(records[record(owner, "separate-channel")])
        XCTAssertFalse(records.keys.contains { LiveTVPortableRecordKey.parse($0)?.profileID == ProfileStore.defaultProfileID })
    }

    func testProfileRemovalSurvivesReopeningWithoutErasingLocalSourcesOrFavorites() async throws {
        let fixture = try makeFixture()
        let profileID = fixture.profiles.activeProfileID
        fixture.consent(profileID).isEnabled = true
        try fixture.preferences.save(.init(favoriteIDs: ["favorite"]))
        let initial = await fixture.bridge.capture(fallback: [:])
        XCTAssertFalse(initial.isEmpty)
        try fixture.bridge.removeProfile(profileID)
        let reopened = fixture.makeBridge()
        let after = await reopened.capture(fallback: initial)
        XCTAssertTrue(after.isEmpty)
        XCTAssertFalse(fixture.consent(profileID).isEnabled)
        XCTAssertEqual(try fixture.preferences.load().favoriteIDs, ["favorite"])
        XCTAssertEqual(try fixture.sources.load().playlists.count, 1)
    }

    func testAccountResetRevokesEveryProfileConsentButKeepsLocalState() async throws {
        let fixture = try makeFixture()
        let child = fixture.profiles.add(name: "Other", isKidsProfile: true)
        for profile in fixture.profiles.profiles { fixture.consent(profile.id).isEnabled = true }
        try fixture.preferences.save(.init(favoriteIDs: ["favorite"]))
        _ = await fixture.bridge.capture(fallback: [:])
        let epoch = LiveTVPortableSyncPreferenceStore.storageEpoch(defaults: fixture.defaults)
        fixture.bridge.accountDidChange()
        XCTAssertNotEqual(epoch, LiveTVPortableSyncPreferenceStore.storageEpoch(defaults: fixture.defaults))
        XCTAssertFalse(fixture.consent(fixture.profiles.activeProfileID).isEnabled)
        XCTAssertFalse(fixture.consent(child.id).isEnabled)
        let after = await fixture.bridge.capture(fallback: [:])
        XCTAssertTrue(after.isEmpty)
        XCTAssertEqual(try fixture.preferences.load().favoriteIDs, ["favorite"])
        XCTAssertEqual(try fixture.sources.load().playlists.first?.playlistURL.query, "token=local-only")
    }

    func testMissingSharedGuideCacheKeepsMappingPendingAcrossCaptures() async throws {
        let fixture = try makeFixture()
        let profileID = fixture.profiles.activeProfileID
        fixture.consent(profileID).isEnabled = true
        let id = "channel-" + UUID().uuidString.lowercased()
        let bytes = try LiveTVPortableRecord(channel: .init(
            isFavorite: true,
            guideMapping: .init(guideSourceID: "guide", guideChannelID: "station")
        )).encoded()
        await fixture.bridge.apply([record(profileID, id): bytes])
        XCTAssertEqual(fixture.bridge.statuses[profileID], .pendingChannelMatches(1))
        let captured = await fixture.bridge.capture(fallback: [:])
        XCTAssertNotNil(captured[record(profileID, id)])
        XCTAssertEqual(fixture.bridge.statuses[profileID], .pendingChannelMatches(1))
    }

    func testIdentityUpdatesWaitForAllPlaybackHoldsAndRetryOnCapture() async throws {
        let fixture = try makeFixture()
        let profileID = fixture.profiles.activeProfileID
        fixture.consent(profileID).isEnabled = true
        var applied = 0
        let bridge = fixture.makeBridge { _, _ in applied += 1; return true }
        let hold = LiveTVPlaybackIdentityHold(profileID: profileID)
        hold.update(true)
        defer { hold.update(false) }
        let id = "channel-" + UUID().uuidString.lowercased()
        let bytes = try LiveTVPortableRecord(channel: .init(
            isFavorite: true, identityHint: .init(sourceID: "source", nativeID: "native")
        )).encoded()
        await bridge.apply([record(profileID, id): bytes])
        XCTAssertEqual(applied, 0)
        hold.update(false)
        _ = await bridge.capture(fallback: [:])
        XCTAssertEqual(applied, 1)
        _ = await bridge.capture(fallback: [:])
        XCTAssertEqual(applied, 1)
    }

    func testConcurrentRemoteUpdatesCannotAcknowledgeAwayNewerIdentityWork() async throws {
        let fixture = try makeFixture()
        let profileID = fixture.profiles.activeProfileID
        fixture.consent(profileID).isEnabled = true
        let gate = PortableTestGate()
        let entered = expectation(description: "First identity application entered")
        var applied: [String] = []
        let bridge = fixture.makeBridge { _, hints in
            applied += hints.values.compactMap { $0?.nativeID }
            if applied.count == 1 {
                entered.fulfill()
                await gate.wait()
            }
            return true
        }
        let id = "channel-" + UUID().uuidString.lowercased()
        let first = try LiveTVPortableRecord(channel: .init(
            isFavorite: true, identityHint: .init(sourceID: "source", nativeID: "first")
        )).encoded()
        let second = try LiveTVPortableRecord(channel: .init(
            isFavorite: true, identityHint: .init(sourceID: "source", nativeID: "second")
        )).encoded()
        let key = record(profileID, id)
        let firstTask = Task { await bridge.apply([key: first]) }
        await fulfillment(of: [entered], timeout: 2)
        let secondTask = Task { await bridge.apply([key: second]) }
        await gate.open()
        await firstTask.value
        await secondTask.value
        XCTAssertEqual(applied, ["first", "second"])
        _ = await bridge.capture(fallback: [:])
        XCTAssertEqual(applied, ["first", "second"])
    }

    func testCaptureOnlyNotifiesAppliedWhenItHydratesRemotePreferences() async throws {
        let fixture = try makeFixture()
        let profileID = fixture.profiles.activeProfileID
        fixture.consent(profileID).isEnabled = true
        let counter = PortableAppliedCounter()
        let token = NotificationCenter.default.addObserver(
            forName: .plozzLiveTVPortableStateDidApply, object: nil, queue: nil
        ) { notification in
            if notification.object as? String == profileID { counter.increment() }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        try fixture.preferences.save(.init(favoriteIDs: ["local"]))
        _ = await fixture.bridge.capture(fallback: [:])
        XCTAssertEqual(counter.value, 0)
        let key = record(profileID, "remote")
        let bytes = try LiveTVPortableRecord(channel: .init(isFavorite: true)).encoded()
        _ = await fixture.bridge.capture(fallback: [key: bytes])
        XCTAssertEqual(try fixture.preferences.load().favoriteIDs, ["local", "remote"])
        XCTAssertEqual(counter.value, 1)
        _ = await fixture.bridge.capture(fallback: [key: bytes])
        XCTAssertEqual(counter.value, 1)
    }

    func testRemoteEnrollmentDenialNotifiesEffectiveSourceChangeOnlyOnce() async throws {
        let fixture = try makeFixture()
        let profileID = fixture.profiles.activeProfileID
        fixture.consent(profileID).isEnabled = true
        let counter = PortableAppliedCounter()
        let token = NotificationCenter.default.addObserver(
            forName: .plozzLiveTVPortableStateDidApply, object: nil, queue: nil
        ) { notification in
            if notification.object as? String == profileID { counter.increment() }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        let key = LiveTVPortableRecordKey(
            profileID: profileID, kind: .serverEnrollment, entityID: "account"
        ).recordName
        let bytes = try LiveTVPortableRecord(serverEnrollmentSuppressed: true).encoded()
        await fixture.bridge.apply([key: bytes])
        XCTAssertEqual(counter.value, 1)
        XCTAssertEqual(try LiveTVServerEnrollmentSuppressionStore(
            defaults: fixture.defaults, profileID: profileID, namespace: fixture.profiles.activeNamespace
        ).suppressedAccountIDs(), ["account"])
        await fixture.bridge.apply([key: bytes])
        XCTAssertEqual(counter.value, 1)
    }

    private func record(_ profileID: String, _ channelID: String) -> String {
        LiveTVPortableRecordKey(profileID: profileID, kind: .channel, entityID: channelID).recordName
    }

    private func makeFixture(rootOwner: String = ProfileStore.defaultProfileID) throws -> PortableRuntimeFixture {
        let suite = "LiveTVPortableSyncBridgeTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/live-tv-runtime-tests/" + UUID().uuidString, isDirectory: true)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
        }
        let store = ProfileStore(defaults: defaults)
        var roster = [Profile(id: rootOwner, name: "Owner")]
        if rootOwner != ProfileStore.defaultProfileID {
            roster.append(Profile(id: ProfileStore.defaultProfileID, name: "Separate"))
        }
        store.saveProfiles(roster)
        store.setRootNamespaceOwnerID(rootOwner)
        let profiles = ProfilesModel(store: store)
        profiles.select(rootOwner)
        let sources = PortableRuntimeSources(configuration: .init(playlists: [
            .init(id: "source", name: "Local", playlistURL: URL(string: "https://example.test/list.m3u?token=local-only")!)
        ]))
        return PortableRuntimeFixture(profiles: profiles, defaults: defaults, directory: directory, sources: sources)
    }
}

@MainActor
private final class PortableRuntimeFixture {
    let profiles: ProfilesModel
    let defaults: UserDefaults
    let directory: URL
    let sources: PortableRuntimeSources
    lazy var bridge = makeBridge()
    var preferences: LiveTVPreferencesStore {
        LiveTVPreferencesStore(defaults: defaults, namespace: profiles.activeNamespace)
    }
    init(profiles: ProfilesModel, defaults: UserDefaults, directory: URL, sources: PortableRuntimeSources) {
        self.profiles = profiles
        self.defaults = defaults
        self.directory = directory
        self.sources = sources
    }
    func consent(_ profileID: String) -> LiveTVPortableSyncPreferenceStore {
        .init(
            defaults: defaults, profileID: profileID,
            namespace: profileID == profiles.rootNamespaceOwnerID ? nil : profileID
        )
    }
    func makeBridge(
        cache: LiveTVIndexedCache? = nil,
        identities: @escaping @MainActor (String, [String: LiveTVPortableChannelIdentityHint?]) async throws -> Bool = { _, _ in false }
    ) -> LiveTVPortableSyncBridge {
        LiveTVPortableSyncBridge(
            profiles: profiles, directory: directory, defaults: defaults,
            sourceStore: { [sources] _ in sources }, guideCache: { _ in cache }, applyIdentityHints: identities
        )
    }
}

private final class PortableRuntimeSecrets: SecureStoring, @unchecked Sendable {
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

private final class PortableRuntimeSources: LiveTVSourcesStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var configuration: LiveTVSourcesConfiguration
    init(configuration: LiveTVSourcesConfiguration) { self.configuration = configuration }
    func load() throws -> LiveTVSourcesConfiguration {
        lock.lock()
        defer { lock.unlock() }
        return configuration
    }
    func save(_ configuration: LiveTVSourcesConfiguration) throws {
        try configuration.validate()
        lock.lock()
        defer { lock.unlock() }
        self.configuration = configuration
    }
}

private actor PortableTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        let waiting = waiters
        waiters = []
        for waiter in waiting { waiter.resume() }
    }
}

private final class PortableAppliedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
    func increment() {
        lock.lock()
        defer { lock.unlock() }
        count += 1
    }
}
#endif
