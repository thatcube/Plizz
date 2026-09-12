import Foundation
import XCTest
@testable import CoreModels

final class LiveTVPortableSyncTests: XCTestCase {
    private let profileID = "profile"

    func testConsentCannotBeBorrowedWhenRootNamespaceOwnerChanges() throws {
        let fixture = try makeFixture()
        let original = LiveTVPortableSyncPreferenceStore(
            defaults: fixture.defaults, profileID: "original", namespace: nil
        )
        let replacement = LiveTVPortableSyncPreferenceStore(
            defaults: fixture.defaults, profileID: "replacement", namespace: nil
        )
        original.isEnabled = true
        XCTAssertTrue(original.isEnabled)
        XCTAssertFalse(replacement.isEnabled)
        replacement.isEnabled = true
        XCTAssertTrue(replacement.isEnabled)
        XCTAssertFalse(original.isEnabled)
    }

    func testReenablingReplaysMissedRemoteChangesWithoutOverwritingOfflineEdits() throws {
        let fixture = try makeFixture()
        let consent = LiveTVPortableSyncPreferenceStore(defaults: fixture.defaults, profileID: profileID)
        try fixture.preferences.save(.init(
            favoriteIDs: ["a", "b"], channelOverrides: ["a": .init(name: "Original"), "b": .init(name: "Original")]
        ))
        let initial = try fixture.adapter.capture(sourceStore: fixture.sources, fallback: [:])
        var baseline = initial
        for id in ["a", "b"] {
            let key = recordKey(.channel, id)
            let previous = try LiveTVPortableRecord.decode(try XCTUnwrap(initial[key.recordName]), key: key)
            var value = try XCTUnwrap(previous.channel)
            value.metadata = .init(name: "Remote")
            baseline[key.recordName] = try LiveTVPortableRecord(channel: value).encoded()
        }
        consent.isEnabled = false
        _ = try fixture.adapter.apply(baseline.mapValues(Optional.some), sourceStore: fixture.sources)
        try fixture.preferences.save(.init(
            favoriteIDs: ["a", "b"], channelOverrides: ["a": .init(name: "Original"), "b": .init(name: "Local edit")]
        ))
        consent.isEnabled = true
        let captured = try fixture.adapter.capture(sourceStore: fixture.sources, fallback: baseline)
        XCTAssertEqual(try fixture.preferences.load().channelOverrides["a"]?.name, "Remote")
        XCTAssertEqual(try fixture.preferences.load().channelOverrides["b"]?.name, "Local edit")
        XCTAssertEqual(captured[recordKey(.channel, "a").recordName], baseline[recordKey(.channel, "a").recordName])
        XCTAssertNotEqual(captured[recordKey(.channel, "b").recordName], baseline[recordKey(.channel, "b").recordName])
    }

    func testUnloadedCatalogDoesNotErasePreviouslyReceivedNativeIdentityHint() throws {
        let fixture = try makeFixture()
        let key = recordKey(.channel, "channel")
        let hint = LiveTVPortableChannelIdentityHint(sourceID: "source", nativeID: "native")
        let bytes = try LiveTVPortableRecord(channel: .init(isFavorite: true, identityHint: hint)).encoded()
        _ = try fixture.adapter.apply([key.recordName: bytes], sourceStore: fixture.sources)
        try fixture.adapter.acknowledgeIdentityHints(["channel"])
        let captured = try fixture.adapter.capture(
            sourceStore: fixture.sources, identityHints: [:], fallback: [key.recordName: bytes]
        )
        let result = try LiveTVPortableRecord.decode(try XCTUnwrap(captured[key.recordName]), key: key)
        XCTAssertEqual(result.channel?.identityHint, hint)
    }

    func testStaleFallbackCannotUndoFreshApplyBeforeOrAfterFirstCapture() throws {
        for capturesFirst in [false, true] {
            let fixture = try makeFixture()
            let key = recordKey(.channel, "channel")
            let old = try LiveTVPortableRecord(channel: .init(isFavorite: true)).encoded()
            let deleted = try LiveTVPortableRecord(isDeleted: true).encoded()
            _ = try fixture.adapter.apply([key.recordName: old], sourceStore: fixture.sources)
            if capturesFirst {
                _ = try fixture.adapter.capture(sourceStore: fixture.sources, fallback: [key.recordName: old])
            }
            _ = try fixture.adapter.apply([key.recordName: deleted], sourceStore: fixture.sources)
            for _ in 0..<2 {
                let captured = try fixture.adapter.capture(
                    sourceStore: fixture.sources, fallback: [key.recordName: old]
                )
                XCTAssertEqual(captured[key.recordName], deleted)
                XCTAssertTrue(try fixture.preferences.load().favoriteIDs.isEmpty)
            }
        }
    }

