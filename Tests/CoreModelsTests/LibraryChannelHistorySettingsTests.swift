import CoreModels
import Foundation
import XCTest

@MainActor
final class LibraryChannelHistorySettingsTests: XCTestCase {
    func testDefaultOffProfileScopedAndEachOptInStartsNewAuthorization() {
        let suite = "library-channel-history-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = LibraryChannelHistorySettings(defaults: defaults, namespace: "one")
        let second = LibraryChannelHistorySettings(defaults: defaults, namespace: "two")
        XCTAssertFalse(first.isEnabled)
        XCTAssertNil(first.authorizationID)
        first.setEnabled(true)
        let token = first.authorizationID
        XCTAssertNotNil(token)
        XCTAssertFalse(second.isEnabled)
        first.setEnabled(false)
        XCTAssertNil(first.authorizationID)
        first.setEnabled(true)
        XCTAssertNotEqual(token, first.authorizationID)
        let restored = LibraryChannelHistorySettings(defaults: defaults, namespace: "one")
        XCTAssertTrue(restored.isEnabled)
        XCTAssertNotEqual(restored.authorizationID, first.authorizationID)
    }

    func testSharedConsumersImmediatelyObserveTheSameOptOutAndNextGrant() {
        let namespace = "library-history-shared-\(UUID().uuidString)"
        let otherNamespace = "library-history-shared-\(UUID().uuidString)"
        let settings = LibraryChannelHistorySettings.shared(namespace: namespace)
        let decoder = LibraryChannelHistorySettings.shared(namespace: namespace)
        let otherProfile = LibraryChannelHistorySettings.shared(namespace: otherNamespace)
        defer {
            settings.setEnabled(false)
            otherProfile.setEnabled(false)
            for namespace in [namespace, otherNamespace] {
                UserDefaults.standard.removeObject(forKey: SettingsKey.scoped(
                    "com.plozz.liveTV.libraryChannelHistory", namespace: namespace
                ))
            }
        }
        XCTAssertTrue(settings === decoder)
        XCTAssertFalse(settings === otherProfile)
        settings.setEnabled(true)
        let firstGrant = decoder.authorizationID
        XCTAssertNotNil(firstGrant)
        XCTAssertEqual(settings.authorizationID, firstGrant)
        XCTAssertFalse(otherProfile.isEnabled)
        settings.setEnabled(false)
        XCTAssertFalse(decoder.isEnabled)
        XCTAssertNil(decoder.authorizationID)
        settings.setEnabled(true)
        XCTAssertNotNil(decoder.authorizationID)
        XCTAssertNotEqual(decoder.authorizationID, firstGrant)
        XCTAssertTrue(settings === LibraryChannelHistorySettings.shared(namespace: namespace))
    }

    func testSharedCacheUsesTheNormalizedScopedKey() {
        XCTAssertTrue(
            LibraryChannelHistorySettings.shared(namespace: nil)
                === LibraryChannelHistorySettings.shared(namespace: "")
        )
    }

    func testDefaultsNotificationsReloadAnotherInstancesChangesWithoutRotatingUnchangedGrants() {
        let suite = "library-channel-history-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let writer = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = SettingsKey.scoped("com.plozz.liveTV.libraryChannelHistory", namespace: "one")
        let settings = LibraryChannelHistorySettings(defaults: defaults, namespace: "one")
        settings.setEnabled(true)
        let original = settings.authorizationID
        XCTAssertNotNil(original)

        writer.set(true, forKey: "unrelated-setting")
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: writer)
        XCTAssertEqual(settings.authorizationID, original)

        writer.set(false, forKey: key)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: writer)
        XCTAssertFalse(settings.isEnabled)
        XCTAssertNil(settings.authorizationID)

        writer.set(true, forKey: key)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: writer)
        XCTAssertTrue(settings.isEnabled)
        XCTAssertNotNil(settings.authorizationID)
        XCTAssertNotEqual(settings.authorizationID, original)
    }

    func testExplicitReloadKeepsTheGrantStableAndRevokesDeletedPreferences() {
        let suite = "library-channel-history-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = SettingsKey.scoped("com.plozz.liveTV.libraryChannelHistory", namespace: "one")
        let settings = LibraryChannelHistorySettings(defaults: defaults, namespace: "one")
        defaults.set(true, forKey: key)
        settings.reload()
        let token = settings.authorizationID
        XCTAssertNotNil(token)
        settings.reload()
        XCTAssertEqual(settings.authorizationID, token)
        defaults.removeObject(forKey: key)
        settings.reload()
        XCTAssertFalse(settings.isEnabled)
        XCTAssertNil(settings.authorizationID)
    }

    func testIsolatedSettingsAreNotRetainedByTheirDefaultsObserver() {
        let suite = "library-channel-history-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        weak var reference: LibraryChannelHistorySettings?
        do {
            let settings = LibraryChannelHistorySettings(defaults: defaults, namespace: "one")
            reference = settings
            XCTAssertNotNil(reference)
        }
        XCTAssertNil(reference)
    }
}
