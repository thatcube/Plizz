import Foundation
import Observation
import XCTest
@testable import CoreModels

final class AppAdmissionPolicyTests: XCTestCase {
    func testFreshInstallRequiresAccountOrExplicitChoice() {
        XCTAssertFalse(AppAdmissionContext(hasMediaAccounts: false).canEnterApp)
        XCTAssertTrue(AppAdmissionContext(hasMediaAccounts: true).canEnterApp)
        XCTAssertTrue(AppAdmissionContext(
            hasMediaAccounts: false,
            explicitStandaloneChoice: true
        ).canEnterApp)
        XCTAssertTrue(AppAdmissionContext(
            hasMediaAccounts: true,
            explicitStandaloneChoice: true
        ).canEnterApp)
    }
}

final class AppAdmissionNavigationTests: XCTestCase {
    private let standalone = AppAdmissionContext(
        hasMediaAccounts: false,
        explicitStandaloneChoice: true
    )

    func testExplicitEntryTemporarilyExposesHiddenLiveTVWithoutEditingLayout() {
        let configured = ["settings"]
        let entry = AppAdmissionNavigation.destinations(
            configured, liveTV: "liveTV", includesExplicitEntry: true
        )
        XCTAssertEqual(entry, ["liveTV", "settings"])
        XCTAssertEqual(AppAdmissionNavigation.initialSelection(
            current: "settings", visible: entry, liveTV: "liveTV", fallback: "settings",
            admission: standalone, hasPendingLiveTVEntry: true
        ), "liveTV")
        XCTAssertEqual(configured, ["settings"])
        XCTAssertEqual(AppAdmissionNavigation.destinations(
            configured, liveTV: "liveTV", includesExplicitEntry: false
        ), ["settings"])
    }

    func testStandaloneRelaunchPrefersLiveTVOnlyWhenVisible() {
        XCTAssertEqual(AppAdmissionNavigation.initialSelection(
            current: "home", visible: ["home", "liveTV", "settings"],
            liveTV: "liveTV", fallback: "settings",
            admission: standalone, hasPendingLiveTVEntry: false
        ), "liveTV")
        XCTAssertEqual(AppAdmissionNavigation.initialSelection(
            current: "liveTV", visible: ["settings"],
            liveTV: "liveTV", fallback: "settings",
            admission: standalone, hasPendingLiveTVEntry: false
        ), "settings")
    }

    func testHiddenLiveTVDoesNotReplaceAnotherChosenVisibleDestination() {
        XCTAssertEqual(AppAdmissionNavigation.initialSelection(
            current: "search", visible: ["settings", "search"],
            liveTV: "liveTV", fallback: "settings",
            admission: standalone, hasPendingLiveTVEntry: false
        ), "search")
    }

    func testEmptyNavigationFallsBackToSettingsRatherThanHome() {
        XCTAssertEqual(AppAdmissionNavigation.initialSelection(
            current: "home", visible: [],
            liveTV: "liveTV", fallback: "settings",
            admission: standalone, hasPendingLiveTVEntry: false
        ), "settings")
    }

    func testMediaAccountsAndSilentIPTVSetupKeepExistingSelection() {
        let mixed = AppAdmissionContext(hasMediaAccounts: true, explicitStandaloneChoice: true)
        XCTAssertEqual(AppAdmissionNavigation.initialSelection(
            current: "settings", visible: ["home", "liveTV", "settings"],
            liveTV: "liveTV", fallback: "settings",
            admission: mixed, hasPendingLiveTVEntry: false
        ), "settings")
    }

    func testUnavailableStandaloneAdmissionDoesNotHonorAStaleIntent() {
        XCTAssertEqual(AppAdmissionNavigation.initialSelection(
            current: "home", visible: ["home", "settings"],
            liveTV: "liveTV", fallback: "settings",
            admission: AppAdmissionContext(hasMediaAccounts: true),
            hasPendingLiveTVEntry: true
        ), "home")
    }

    func testExplicitEntryDoesNotReorderAnAlreadyVisibleLiveTVTab() {
        let configured = ["search", "settings", "liveTV"]
        XCTAssertEqual(AppAdmissionNavigation.destinations(
            configured, liveTV: "liveTV", includesExplicitEntry: true
        ), configured)
    }

    #if DEBUG
    func testEveryTVNavigationVariantKeepsSettingsOnlyLayoutsOnRelaunch() {
        let variants = [
            NavigationDestinationDefaults.compact(hasMusic: false),
            NavigationDestinationDefaults.sidebar(visibleLibraries: [], hasMusic: false),
            NavigationDestinationDefaults.rail(visibleLibraries: [], hasMusic: false),
        ]
        for keys in variants {
            let layout = NavigationLibraryLayout(hiddenKeys: Set(keys))
            let destinations = NavigationRailPlan.destinations(
                visibleLibraries: [], layout: layout, availableKeys: keys
            )
            XCTAssertEqual(destinations, [.settings])
            XCTAssertEqual(AppAdmissionNavigation.initialSelection(
                current: NavigationRailDestination.home, visible: destinations,
                liveTV: .liveTV, fallback: .settings,
                admission: standalone, hasPendingLiveTVEntry: false
            ), .settings)
            let explicit = AppAdmissionNavigation.destinations(
                destinations, liveTV: .liveTV, includesExplicitEntry: true
            )
            XCTAssertEqual(explicit, [.liveTV, .settings])
            XCTAssertFalse(layout.isVisible(NavigationLibraryLayout.liveTVKey))
        }
    }