    func testFreshApplyDoesNotConsumeMissedReplayForUnrelatedRecords() throws {
        let fixture = try makeFixture()
        let consent = LiveTVPortableSyncPreferenceStore(defaults: fixture.defaults, profileID: profileID)
        try fixture.preferences.save(.init(
            favoriteIDs: ["a", "b"], channelOverrides: ["a": .init(name: "Initial"), "b": .init(name: "Initial")]
        ))
        let initial = try fixture.adapter.capture(sourceStore: fixture.sources, fallback: [:])
        consent.isEnabled = false
        var missed = initial
        for id in ["a", "b"] {
            let key = recordKey(.channel, id)
            var channel = try XCTUnwrap(LiveTVPortableRecord.decode(
                XCTUnwrap(initial[key.recordName]), key: key
            ).channel)
            channel.metadata = .init(name: "Missed")
            missed[key.recordName] = try LiveTVPortableRecord(channel: channel).encoded()
        }
        consent.isEnabled = true
        let freshKey = recordKey(.channel, "a")
        var fresh = try XCTUnwrap(LiveTVPortableRecord.decode(
            XCTUnwrap(missed[freshKey.recordName]), key: freshKey
        ).channel)
        fresh.metadata = .init(name: "Latest")
        _ = try fixture.adapter.apply(
            [freshKey.recordName: LiveTVPortableRecord(channel: fresh).encoded()], sourceStore: fixture.sources
        )
        _ = try fixture.adapter.capture(sourceStore: fixture.sources, fallback: missed)
        XCTAssertEqual(try fixture.preferences.load().channelOverrides["a"]?.name, "Latest")
        XCTAssertEqual(try fixture.preferences.load().channelOverrides["b"]?.name, "Missed")
    }

    func testFailedApplyRetriesExactFallbackWithoutOverwritingLaterLocalEdit() throws {
        for editsLocally in [false, true] {
            let fixture = try makeFixture()
            try fixture.preferences.save(.init(
                favoriteIDs: ["channel"], channelOverrides: ["channel": .init(name: "Initial")]
            ))
            let initial = try fixture.adapter.capture(sourceStore: fixture.sources, fallback: [:])
            let key = recordKey(.channel, "channel")
            var remote = try XCTUnwrap(LiveTVPortableRecord.decode(
                XCTUnwrap(initial[key.recordName]), key: key
            ).channel)
            remote.metadata = .init(name: "Remote")
            let bytes = try LiveTVPortableRecord(channel: remote).encoded()
            XCTAssertThrowsError(try fixture.adapter.apply(
                [key.recordName: bytes], sourceStore: UnavailablePortableSources()
            ))
            if editsLocally {
                try fixture.preferences.save(.init(
                    favoriteIDs: ["channel"], channelOverrides: ["channel": .init(name: "Local")]
                ))
            }
            for _ in 0..<2 {
                _ = try fixture.adapter.capture(sourceStore: fixture.sources, fallback: [key.recordName: bytes])
                XCTAssertEqual(
                    try fixture.preferences.load().channelOverrides["channel"]?.name,
                    editsLocally ? "Local" : "Remote"
                )
            }
        }
    }

    func testExplicitHintClearIsNotEchoedBackFromUnchangedCachedEvidence() throws {
        let fixture = try makeFixture()
        let key = recordKey(.channel, "channel")
        let hint = LiveTVPortableChannelIdentityHint(sourceID: "source", nativeID: "native")
        let original = try LiveTVPortableRecord(channel: .init(isFavorite: true, identityHint: hint)).encoded()
        _ = try fixture.adapter.apply([key.recordName: original], sourceStore: fixture.sources)
        try fixture.adapter.acknowledgeIdentityHints(["channel"])
        let cleared = try LiveTVPortableRecord(channel: .init(isFavorite: true)).encoded()
        _ = try fixture.adapter.apply([key.recordName: cleared], sourceStore: fixture.sources)
        let pending = try fixture.adapter.deferredIdentityHints()
        XCTAssertTrue(pending.keys.contains("channel"))
        XCTAssertNil(try XCTUnwrap(pending["channel"]))
        try fixture.adapter.acknowledgeIdentityHints(["channel"])
        let capture = try fixture.adapter.capture(
            sourceStore: fixture.sources, identityHints: ["channel": hint], fallback: [key.recordName: cleared]
        )
        let removed = try LiveTVPortableRecord.decode(try XCTUnwrap(capture[key.recordName]), key: key)
        XCTAssertNil(removed.channel?.identityHint)
        let changedHint = LiveTVPortableChannelIdentityHint(sourceID: "source", nativeID: "new-evidence")
        let changed = try fixture.adapter.capture(
            sourceStore: fixture.sources, identityHints: ["channel": changedHint], fallback: capture
        )
        XCTAssertEqual(
            try LiveTVPortableRecord.decode(XCTUnwrap(changed[key.recordName]), key: key).channel?.identityHint,
            changedHint
        )
    }

