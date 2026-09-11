#if DEBUG
import CoreModels
import Foundation
import XCTest
@testable import FeatureLiveTV

@MainActor
final class LiveTVSourceAccessTests: XCTestCase {
    func testAdultSourceManagementDoesNotRequireTheHouseholdPIN() throws {
        let (profiles, suite) = makeProfiles()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        profiles.setParentalPIN(try XCTUnwrap(ParentalPIN.make(pin: "1234", iterations: 1)))
        let access = LiveTVSourceManagementAccess(profiles: profiles)
        XCTAssertTrue(access.canManage)
    }

    func testKidsOnlyRequireUnlockWhenAParentalPINExists() throws {
        let (profiles, suite) = makeProfiles()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let child = profiles.add(name: "Child", isKidsProfile: true)
        profiles.select(child.id)
        let access = LiveTVSourceManagementAccess(profiles: profiles)
        XCTAssertTrue(access.canManage)
        profiles.setParentalPIN(try XCTUnwrap(ParentalPIN.make(pin: "1234", iterations: 1)))
        XCTAssertFalse(access.canManage)
        access.unlock("0000")
        XCTAssertFalse(access.canManage)
        access.unlock("1234")
        XCTAssertTrue(access.canManage)
        access.lock()
        XCTAssertFalse(access.canManage)
    }

    func testChangingTheParentalPINRevokesAnExistingGrant() throws {
        let (profiles, suite) = makeProfiles()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let child = profiles.add(name: "Child", isKidsProfile: true)
        profiles.select(child.id)
        profiles.setParentalPIN(try XCTUnwrap(ParentalPIN.make(pin: "1234", iterations: 1)))
        let access = LiveTVSourceManagementAccess(profiles: profiles)
        access.unlock("1234")
        XCTAssertTrue(access.canManage)
        profiles.setParentalPIN(try XCTUnwrap(ParentalPIN.make(pin: "5678", iterations: 1)))
        XCTAssertFalse(access.canManage)
        access.unlock("5678")
        XCTAssertTrue(access.canManage)
    }

    func testAProfileSwitchCannotAuthorizeThePreviousProfilesEditor() {
        let (profiles, suite) = makeProfiles()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let access = LiveTVSourceManagementAccess(profiles: profiles)
        XCTAssertTrue(access.canManage)
        let other = profiles.add(name: "Another adult")
        profiles.select(other.id)
        XCTAssertFalse(access.canManage)
        XCTAssertTrue(LiveTVSourceManagementAccess(profiles: profiles).canManage)
    }

    private func makeProfiles() -> (ProfilesModel, String) {
        let suite = "LiveTVSourceAccessTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (ProfilesModel(store: ProfileStore(defaults: defaults)), suite)
    }
}
#endif
