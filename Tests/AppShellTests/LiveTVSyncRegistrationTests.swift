#if DEBUG && canImport(SwiftUI)
import AppRuntime
import CoreModels
import Foundation
import XCTest
@testable import AppShell

@MainActor
final class LiveTVSyncRegistrationTests: XCTestCase {
    func testUnavailableChannelPreservesBaselineInItsOwnVersionedZone() async {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("unused-live-tv-ledger.json")
        let channel = AppState.makeLiveTVSyncChannel(bridge: nil, stateFileURL: url)
        XCTAssertEqual(channel.schema.zoneName, "PlozzLiveTVStateV1Zone")
        XCTAssertEqual(channel.schema.recordType, "PlozzMediaStateV1Record")
        XCTAssertEqual(channel.stateFileURL, url)
        XCTAssertFalse(channel.isHydrated())
        let fallback = ["peer-record": Data("peer-value".utf8)]
        let captured = await channel.captureRecords(fallback)
        XCTAssertEqual(captured, fallback)
    }

    func testRegisteredChannelRoutesAccountResetToTheRetainedBridge() async throws {
        let suite = "LiveTVSyncRegistrationTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let profiles = ProfilesModel(store: ProfileStore(defaults: defaults))
        let preference = LiveTVPortableSyncPreferenceStore(
            defaults: defaults, profileID: profiles.activeProfileID, namespace: profiles.activeNamespace
        )
        preference.isEnabled = true
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("unused-live-tv-directory", isDirectory: true)
        let bridge = LiveTVPortableSyncBridge(profiles: profiles, directory: directory, defaults: defaults)
        let channel = AppState.makeLiveTVSyncChannel(
            bridge: bridge, stateFileURL: directory.appendingPathComponent("ledger.json")
        )
        XCTAssertTrue(channel.isHydrated())
        await channel.onAccountSwitch()
        XCTAssertFalse(preference.isEnabled)
        XCTAssertEqual(bridge.statuses[profiles.activeProfileID], .localOnly)
    }
}
#endif