    func testCachedNativeHintCannotResurrectExplicitlyDeletedChannelState() throws {
        let fixture = try makeFixture()
        let key = recordKey(.channel, "channel")
        let hint = LiveTVPortableChannelIdentityHint(sourceID: "source", nativeID: "native")
        let original = try LiveTVPortableRecord(channel: .init(isFavorite: true, identityHint: hint)).encoded()
        _ = try fixture.adapter.apply([key.recordName: original], sourceStore: fixture.sources)
        let deleted = try LiveTVPortableRecord(isDeleted: true).encoded()
        _ = try fixture.adapter.apply([key.recordName: deleted], sourceStore: fixture.sources)
        try fixture.adapter.acknowledgeIdentityHints(["channel"])
        let capture = try fixture.adapter.capture(
            sourceStore: fixture.sources, identityHints: ["channel": hint], fallback: [key.recordName: deleted]
        )
        XCTAssertTrue(try LiveTVPortableRecord.decode(XCTUnwrap(capture[key.recordName]), key: key).isDeleted)
    }

    func testConsentDefaultsOffAndDoesNotTransferWithProfileSettings() throws {
        let fixture = try makeFixture(enabled: false)
        let key = recordKey(.channel, "channel")
        let bytes = try LiveTVPortableRecord(channel: .init(isFavorite: true)).encoded()
        XCTAssertFalse(fixture.adapter.isEnabled)
        XCTAssertEqual(try fixture.adapter.capture(sourceStore: fixture.sources, fallback: [key.recordName: bytes]), [key.recordName: bytes])
        XCTAssertEqual(try fixture.adapter.apply([key.recordName: bytes], sourceStore: fixture.sources).appliedCount, 0)
        XCTAssertEqual(try fixture.preferences.load(), .empty)
        XCTAssertFalse(ProfileSettingsTransfer.transferableBaseKeys.contains("com.plozz.liveTV.portableSync.enabled"))
    }

    func testPreferencesRoundTripPreservesLocalRecentsBrowseAndCanonicalRemoteBytes() throws {
        let sender = try makeFixture()
        let receiver = try makeFixture()
        try sender.preferences.save(.init(
            favoriteIDs: ["b", "a"], recentChannelIDs: ["sender-recent"],
            hiddenChannels: [.init(id: "hidden", name: "Hidden")],
            favoriteOrder: ["b", "a"], favoriteChannels: [.init(id: "a", name: "Favorite A")],
            channelOverrides: ["a": .init(name: "My name", category: "My group", language: "en", country: "US")],
            browse: .init(sort: "sender-sort", favoritesOnly: true)
        ))
        try receiver.preferences.save(.init(
            recentChannelIDs: ["receiver-recent"], browse: .init(sort: "receiver-sort")
        ))
        let records = try sender.adapter.capture(sourceStore: sender.sources, fallback: [:])
        _ = try receiver.adapter.apply(records.mapValues(Optional.some), sourceStore: receiver.sources)
        let prefs = try receiver.preferences.load()
        XCTAssertEqual(prefs.favoriteIDs, ["a", "b"])
        XCTAssertEqual(prefs.favoriteOrder, ["b", "a"])
        XCTAssertEqual(prefs.favoriteChannels, [.init(id: "a", name: "Favorite A")])
        XCTAssertEqual(prefs.channelOverrides["a"]?.name, "My name")
        XCTAssertEqual(prefs.hiddenChannelIDs, ["hidden"])
        XCTAssertEqual(prefs.recentChannelIDs, ["receiver-recent"])
        XCTAssertEqual(prefs.browse.sort, "receiver-sort")
        XCTAssertTrue(try receiver.adapter.deferredIdentityHints().isEmpty)
        XCTAssertTrue(try receiver.adapter.deferredGuideMappings().isEmpty)
        let recaptured = try receiver.adapter.capture(sourceStore: receiver.sources, fallback: records)
        XCTAssertEqual(recaptured, records)
    }

    func testUnfavoriteAndUnhideAreExplicitAndDoNotDeleteUnrelatedPeerChanges() throws {
        let sender = try makeFixture()
        let receiver = try makeFixture()
        try sender.preferences.save(.init(favoriteIDs: ["a"], hiddenChannels: [.init(id: "a", name: "A")]))
        let initial = try sender.adapter.capture(sourceStore: sender.sources, fallback: [:])
        _ = try receiver.adapter.apply(initial.mapValues(Optional.some), sourceStore: receiver.sources)
        try sender.preferences.save(.empty)
        let cleared = try sender.adapter.capture(sourceStore: sender.sources, fallback: initial)
        try receiver.preferences.save(.init(favoriteIDs: ["a", "unrelated"], hiddenChannels: [.init(id: "a", name: "A")]))
        _ = try receiver.adapter.apply(cleared.mapValues(Optional.some), sourceStore: receiver.sources)
        XCTAssertEqual(try receiver.preferences.load().favoriteIDs, ["unrelated"])
        XCTAssertTrue(try receiver.preferences.load().hiddenChannels.isEmpty)
    }

