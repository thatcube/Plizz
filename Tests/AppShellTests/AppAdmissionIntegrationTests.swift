import CoreModels
import FeatureAuth
import Foundation
import XCTest
@testable import AppShell

@MainActor
final class AppAdmissionIntegrationTests: XCTestCase {
    private struct Harness {
        let state: AppState
        let accounts: AccountStore
        let profiles: ProfilesModel
        let defaults: UserDefaults
    }

    private func makeHarness(
        standalone: Bool = false,
        profileSetupComplete: Bool = false,
        withAccount: Bool = false
    ) throws -> Harness {
        let suite = "AppAdmissionIntegrationTests.\(UUID().uuidString)"
        addTeardownBlock {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        let defaults = UserDefaults(suiteName: suite)!
        let accounts = AccountStore(secureStore: InMemorySecureStore())
        if withAccount {
            try accounts.add(Account(
                id: "media-account",
                server: MediaServer(
                    id: "server",
                    name: "Server",
                    baseURL: URL(string: "https://server.example")!,
                    provider: .jellyfin
                ),
                userID: "viewer",
                userName: "Viewer",
                deviceID: "device"
            ), token: "test-token")
        }
        let profiles = ProfilesModel(store: ProfileStore(defaults: defaults))
        if profileSetupComplete { profiles.markFirstRunProfileSetupComplete() }
        let admission = AppAdmissionStore(defaults: defaults)
        if standalone { admission.recordStandaloneChoice() }
        let state = AppState(
            accountStore: accounts,
            registry: ProviderRegistry(),
            profilesModel: profiles,
            appAdmissionStore: admission
        )
        return Harness(state: state, accounts: accounts, profiles: profiles, defaults: defaults)
    }

    func testFreshZeroAccountInstallStillOnboards() throws {
        let harness = try makeHarness()
        harness.state.bootstrap()
        XCTAssertFalse(harness.state.canEnterApp)
        XCTAssertFalse(harness.state.pendingStandaloneLiveTVEntry)
        XCTAssertEqual(harness.state.state, .onboarding(.selectingServer, canReturnToApp: false))
        XCTAssertEqual(harness.profiles.activeProfile.name, "Me")
    }

    func testNormalLastAccountSignOutStillOnboards() throws {
        let harness = try makeHarness(profileSetupComplete: true, withAccount: true)
        harness.state.bootstrap()
        XCTAssertEqual(harness.state.state, .ready)
        harness.state.removeAccount(id: "media-account")
        XCTAssertFalse(harness.state.canEnterApp)
        XCTAssertEqual(harness.state.state, .onboarding(.selectingServer, canReturnToApp: false))
    }

    #if DEBUG
    func testSuccessfulIPTVSetupKeepsSessionAndProfileThenSurvivesFinalLogout() throws {
        let harness = try makeHarness(profileSetupComplete: true, withAccount: true)
        harness.state.bootstrap()
        let profile = harness.profiles.activeProfile
        let rememberedSelection = harness.profiles.hasRememberedSelection
        XCTAssertTrue(harness.state.recordSuccessfulIPTVSetup())
        XCTAssertEqual(harness.state.state, .ready)
        XCTAssertEqual(harness.profiles.activeProfile, profile)
        XCTAssertEqual(harness.profiles.hasRememberedSelection, rememberedSelection)
        XCTAssertFalse(harness.state.pendingStandaloneLiveTVEntry)
        XCTAssertTrue(harness.profiles.firstRunProfileSetupComplete)

        harness.state.removeAccount(id: "media-account")

        XCTAssertEqual(harness.state.state, .ready)
        XCTAssertTrue(harness.state.canEnterApp)
        XCTAssertFalse(harness.state.pendingStandaloneLiveTVEntry)
        XCTAssertTrue(AppAdmissionStore(defaults: harness.defaults).loadStandaloneChoice())
    }

    func testInterruptedStandaloneProfileSetupPreservesLaunchLockGate() throws {
        let harness = try makeHarness(standalone: true)
        var profile = harness.profiles.activeProfile
        profile.replaceLock(with: try XCTUnwrap(ProfileLock.make(pin: "1234", iterations: 64)))
        harness.profiles.update(profile)
        harness.state.bootstrap()
        XCTAssertEqual(harness.state.state, .onboarding(.confirmProfile, canReturnToApp: true))
        XCTAssertTrue(harness.state.profileFlow.isChoosingProfile)
        XCTAssertTrue(harness.state.profileFlow.activeProfileAwaitsUnlock)
        harness.state.profileFlow.switchProfile(to: profile.id)
        XCTAssertEqual(harness.state.profileFlow.pendingLockedProfile?.id, profile.id)
        XCTAssertFalse(harness.profiles.firstRunProfileSetupComplete)
    }

    func testStandaloneEntryUsesExistingProfileAndSkipsServerOnlySteps() throws {
        let harness = try makeHarness()
        harness.state.bootstrap()
        let existingProfile = harness.profiles.activeProfile

        XCTAssertTrue(harness.state.enterStandalonePlayback())
        XCTAssertTrue(harness.state.canEnterApp)
        XCTAssertTrue(harness.state.pendingStandaloneLiveTVEntry)
        XCTAssertTrue(harness.state.accountsProviders.accounts.isEmpty)
        XCTAssertEqual(harness.profiles.activeProfile, existingProfile)
        XCTAssertFalse(harness.profiles.firstRunProfileSetupComplete)
        XCTAssertEqual(harness.state.state, .onboarding(.confirmProfile, canReturnToApp: true))

        harness.state.confirmFirstRunProfile()
        XCTAssertEqual(harness.state.state, .onboarding(.selectTheme, canReturnToApp: true))
        harness.state.finishThemeSelection()
        XCTAssertEqual(harness.state.state, .onboarding(.selectNavigation, canReturnToApp: true))
        harness.state.finishNavigationSelection()
        XCTAssertEqual(harness.state.state, .ready)
        XCTAssertTrue(harness.state.pendingStandaloneLiveTVEntry)
        XCTAssertTrue(harness.state.consumeStandaloneLiveTVEntryIntent())
        XCTAssertFalse(harness.state.consumeStandaloneLiveTVEntryIntent())
    }

    func testStoredStandaloneChoiceRestoresWithoutAccounts() throws {
        let harness = try makeHarness(standalone: true, profileSetupComplete: true)
        harness.state.bootstrap()
        XCTAssertEqual(harness.state.state, .ready)
        XCTAssertTrue(harness.state.canEnterApp)
        XCTAssertTrue(harness.state.accountsProviders.homeAccounts.isEmpty)
        XCTAssertFalse(harness.state.pendingStandaloneLiveTVEntry)
    }

    func testUnfinishedStandaloneConfirmationResumesOnLaunch() throws {
        let harness = try makeHarness(standalone: true)
        harness.state.bootstrap()
        XCTAssertEqual(harness.state.state, .onboarding(.confirmProfile, canReturnToApp: true))
        XCTAssertFalse(harness.profiles.firstRunProfileSetupComplete)
    }

    func testLastAccountRemovalRetainsStandaloneAdmission() throws {
        let harness = try makeHarness(
            standalone: true,
            profileSetupComplete: true,
            withAccount: true
        )
        harness.state.bootstrap()
        harness.state.removeAccount(id: "media-account")
        XCTAssertTrue(harness.state.accountsProviders.accounts.isEmpty)
        XCTAssertTrue(harness.state.canEnterApp)
        XCTAssertEqual(harness.state.state, .ready)
        XCTAssertTrue(AppAdmissionStore(defaults: harness.defaults).loadStandaloneChoice())
    }

    func testSignOutAllRetainsStandaloneAdmission() throws {
        let harness = try makeHarness(
            standalone: true,
            profileSetupComplete: true,
            withAccount: true
        )
        harness.state.bootstrap()
        harness.state.signOutAll()
        XCTAssertTrue(harness.state.accountsProviders.accounts.isEmpty)
        XCTAssertEqual(harness.state.state, .ready)
        XCTAssertTrue(harness.state.allowsStandalonePlayback)
    }

    func testStandaloneProfileSwitchKeepsAdmissionAndLockGate() throws {
        let harness = try makeHarness(standalone: true, profileSetupComplete: true)
        var locked = harness.profiles.add(name: "Locked")
        locked.replaceLock(with: try XCTUnwrap(ProfileLock.make(pin: "1234", iterations: 64)))
        harness.profiles.update(locked)
        let firstID = harness.profiles.activeProfileID
        harness.state.bootstrap()
        harness.state.profileFlow.switchProfile(to: locked.id)
        XCTAssertEqual(harness.state.profileFlow.pendingLockedProfile?.id, locked.id)
        XCTAssertEqual(harness.profiles.activeProfileID, firstID)
        XCTAssertEqual(harness.state.state, .ready)
        XCTAssertTrue(harness.state.canEnterApp)
        XCTAssertTrue(harness.state.profileFlow.isChoosingProfile)
        XCTAssertTrue(harness.state.profileFlow.submitProfileLockPIN("1234"))
        XCTAssertEqual(harness.profiles.activeProfileID, locked.id)
        XCTAssertEqual(harness.state.state, .ready)
        XCTAssertTrue(harness.state.canEnterApp)
        XCTAssertTrue(AppAdmissionStore(defaults: harness.defaults).loadStandaloneChoice())
    }

    func testStandaloneAdmissionDoesNotUnlockParentalSwitch() throws {
        let harness = try makeHarness(standalone: true, profileSetupComplete: true)
        let adult = harness.profiles.activeProfile
        let child = harness.profiles.add(name: "Child", isKidsProfile: true)
        harness.profiles.setParentalPIN(
            try XCTUnwrap(ParentalPIN.make(pin: "2468", iterations: 64))
        )
        harness.profiles.select(child.id)
        harness.state.bootstrap()

        harness.state.profileFlow.switchProfile(to: adult.id)

        XCTAssertEqual(harness.state.profileFlow.pendingParentalSwitch?.id, adult.id)
        XCTAssertEqual(harness.profiles.activeProfileID, child.id)
        XCTAssertTrue(harness.profiles.enforcesKidsRestrictions)
        XCTAssertTrue(harness.state.canEnterApp)
        harness.state.profileFlow.cancelParentalSwitch()
        XCTAssertEqual(harness.profiles.activeProfileID, child.id)
        XCTAssertEqual(harness.state.state, .ready)
    }

    func testStandaloneLockedProfileStillRequiresSelectionAtLaunch() throws {
        let harness = try makeHarness(standalone: true, profileSetupComplete: true)
        var profile = harness.profiles.activeProfile
        profile.replaceLock(with: try XCTUnwrap(ProfileLock.make(pin: "1234", iterations: 64)))
        harness.profiles.update(profile)
        harness.state.bootstrap()
        XCTAssertEqual(harness.state.state, .ready)
        XCTAssertTrue(harness.state.profileFlow.isChoosingProfile)
        XCTAssertFalse(harness.state.profileFlow.isProfileSelectionCancelable)
    }

    func testDiagnosticFirstRunResetClearsStandaloneChoice() throws {
        let harness = try makeHarness(standalone: true, profileSetupComplete: true)
        harness.state.bootstrap()
        harness.state.resetToFirstRunForDebugging()
        XCTAssertFalse(harness.state.canEnterApp)
        XCTAssertFalse(harness.state.allowsStandalonePlayback)
        XCTAssertFalse(harness.state.pendingStandaloneLiveTVEntry)
        XCTAssertEqual(harness.state.state, .onboarding(.selectingServer, canReturnToApp: false))
    }
    #else
    func testReleaseBuildDoesNotAdmitStoredStandaloneChoice() throws {
        let harness = try makeHarness(standalone: true, profileSetupComplete: true)
        harness.state.bootstrap()
        XCTAssertFalse(harness.state.enterStandalonePlayback())
        XCTAssertFalse(harness.state.recordSuccessfulIPTVSetup())
        XCTAssertFalse(harness.state.canEnterApp)
        XCTAssertEqual(harness.state.state, .onboarding(.selectingServer, canReturnToApp: false))
    }
    #endif
}
