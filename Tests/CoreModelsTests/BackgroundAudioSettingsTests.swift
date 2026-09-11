import XCTest
@testable import CoreModels

final class BackgroundAudioSettingsTests: XCTestCase {
    func testDefaultAndLegacyPayloadPauseOnLock() throws {
        XCTAssertFalse(PlaybackSettings.default.backgroundAudio)
        let legacy = Data(#"{"autoPlayNextEpisode":false}"#.utf8)
        let decoded = try JSONDecoder().decode(PlaybackSettings.self, from: legacy)
        XCTAssertFalse(decoded.backgroundAudio)
        XCTAssertFalse(decoded.autoPlayNextEpisode)
    }

    func testRoundTripPreservesBothChoices() throws {
        for enabled in [false, true] {
            let settings = PlaybackSettings(backgroundAudio: enabled)
            let data = try JSONEncoder().encode(settings)
            XCTAssertEqual(try JSONDecoder().decode(PlaybackSettings.self, from: data), settings)
        }
    }

    @MainActor
    func testBindingPersistsOnlyTheCurrentProfile() throws {
        let name = "BackgroundAudioSettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let guest = PlaybackSettingsStore(defaults: defaults, namespace: "guest")
        let primary = PlaybackSettingsStore(defaults: defaults)
        let model = PlaybackSettingsModel(store: guest)
        model.settings.backgroundAudio = true

        XCTAssertTrue(guest.load().backgroundAudio)
        XCTAssertFalse(primary.load().backgroundAudio)
        XCTAssertTrue(guest.load().autoPlayNextEpisode)
    }
}