    func testPlaylistCredentialsStayLocalAndPendingDescriptorPreservesPausedState() throws {
        let sender = try makeFixture()
        let receiver = try makeFixture()
        let source = LiveTVPlaylistSource(
            id: "source", name: "News",
            playlistURL: URL(string: "https://host.test/path-password/list.m3u?token=query-secret")!,
            guideURLs: [URL(string: "https://host.test/guide-secret.xml")!], isEnabled: false
        )
        try sender.sources.save(.init(playlists: [source]))
        let records = try sender.adapter.capture(sourceStore: sender.sources, fallback: [:])
        let encoded = records.values.map { String(decoding: $0, as: UTF8.self) }.joined()
        for secret in ["path-password", "query-secret", "guide-secret", "https://"] {
            XCTAssertFalse(encoded.contains(secret))
        }
        let report = try receiver.adapter.apply(records.mapValues(Optional.some), sourceStore: receiver.sources)
        XCTAssertTrue(try receiver.sources.load().playlists.isEmpty)
        XCTAssertEqual(report.pendingPlaylists["source"]?.isEnabled, false)
        XCTAssertEqual(try receiver.adapter.capture(sourceStore: receiver.sources, fallback: records), records)
    }

    func testRemovingSourceKeepsTombstoneAndFavoritesAndCannotRetargetServer() throws {
        let fixture = try makeFixture()
        let source = LiveTVPlaylistSource(id: "source", name: "News", playlistURL: URL(string: "https://host.test/list.m3u")!)
        try fixture.sources.save(.init(playlists: [source], servers: [
            .init(id: "server", name: "Original", accountID: "allowed-account")
        ]))
        try fixture.preferences.save(.init(favoriteIDs: ["recoverable-channel"]))
        let before = try fixture.adapter.capture(sourceStore: fixture.sources, fallback: [:])
        var config = try fixture.sources.load()
        config.playlists = []
        try fixture.sources.save(config)
        let after = try fixture.adapter.capture(sourceStore: fixture.sources, fallback: before)
        let sourceKey = recordKey(.source, "source")
        XCTAssertTrue(try LiveTVPortableRecord.decode(XCTUnwrap(after[sourceKey.recordName]), key: sourceKey).isDeleted)
        XCTAssertEqual(try fixture.adapter.capture(sourceStore: fixture.sources, fallback: before), after)
        let malicious = try LiveTVPortableRecord(source: .init(
            kind: .server, name: "Different", isEnabled: true, accountID: "other-account"
        )).encoded()
        _ = try fixture.adapter.apply([recordKey(.source, "server").recordName: malicious], sourceStore: fixture.sources)
        XCTAssertEqual(try fixture.sources.load().servers.first?.accountID, "allowed-account")
        XCTAssertEqual(try fixture.preferences.load().favoriteIDs, ["recoverable-channel"])
    }

    func testOptInHydratesPreviouslyFetchedRemoteFavoritesWithoutErasingLocalChoices() throws {
        let fixture = try makeFixture(enabled: false)
        try fixture.preferences.save(.init(favoriteIDs: ["local"]))
        let remote = try LiveTVPortableRecord(channel: .init(isFavorite: true)).encoded()
        let baseline = [recordKey(.channel, "remote").recordName: remote]
        _ = try fixture.adapter.apply(baseline.mapValues(Optional.some), sourceStore: fixture.sources)
        LiveTVPortableSyncPreferenceStore(defaults: fixture.defaults, profileID: profileID).isEnabled = true
        _ = try fixture.adapter.capture(sourceStore: fixture.sources, fallback: baseline)
        XCTAssertEqual(try fixture.preferences.load().favoriteIDs, ["local", "remote"])
    }

    func testUnknownProfileMalformedAndOversizedRecordsDoNotMutateStores() throws {
        let fixture = try makeFixture()
        let otherKey = LiveTVPortableRecordKey(profileID: "other", kind: .channel, entityID: "other-channel")
        let other = try LiveTVPortableRecord(channel: .init(isFavorite: true)).encoded()
        let report = try fixture.adapter.apply([
            otherKey.recordName: other,
            recordKey(.channel, "bad").recordName: Data("bad".utf8),
            recordKey(.channel, "large").recordName: Data(repeating: 0, count: LiveTVPortableRecord.maximumBytes + 1)
        ], sourceStore: fixture.sources)
        XCTAssertEqual(report.rejectedCount, 2)
        XCTAssertEqual(try fixture.preferences.load(), .empty)
        XCTAssertTrue(try fixture.sources.load().playlists.isEmpty)
    }

    func testCloudDeletionRemainsTombstoneAndAccountChangeRequiresNewConsent() throws {
        let fixture = try makeFixture()
        let key = recordKey(.channel, "deleted")
        var deletion: SyncLocalChanges = [:]
        deletion.updateValue(nil, forKey: key.recordName)
        _ = try fixture.adapter.apply(deletion, sourceStore: fixture.sources)
        let captured = try fixture.adapter.capture(sourceStore: fixture.sources, fallback: [:])
        XCTAssertTrue(try LiveTVPortableRecord.decode(XCTUnwrap(captured[key.recordName]), key: key).isDeleted)
        try fixture.adapter.resetForAccountChange()
        XCTAssertFalse(fixture.adapter.isEnabled)
    }