    func testIOSSettingsOnlyLayoutKeepsSettingsOnRelaunch() {
        let keys = NavigationDestinationDefaults.iOS
        let layout = NavigationLibraryLayout(hiddenKeys: Set(keys))
        let visible = layout.visibleKeys(available: keys)
        XCTAssertEqual(visible, [NavigationLibraryLayout.settingsKey])
        XCTAssertEqual(AppAdmissionNavigation.initialSelection(
            current: NavigationLibraryLayout.homeKey,
            visible: visible,
            liveTV: NavigationLibraryLayout.liveTVKey,
            fallback: NavigationLibraryLayout.settingsKey,
            admission: standalone,
            hasPendingLiveTVEntry: false
        ), NavigationLibraryLayout.settingsKey)
    }
    #endif
}

@MainActor
final class AppAdmissionStoreTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "AppAdmissionStoreTests.\(UUID().uuidString)"
        addTeardownBlock {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        return UserDefaults(suiteName: suite)!
    }

    func testMissingAndExplicitFalseRemainServerOnly() {
        let defaults = makeDefaults()
        let store = AppAdmissionStore(defaults: defaults)
        XCTAssertFalse(store.loadStandaloneChoice())
        defaults.set(false, forKey: AppAdmissionStore.standaloneChoiceKey)
        XCTAssertFalse(store.loadStandaloneChoice())
    }

    func testMalformedAndCoercibleFlagsNeverOptIn() {
        let defaults = makeDefaults()
        let store = AppAdmissionStore(defaults: defaults)
        let malformed: [Any] = [
            "true", "YES", "1", 1, 1.0, -1,
            ["enabled": true], [true], Data([1])
        ]
        for value in malformed {
            defaults.set(value, forKey: AppAdmissionStore.standaloneChoiceKey)
            XCTAssertFalse(store.loadStandaloneChoice(), "Must reject \(value)")
        }
    }

    func testChoicePersistsAcrossModelAndStoreRecreation() {
        let defaults = makeDefaults()
        let first = AppAdmissionModel(store: AppAdmissionStore(defaults: defaults))
        XCTAssertTrue(first.enterStandalonePlayback(isAvailable: true))

        let relaunched = AppAdmissionModel(store: AppAdmissionStore(defaults: defaults))
        XCTAssertTrue(relaunched.explicitStandaloneChoice)
        XCTAssertTrue(relaunched.context(
            hasMediaAccounts: false,
            standalonePlaybackAvailable: true
        ).canEnterApp)
        XCTAssertFalse(relaunched.pendingLiveTVEntry, "Relaunch is not a new choice")
    }

    func testUnavailableFeatureCannotPersistOrHonorStandaloneChoice() {
        let defaults = makeDefaults()
        let store = AppAdmissionStore(defaults: defaults)
        let model = AppAdmissionModel(store: store)
        XCTAssertFalse(model.enterStandalonePlayback(isAvailable: false))
        XCTAssertFalse(store.loadStandaloneChoice())
        XCTAssertFalse(model.pendingLiveTVEntry)

        XCTAssertTrue(model.enterStandalonePlayback(isAvailable: true))
        XCTAssertFalse(model.context(
            hasMediaAccounts: false,
            standalonePlaybackAvailable: false
        ).canEnterApp)
        XCTAssertTrue(model.context(
            hasMediaAccounts: true,
            standalonePlaybackAvailable: false
        ).canEnterApp)
    }

    func testSuccessfulSetupRecordsAdmissionWithoutRequestingNavigation() {
        let defaults = makeDefaults()
        let store = AppAdmissionStore(defaults: defaults)
        let model = AppAdmissionModel(store: store)
        XCTAssertTrue(model.recordStandaloneChoice(isAvailable: true))
        XCTAssertTrue(model.explicitStandaloneChoice)
        XCTAssertTrue(store.loadStandaloneChoice())
        XCTAssertFalse(model.pendingLiveTVEntry)
        XCTAssertFalse(model.consumeLiveTVEntryIntent())
        XCTAssertTrue(AppAdmissionModel(store: store).explicitStandaloneChoice)
    }

    func testRecordingSetupNeitherConsumesExistingIntentNorOverridesAvailability() {
        let model = AppAdmissionModel(store: AppAdmissionStore(defaults: makeDefaults()))
        XCTAssertFalse(model.recordStandaloneChoice(isAvailable: false))
        XCTAssertFalse(model.explicitStandaloneChoice)
        model.enterStandalonePlayback(isAvailable: true)
        XCTAssertTrue(model.recordStandaloneChoice(isAvailable: true))
        XCTAssertTrue(model.pendingLiveTVEntry)
    }

    func testNavigationIntentPrecedesAdmissionAndIsConsumedOnce() {
        let model = AppAdmissionModel(store: AppAdmissionStore(defaults: makeDefaults()))
        withObservationTracking {
            _ = model.explicitStandaloneChoice
        } onChange: {
            MainActor.assumeIsolated {
                XCTAssertTrue(model.pendingLiveTVEntry)
                XCTAssertFalse(model.explicitStandaloneChoice, "Admission has not published yet")
            }
        }
        XCTAssertTrue(model.enterStandalonePlayback(isAvailable: true))
        XCTAssertTrue(model.pendingLiveTVEntry)
        XCTAssertTrue(model.consumeLiveTVEntryIntent())
        XCTAssertFalse(model.consumeLiveTVEntryIntent())
        XCTAssertTrue(model.enterStandalonePlayback(isAvailable: true))
        XCTAssertFalse(model.pendingLiveTVEntry, "An existing choice must not steal navigation")
    }

    func testProfileSetupDoesNotImplicitlyAdmitAnEmptyInstall() {
        let defaults = makeDefaults()
        let profiles = ProfilesModel(store: ProfileStore(defaults: defaults))
        let model = AppAdmissionModel(store: AppAdmissionStore(defaults: defaults))
        XCTAssertEqual(profiles.activeProfile.name, "Me")
        profiles.markFirstRunProfileSetupComplete()
        XCTAssertFalse(model.context(
            hasMediaAccounts: false,
            standalonePlaybackAvailable: true
        ).canEnterApp)
    }

    func testExplicitDiagnosticResetRestoresFreshAdmissionAndNavigation() {
        let defaults = makeDefaults()
        let store = AppAdmissionStore(defaults: defaults)
        let model = AppAdmissionModel(store: store)
        model.enterStandalonePlayback(isAvailable: true)
        model.resetForDebugging()
        XCTAssertFalse(model.explicitStandaloneChoice)
        XCTAssertFalse(model.pendingLiveTVEntry)
        XCTAssertFalse(store.loadStandaloneChoice())
        XCTAssertTrue(model.enterStandalonePlayback(isAvailable: true))
        XCTAssertTrue(model.pendingLiveTVEntry)
    }

    func testStandaloneChoiceNeitherChangesProfilesNorFollowsTheirNamespace() throws {
        let defaults = makeDefaults()
        let profileStore = ProfileStore(defaults: defaults)
        let profiles = ProfilesModel(store: profileStore)
        var second = profiles.add(name: "Second")
        second.replaceLock(with: try XCTUnwrap(ProfileLock.make(pin: "1234", iterations: 64)))
        profiles.update(second)
        let originalProfiles = profiles.profiles
        let originalID = profiles.activeProfileID
        let originalRemembered = profiles.hasRememberedSelection
        let originalSetupComplete = profiles.firstRunProfileSetupComplete
        // Multiple profiles imply completed household setup without writing the
        // local first-run flag. Admission must preserve both distinct values.
        XCTAssertTrue(originalSetupComplete)
        XCTAssertFalse(profileStore.firstRunProfileSetupComplete())
        let model = AppAdmissionModel(store: AppAdmissionStore(defaults: defaults))

        XCTAssertTrue(model.enterStandalonePlayback(isAvailable: true))
        XCTAssertEqual(profiles.profiles, originalProfiles)
        XCTAssertEqual(profiles.activeProfileID, originalID)
        XCTAssertEqual(profiles.hasRememberedSelection, originalRemembered)
        XCTAssertEqual(profiles.firstRunProfileSetupComplete, originalSetupComplete)
        XCTAssertFalse(profileStore.firstRunProfileSetupComplete())

        profiles.select(second.id)
        XCTAssertEqual(profiles.activeNamespace, second.id)
        XCTAssertTrue(profiles.activeProfile.isLocked)
        XCTAssertTrue(model.context(
            hasMediaAccounts: false,
            standalonePlaybackAvailable: true
        ).canEnterApp)
        XCTAssertTrue(AppAdmissionStore(defaults: defaults).loadStandaloneChoice())
        XCTAssertNil(defaults.object(
            forKey: "\(AppAdmissionStore.standaloneChoiceKey).\(second.id)"
        ))
    }

    func testStandaloneEntryLeavesSingleProfileConfirmationIncomplete() {
        let defaults = makeDefaults()
        let profileStore = ProfileStore(defaults: defaults)
        let profiles = ProfilesModel(store: profileStore)
        let model = AppAdmissionModel(store: AppAdmissionStore(defaults: defaults))
        XCTAssertEqual(profiles.profiles.count, 1)
        XCTAssertFalse(profiles.firstRunProfileSetupComplete)

        XCTAssertTrue(model.enterStandalonePlayback(isAvailable: true))

        XCTAssertTrue(model.context(
            hasMediaAccounts: false,
            standalonePlaybackAvailable: true
        ).canEnterApp)
        XCTAssertFalse(profiles.firstRunProfileSetupComplete)
        XCTAssertFalse(profileStore.firstRunProfileSetupComplete())
        XCTAssertEqual(profiles.activeProfile.name, "Me")
    }
}
