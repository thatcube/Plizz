#if DEBUG
import CoreModels
import XCTest
@testable import AppRuntime

@MainActor
final class LiveTVLibraryStorageTests: XCTestCase {
    func testRecordedOwnerUsesRootNamespaceInsteadOfSentinelProfile() throws {
        let suite = "LiveTVLibraryStorageTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let owner = Profile(id: "owner", name: "Owner")
        let sentinel = Profile(id: ProfileStore.defaultProfileID, name: "Separate profile")
        let store = ProfileStore(defaults: defaults)
        store.saveProfiles([owner, sentinel])
        store.setRootNamespaceOwnerID(owner.id)
        let profiles = ProfilesModel(store: store)

        XCTAssertNil(LiveTVLibraryStorage.preferencesNamespace(profileID: owner.id, profiles: profiles))
        XCTAssertEqual(
            LiveTVLibraryStorage.preferencesNamespace(profileID: sentinel.id, profiles: profiles),
            sentinel.id
        )
    }

    func testDeletedOwnerDoesNotGiveRootNamespaceToRemainingProfile() throws {
        let suite = "LiveTVLibraryStorageTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let remaining = Profile(id: ProfileStore.defaultProfileID, name: "Remaining profile")
        let store = ProfileStore(defaults: defaults)
        store.saveProfiles([remaining])
        store.setRootNamespaceOwnerID("deleted-owner")
        let profiles = ProfilesModel(store: store)

        XCTAssertNil(profiles.rootNamespaceOwnerID)
        XCTAssertEqual(
            LiveTVLibraryStorage.preferencesNamespace(profileID: remaining.id, profiles: profiles),
            remaining.id
        )
        XCTAssertEqual(
            LiveTVLibraryStorage.preferencesNamespace(profileID: "deleted-owner", profiles: profiles),
            "deleted-owner"
        )
    }

    func testNamespaceMatchesProfileModelAfterSelectionChanges() throws {
        let suite = "LiveTVLibraryStorageTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let owner = Profile(id: "owner", name: "Owner")
        let other = Profile(id: "other", name: "Other")
        let store = ProfileStore(defaults: defaults)
        store.saveProfiles([owner, other])
        store.setRootNamespaceOwnerID(owner.id)
        let profiles = ProfilesModel(store: store)

        for profile in [owner, other, owner] {
            profiles.select(profile.id)
            XCTAssertEqual(
                LiveTVLibraryStorage.preferencesNamespace(profileID: profile.id, profiles: profiles),
                profiles.activeNamespace
            )
        }
    }
}
#endif