    func testMappingOverrideRoundTripsAndExplicitRemovalIsReported() throws {
        let fixture = try makeFixture()
        let mapping = LiveTVPortableGuideMapping(guideSourceID: "guide", guideChannelID: "station")
        let records = try fixture.adapter.capture(
            sourceStore: fixture.sources, guideMappings: ["channel": mapping], fallback: [:]
        )
        let key = recordKey(.channel, "channel")
        XCTAssertEqual(try LiveTVPortableRecord.decode(XCTUnwrap(records[key.recordName]), key: key).channel?.guideMapping, mapping)
        let removal = try LiveTVPortableRecord(channel: .init()).encoded()
        let report = try fixture.adapter.apply([key.recordName: removal], sourceStore: fixture.sources)
        XCTAssertTrue(report.guideMappings.keys.contains("channel"))
        XCTAssertNil(report.guideMappings["channel"]!)
        let recaptured = try fixture.adapter.capture(sourceStore: fixture.sources, guideMappings: [:], fallback: records)
        XCTAssertEqual(recaptured[key.recordName], removal)
    }

    func testUnavailableGuideExportPreservesMappingUntilAnActualLocalRemoval() throws {
        let fixture = try makeFixture()
        let key = recordKey(.channel, "channel")
        let mapping = LiveTVPortableGuideMapping(
            guideSourceID: "feed-v1-" + String(repeating: "a", count: 64), guideChannelID: "station"
        )
        let first = try fixture.adapter.capture(
            sourceStore: fixture.sources, guideMappings: ["channel": mapping], fallback: [:]
        )
        let unavailable = try fixture.adapter.capture(
            sourceStore: fixture.sources, guideMappings: [:],
            unresolvedGuideMappingIDs: ["channel"], fallback: first
        )
        let retained = try LiveTVPortableRecord.decode(XCTUnwrap(unavailable[key.recordName]), key: key)
        XCTAssertEqual(retained.channel?.guideMapping, mapping)
        let removed = try fixture.adapter.capture(
            sourceStore: fixture.sources, guideMappings: [:], fallback: unavailable
        )
        XCTAssertNil(try LiveTVPortableRecord.decode(XCTUnwrap(removed[key.recordName]), key: key).channel?.guideMapping)
    }

    func testPortableFeedBindingRetainsExactCredentialsWithoutExportingAddresses() throws {
        let source = LiveTVPlaylistSource(
            id: "source", name: "Source",
            playlistURL: try XCTUnwrap(URL(string: "https://host.test/list.m3u?token=playlist-secret"))
        )
        let guideURL = try XCTUnwrap(URL(string: "https://host.test/guide.xml?token=guide-secret"))
        let changedURL = try XCTUnwrap(URL(string: "https://host.test/guide.xml?token=changed-secret"))
        let identity = LiveTVPortableGuideMapping.boundSourceID(playlist: source, guideURL: guideURL)
        XCTAssertEqual(identity, LiveTVPortableGuideMapping.boundSourceID(playlist: source, guideURL: guideURL))
        XCTAssertNotEqual(identity, LiveTVPortableGuideMapping.boundSourceID(playlist: source, guideURL: changedURL))
        let mapping = LiveTVPortableGuideMapping(guideSourceID: identity, guideChannelID: "station")
        XCTAssertTrue(mapping.isSafe)
        XCTAssertTrue(mapping.hasBoundSourceIdentity)
        XCTAssertFalse(LiveTVPortableGuideMapping(guideSourceID: "guide-local", guideChannelID: "station").hasBoundSourceIdentity)
        let text = String(decoding: try JSONEncoder().encode(mapping), as: UTF8.self)
        for secret in ["https://", "playlist-secret", "guide-secret", "host.test"] {
            XCTAssertFalse(text.contains(secret))
        }
    }

    func testRecordNamesRoundTripWithoutDelimiterOrPathAmbiguity() {
        let key = LiveTVPortableRecordKey(profileID: "profile:/% ü", kind: .channel, entityID: "channel:a/b:?")
        XCTAssertEqual(LiveTVPortableRecordKey.parse(key.recordName), key)
        XCTAssertNil(LiveTVPortableRecordKey.parse(key.recordName + ":extra"))
        XCTAssertNil(LiveTVPortableRecordKey.parse("liveTV:::"))
    }

