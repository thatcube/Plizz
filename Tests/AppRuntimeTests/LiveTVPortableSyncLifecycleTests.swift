#if DEBUG
import CoreModels
import Foundation
import XCTest
@testable import AppRuntime

@MainActor
final class LiveTVPortableSyncLifecycleTests: XCTestCase {
    func testSnapshotIgnoresUnrelatedDefaultsRecentsAndBrowseButTracksFavorites() throws {
        let (defaults, profiles) = try fixture()
        let initial = LiveTVPortableChangeSnapshot(profiles: profiles, defaults: defaults)
        defaults.set("new-cloud-diagnostic", forKey: "unrelated")
        let preferences = LiveTVPreferencesStore(defaults: defaults)
        try preferences.save(.init(recentChannelIDs: ["recent"], browse: .init(sort: "name")))
        XCTAssertEqual(initial, LiveTVPortableChangeSnapshot(profiles: profiles, defaults: defaults))
        try preferences.save(.init(favoriteIDs: ["favorite"], recentChannelIDs: ["recent"]))
        XCTAssertNotEqual(initial, LiveTVPortableChangeSnapshot(profiles: profiles, defaults: defaults))
    }

    func testSourceAndPlaybackIdleNotificationsRequestPublish() async throws {
        let (defaults, profiles) = try fixture()
        let center = NotificationCenter()
        let published = expectation(description: "Both portable events request a debounced publish")
        published.expectedFulfillmentCount = 2
        let lifecycle = LiveTVPortableSyncLifecycle(
            profiles: profiles, defaults: defaults, notifications: center
        ) { published.fulfill() }
        center.post(name: .plozzLiveTVPortableStateDidChange, object: profiles.activeProfileID)
        center.post(name: .plozzLiveTVPlaybackIdentityDidBecomeIdle, object: profiles.activeProfileID)
        await fulfillment(of: [published], timeout: 2)
        withExtendedLifetime(lifecycle) {}
    }

    func testUnrelatedDefaultsDoNotCreatePublishLoopAndOwnedObserversAreReleased() async throws {
        let (defaults, profiles) = try fixture()
        let center = NotificationCenter()
        let unexpected = expectation(description: "No portable publication")
        unexpected.isInverted = true
        var lifecycle: LiveTVPortableSyncLifecycle? = .init(
            profiles: profiles, defaults: defaults, notifications: center
        ) { unexpected.fulfill() }
        weak var weakLifecycle = lifecycle
        defaults.set("updated", forKey: "cloud-engine-status")
        center.post(name: UserDefaults.didChangeNotification, object: defaults)
        await fulfillment(of: [unexpected], timeout: 0.05)
        lifecycle = nil
        XCTAssertNil(weakLifecycle)
        center.post(name: .plozzLiveTVPortableStateDidChange, object: nil)
    }

    func testAccountChangesAndSignOutRevokeConsentWithoutResettingOnEveryStatusTick() throws {
        let (defaults, profiles) = try fixture()
        let lifecycle = LiveTVPortableSyncLifecycle(profiles: profiles, defaults: defaults) {}
        var resets = 0
        lifecycle.accountStatusChanged(isSignedOut: false, accountTag: "first") { resets += 1 }
        lifecycle.accountStatusChanged(isSignedOut: false, accountTag: "first") { resets += 1 }
        XCTAssertEqual(resets, 0)
        lifecycle.accountStatusChanged(isSignedOut: false, accountTag: "second") { resets += 1 }
        XCTAssertEqual(resets, 1)
        lifecycle.accountStatusChanged(isSignedOut: true, accountTag: "second") { resets += 1 }
        lifecycle.accountStatusChanged(isSignedOut: true, accountTag: "second") { resets += 1 }
        XCTAssertEqual(resets, 2)
    }

    private func fixture() throws -> (UserDefaults, ProfilesModel) {
        let suite = "LiveTVPortableSyncLifecycleTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return (defaults, ProfilesModel(store: ProfileStore(defaults: defaults)))
    }
}
#endif
