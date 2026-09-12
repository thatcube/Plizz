import XCTest
import CoreModels

final class ServerLiveTVProviderTests: XCTestCase {
    func testChannelsDoNotImplyPlaybackSupport() {
        let plex = ServerLiveTVAvailability(status: .unsupportedPlaybackMode, channelCount: 4)
        XCTAssertTrue(plex.hasChannels)
        XCTAssertTrue(plex.supportsGuide)
        XCTAssertFalse(plex.supportsPlayback)
        XCTAssertFalse(ServerLiveTVAvailability(status: .available).supportsPlayback)
        XCTAssertTrue(ServerLiveTVAvailability(status: .available, channelCount: 1).supportsPlayback)
        XCTAssertEqual(ServerLiveTVAvailability(status: .noChannels, channelCount: -2).channelCount, 0)
    }

    func testLivePlaybackPositionsAreSafeForServerTickEncoding() {
        for value in [Double.nan, .infinity, -.infinity, -1] {
            XCTAssertEqual(LiveTVPlaybackUpdate(state: .playing, positionSeconds: value).positionSeconds, 0)
        }
        XCTAssertEqual(
            LiveTVPlaybackUpdate(state: .paused, positionSeconds: .greatestFiniteMagnitude).positionSeconds,
            31_536_000
        )
        XCTAssertEqual(LiveTVPlaybackUpdate(state: .started, positionSeconds: 12.5).positionSeconds, 12.5)
    }
}