    func testLibraryDefinitionWaitsForEveryImmutableSnapshotPart() throws {
        let sender = try makeFixture()
        let receiver = try makeFixture()
        let library = LibraryChannelLibrary(accountID: "account", libraryID: "library")
        let snapshot = try LibraryChannelSnapshot(
            items: (0..<300).map {
                try LibraryChannelItem(
                    item: .init(id: "item-\($0)", title: "Item \($0)", kind: .movie, runtime: 60),
                    library: library, serverID: "server", userID: "user"
                )
            }, createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let definition = LibraryChannelDefinition(profileID: profileID, revisions: [
            .init(snapshotID: snapshot.id, recipe: .init(name: "Movies", libraries: [library]), epochSeconds: 1_700_000_000)
        ])
        XCTAssertThrowsError(try sender.adapter.capture(
            sourceStore: sender.sources, libraryDefinitions: [definition], snapshots: [], fallback: [:]
        ))
        XCTAssertThrowsError(try sender.adapter.capture(
            sourceStore: sender.sources, libraryDefinitions: [], snapshots: [snapshot], fallback: [:]
        ))
        let records = try sender.adapter.capture(
            sourceStore: sender.sources, libraryDefinitions: [definition], snapshots: [snapshot], fallback: [:]
        )
        let definitionKey = recordKey(.library, definition.id.uuidString)
        let definitionBytes = try XCTUnwrap(records[definitionKey.recordName])
        let partial = try receiver.adapter.apply(
            [definitionKey.recordName: definitionBytes], sourceStore: receiver.sources
        )
        XCTAssertTrue(partial.libraryDefinitions.isEmpty)
        XCTAssertEqual(partial.incompleteSnapshotIDs, [snapshot.id])
        let pendingCapture = try receiver.adapter.capture(
            sourceStore: receiver.sources, libraryDefinitions: [], fallback: [definitionKey.recordName: definitionBytes]
        )
        XCTAssertEqual(pendingCapture[definitionKey.recordName], definitionBytes)
        let complete = try receiver.adapter.apply(records.mapValues(Optional.some), sourceStore: receiver.sources)
        XCTAssertEqual(complete.libraryDefinitions, [definition])
        XCTAssertEqual(complete.snapshots, [snapshot])
        XCTAssertTrue(complete.incompleteSnapshotIDs.isEmpty)
        try receiver.adapter.acknowledgeLibraries([definition.id])
        XCTAssertTrue(try receiver.adapter.pending(sourceStore: receiver.sources).libraryDefinitions.isEmpty)
        _ = try sender.adapter.apply(
            [definitionKey.recordName: definitionBytes], sourceStore: sender.sources
        )
        try sender.adapter.markLibrariesForReview([definition.id])
        let locallyDeleted = try sender.adapter.capture(
            sourceStore: sender.sources, libraryDefinitions: [], fallback: records
        )
        XCTAssertTrue(try LiveTVPortableRecord.decode(
            XCTUnwrap(locallyDeleted[definitionKey.recordName]), key: definitionKey
        ).isDeleted)
        XCTAssertTrue(try sender.adapter.pending(sourceStore: sender.sources).libraryReviewIDs.isEmpty)
    }

    func testRemovedServerSuppressionReachesDeviceWithoutLocalSource() throws {
        let sender = try makeFixture()
        let receiver = try makeFixture()
        try sender.sources.save(.init(servers: [
            .init(id: "manual-source", name: "Server", accountID: "account")
        ]))
        let initial = try sender.adapter.capture(sourceStore: sender.sources, fallback: [:])
        try sender.sources.save(.empty)
        let removed = try sender.adapter.capture(sourceStore: sender.sources, fallback: initial)
        _ = try receiver.adapter.apply(removed.mapValues(Optional.some), sourceStore: receiver.sources)
        let suppression = LiveTVServerEnrollmentSuppressionStore(defaults: receiver.defaults, profileID: profileID)
        XCTAssertEqual(try suppression.suppressedAccountIDs(), ["account"])
        XCTAssertTrue(try receiver.sources.load().servers.isEmpty)
    }

    func testSafeNativeIdentityHintsTransferButURLBasedHintsAreRejected() throws {
        let fixture = try makeFixture()
        try fixture.preferences.save(.init(favoriteIDs: ["channel"]))
        let hint = LiveTVPortableChannelIdentityHint(sourceID: "source", nativeID: "BBC.One")
        let capture = try fixture.adapter.capture(
            sourceStore: fixture.sources, identityHints: ["channel": hint], fallback: [:]
        )
        let key = recordKey(.channel, "channel")
        XCTAssertEqual(try LiveTVPortableRecord.decode(XCTUnwrap(capture[key.recordName]), key: key).channel?.identityHint, hint)
        let receiver = try makeFixture()
        _ = try receiver.adapter.apply(capture.mapValues(Optional.some), sourceStore: receiver.sources)
        XCTAssertEqual(try receiver.adapter.deferredIdentityHints()["channel"]!, hint)
        try receiver.adapter.acknowledgeIdentityHints(["channel"])
        XCTAssertTrue(try receiver.adapter.deferredIdentityHints().isEmpty)
        let favoriteOnlyChange = try LiveTVPortableRecord(channel: .init(
            isFavorite: false, identityHint: hint
        )).encoded()
        _ = try receiver.adapter.apply([key.recordName: favoriteOnlyChange], sourceStore: receiver.sources)
        XCTAssertTrue(try receiver.adapter.deferredIdentityHints().isEmpty, "Favorite edits must not trigger catalog re-import")
        let unsafe = LiveTVPortableRecord(channel: .init(identityHint: .init(
            sourceID: "source", nativeID: "https://host.test/secret?id=credential"
        )))
        XCTAssertThrowsError(try unsafe.validate(key: key))
    }

    func testIdentityHintsAloneDoNotPublishDownloadedCatalog() throws {
        let fixture = try makeFixture()
        let hints = Dictionary(uniqueKeysWithValues: (0..<1_000).map {
            ("channel-\($0)", LiveTVPortableChannelIdentityHint(sourceID: "source", nativeID: "station.\($0)"))
        })
        let records = try fixture.adapter.capture(
            sourceStore: fixture.sources, identityHints: hints, fallback: [:]
        )
        XCTAssertTrue(records.isEmpty)
    }

    func testAccountChangeInvalidatesEvenMissingProfileConsentAndOldAdapterInstances() throws {
        let fixture = try makeFixture()
        let missingProfile = LiveTVPortableSyncPreferenceStore(defaults: fixture.defaults, profileID: "missing-profile")
        missingProfile.isEnabled = true
        XCTAssertTrue(fixture.adapter.isEnabled)
        LiveTVPortableSyncPreferenceStore.accountDidChange(defaults: fixture.defaults)
        XCTAssertFalse(missingProfile.isEnabled)
        XCTAssertFalse(fixture.adapter.isEnabled)
        LiveTVPortableSyncPreferenceStore(defaults: fixture.defaults, profileID: profileID).isEnabled = true
        XCTAssertFalse(fixture.adapter.isEnabled, "A stale adapter must not reopen the old household's journal")
        fixture.defaults.set("../old-household", forKey: "com.plozz.liveTV.portableSync.accountEpoch")
        let preference = LiveTVPortableSyncPreferenceStore(defaults: fixture.defaults, profileID: profileID)
        preference.isEnabled = true
        XCTAssertFalse(preference.isEnabled, "Corrupt epochs cannot opt in or select a journal path")
    }

    func testRemoteServerReenableAndSuppressionArriveInEitherOrderWithoutRecaptureClobber() throws {
        for sourceFirst in [true, false] {
            let fixture = try makeFixture()
            try fixture.sources.save(.init(servers: [.init(id: "server", name: "Server", accountID: "account", isEnabled: false)]))
            let policyStore = LiveTVApprovalAwareSourcesStore(
                underlying: fixture.sources,
                approvals: .init(defaults: fixture.defaults, profileID: profileID)
            )
            let baseline = try fixture.adapter.capture(sourceStore: policyStore, fallback: [:])
            let sourceKey = recordKey(.source, "server")
            let permissionKey = recordKey(.serverEnrollment, "account")
            let source = try LiveTVPortableRecord(source: .init(
                kind: .server, name: "Server", isEnabled: true, accountID: "account"
            )).encoded()
            let permission = try LiveTVPortableRecord(serverEnrollmentSuppressed: false).encoded()
            let first = sourceFirst ? [sourceKey.recordName: source] : [permissionKey.recordName: permission]
            let last = sourceFirst ? [permissionKey.recordName: permission] : [sourceKey.recordName: source]
            _ = try fixture.adapter.apply(first.mapValues(Optional.some), sourceStore: policyStore)
            XCTAssertEqual(try policyStore.load().servers.first?.isEnabled, false)
            let middle = try fixture.adapter.capture(sourceStore: policyStore, fallback: baseline)
            for (key, bytes) in first { XCTAssertEqual(middle[key], bytes) }
            _ = try fixture.adapter.apply(last.mapValues(Optional.some), sourceStore: policyStore)
            XCTAssertEqual(try policyStore.load().servers.first?.isEnabled, true)
        }
    }

    func testGuidePreferencesSyncWithoutRetargetingLocalURLsOrGuideIDs() throws {
        let sender = try makeFixture()
        let receiver = try makeFixture()
        let remote = LiveTVPlaylistSource(
            id: "source", name: "News", playlistURL: URL(string: "https://remote.test/secret.m3u")!,
            guideURLs: [URL(string: "https://remote.test/guide.xml")!], guideSourceIDs: ["remote-guide"],
            discoversPlaylistGuides: false, guideLookbackDays: 2, guideLookaheadDays: 14
        )
        let local = LiveTVPlaylistSource(
            id: "source", name: "News", playlistURL: URL(string: "https://local.test/secret.m3u")!,
            guideURLs: [URL(string: "https://local.test/guide.xml")!], guideSourceIDs: ["local-guide"]
        )
        try sender.sources.save(.init(playlists: [remote]))
        try receiver.sources.save(.init(playlists: [local]))
        let records = try sender.adapter.capture(sourceStore: sender.sources, fallback: [:])
        _ = try receiver.adapter.apply(records.mapValues(Optional.some), sourceStore: receiver.sources)
        let applied = try XCTUnwrap(receiver.sources.load().playlists.first)
        XCTAssertEqual(applied.playlistURL, local.playlistURL)
        XCTAssertEqual(applied.guideURLs, local.guideURLs)
        XCTAssertEqual(applied.guideSourceIDs, local.guideSourceIDs)
        XCTAssertFalse(applied.discoversPlaylistGuides)
        XCTAssertEqual(applied.guideLookbackDays, 2)
        XCTAssertEqual(applied.guideLookaheadDays, 14)
        XCTAssertEqual(try receiver.adapter.capture(sourceStore: receiver.sources, fallback: records), records)
    }

    func testCredentialLikeGuideIDsStayLocalWhileFavoritesStillSync() throws {
        let fixture = try makeFixture()
        try fixture.preferences.save(.init(favoriteIDs: ["channel"]))
        let unsafe = LiveTVPortableGuideMapping(
            guideSourceID: "guide", guideChannelID: "https://guide.test/path-secret?token=guide-secret"
        )
        XCTAssertFalse(unsafe.isSafe)
        XCTAssertTrue(LiveTVPortableGuideMapping(guideSourceID: "guide", guideChannelID: "station@West").isSafe)
        let records = try fixture.adapter.capture(
            sourceStore: fixture.sources, guideMappings: ["channel": unsafe], fallback: [:]
        )
        let key = recordKey(.channel, "channel")
        let bytes = try XCTUnwrap(records[key.recordName])
        let decoded = try LiveTVPortableRecord.decode(bytes, key: key)
        XCTAssertEqual(decoded.channel?.isFavorite, true)
        XCTAssertNil(decoded.channel?.guideMapping)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("guide-secret"))
        XCTAssertThrowsError(try LiveTVPortableRecord(channel: .init(guideMapping: unsafe)).validate(key: key))
    }

