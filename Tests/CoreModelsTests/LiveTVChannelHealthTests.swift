import Foundation
import XCTest
@testable import CoreModels

final class LiveTVChannelHealthTests: XCTestCase {
    func testHealthIdentityNeverPersistsURLsCredentialsOrLegacyChannelIDs() throws {
        let identity = LiveTVChannelHealthIdentity(
            profileID: "profile-one", sourceID: "source-one",
            channelID: "https://provider.test/path-secret?token=channel-secret",
            streamIdentity: "https://provider.test/live?token=stream-secret"
        )
        let record = LiveTVChannelHealthRecord(
            identity: identity, status: .unavailable, reason: .repeatedlyMissing,
            checkedAt: Date(timeIntervalSince1970: 100), isScanHidden: true
        )
        let encoded = try JSONEncoder().encode(record)
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        for forbidden in ["https", "provider.test", "token", "path-secret", "channel-secret", "stream-secret"] {
            XCTAssertFalse(text.contains(forbidden))
        }
        XCTAssertTrue(identity.isValid)
    }

    func testProfileSourceChannelAndStreamAllScopeIdentity() {
        func key(_ profile: String = "a", _ source: String = "s", _ channel: String = "c", _ stream: String = "v1") -> LiveTVChannelHealthIdentity {
            LiveTVChannelHealthIdentity(profileID: profile, sourceID: source, channelID: channel, streamIdentity: stream)
        }
        let identities = [key(), key("b"), key("a", "t"), key("a", "s", "d"), key("a", "s", "c", "v2")]
        XCTAssertEqual(Set(identities).count, 5)
        XCTAssertNotEqual(LiveTVChannelHealthIdentity.digest(["ab", "c"]), LiveTVChannelHealthIdentity.digest(["a", "bc"]))
    }

    func testOnlyRepeatedMissingLinksCanBeScanHiddenAndRestorePreservesEvidence() {
        let key = LiveTVChannelHealthIdentity(profileID: "a", sourceID: "s", channelID: "c", streamIdentity: "v1")
        for status in [LiveTVChannelHealthStatus.reachable, .uncertain] {
            let record = LiveTVChannelHealthRecord(
                identity: key, status: status, reason: .timedOut, checkedAt: Date(), isScanHidden: true
            )
            XCTAssertFalse(record.isScanHidden)
        }
        let checkedAt = Date()
        let missing = LiveTVChannelHealthRecord(
            identity: key, status: .unavailable, reason: .repeatedlyMissing, checkedAt: checkedAt, isScanHidden: true
        )
        let restored = missing.restored()
        XCTAssertFalse(restored.isScanHidden)
        XCTAssertEqual(restored.identity, key)
        XCTAssertEqual(restored.status, .unavailable)
        XCTAssertEqual(restored.checkedAt, checkedAt)
    }

    func testPersistenceIsProfileScopedAndDoesNotTouchManualPreferences() throws {
        let suite = "LiveTVChannelHealthTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LiveTVChannelHealthStore(defaults: defaults, namespace: "one")
        let preferences = LiveTVPreferencesStore(defaults: defaults, namespace: "one")
        let manual = LiveTVPreferences(favoriteIDs: ["c"], hiddenChannels: [.init(id: "c", name: "Channel")])
        try preferences.save(manual)
        let record = LiveTVChannelHealthRecord(
            identity: .init(profileID: "one", sourceID: "s", channelID: "c", streamIdentity: "v1"),
            status: .unavailable, reason: .repeatedlyMissing, checkedAt: Date(), isScanHidden: true
        )
        try store.save([record])
        XCTAssertEqual(try store.load(), [record])
        XCTAssertTrue(try LiveTVChannelHealthStore(defaults: defaults, namespace: "two").load().isEmpty)
        try store.save([record.restored()])
        XCTAssertEqual(try preferences.load(), manual)
    }

    func testCorruptHealthIsNotSilentlyOverwritten() throws {
        let suite = "LiveTVChannelHealthTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = LiveTVChannelHealthStore.baseKey
        let original = Data("not-json".utf8)
        defaults.set(original, forKey: key)
        let store = LiveTVChannelHealthStore(defaults: defaults)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save([]))
        XCTAssertEqual(defaults.data(forKey: key), original)
    }
}