    func testImportedPlaylistMetadataNeverCreatesRemoteURLSetupOffer() throws {
        let sender = try makeFixture()
        let receiver = try makeFixture()
        let sourceID = UUID().uuidString
        let source = LiveTVPlaylistSource(
            id: sourceID, name: "Imported file",
            playlistURL: URL(string: "plozz-playlist://\(sourceID.lowercased())")!
        )
        try sender.sources.save(.init(playlists: [source]))
        let records = try sender.adapter.capture(sourceStore: sender.sources, fallback: [:])
        XCTAssertFalse(records.values.contains {
            String(decoding: $0, as: UTF8.self).contains("plozz-playlist")
        })
        let received = try receiver.adapter.apply(records.mapValues(Optional.some), sourceStore: receiver.sources)
        XCTAssertTrue(received.pendingPlaylists.isEmpty)
        XCTAssertEqual(received.localFileSources[sourceID]?.kind, .importedPlaylist)
        XCTAssertTrue(try receiver.sources.load().playlists.isEmpty)
        XCTAssertEqual(try receiver.adapter.capture(sourceStore: receiver.sources, fallback: records), records)

        let conflictingURLDescriptor = try LiveTVPortableRecord(source: .init(
            kind: .playlist, name: source.name, isEnabled: true
        )).encoded()
        let result = try sender.adapter.apply([
            recordKey(.source, sourceID).recordName: conflictingURLDescriptor
        ], sourceStore: sender.sources)
        XCTAssertEqual(result.rejectedCount, 1)
        XCTAssertEqual(try sender.sources.load().playlists.first?.playlistURL, source.playlistURL)
    }

    private func recordKey(_ kind: LiveTVPortableRecordKey.Kind, _ id: String) -> LiveTVPortableRecordKey {
        .init(profileID: profileID, kind: kind, entityID: id)
    }

    private func makeFixture(enabled: Bool = true) throws -> Fixture {
        let suite = "LiveTVPortableSyncTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/live-tv-portable-tests/\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
        }
        LiveTVPortableSyncPreferenceStore(defaults: defaults, profileID: profileID).isEnabled = enabled
        return Fixture(
            defaults: defaults,
            adapter: .init(directory: root, profileID: profileID, defaults: defaults),
            sources: PortableTestSources(),
            preferences: .init(defaults: defaults, namespace: profileID)
        )
    }

    private struct Fixture {
        let defaults: UserDefaults
        let adapter: LiveTVPortableSyncAdapter
        let sources: PortableTestSources
        let preferences: LiveTVPreferencesStore
    }
}

private struct UnavailablePortableSources: LiveTVSourcesStoring {
    func load() throws -> LiveTVSourcesConfiguration { throw CocoaError(.fileReadNoPermission) }
    func save(_ configuration: LiveTVSourcesConfiguration) throws { throw CocoaError(.fileWriteNoPermission) }
}

private final class PortableTestSources: LiveTVSourcesStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var configuration = LiveTVSourcesConfiguration.empty

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
