#if os(iOS)
import AVFoundation
import XCTest
@testable import FeaturePlayback

@MainActor
final class LiveChannelExternalPlaybackPolicyTests: XCTestCase {
    func testDisallowedPaneRejectsActualExternalPlaybackAndLaterAdapterOptIn() {
        let player = AVPlayer()
        let policy = LiveChannelExternalPlaybackPolicy(isAllowed: false)
        defer { policy.bind(nil) }
        policy.bind(player)
        XCTAssertFalse(player.allowsExternalPlayback)
        XCTAssertFalse(player.usesExternalPlaybackWhileExternalScreenIsActive)
        player.allowsExternalPlayback = true
        player.usesExternalPlaybackWhileExternalScreenIsActive = true
        XCTAssertFalse(player.allowsExternalPlayback)
        XCTAssertFalse(player.usesExternalPlaybackWhileExternalScreenIsActive)
    }

    func testReplacementPlayerInheritsRestrictionAndExplicitSinglePaneCanRestoreIt() {
        let first = AVPlayer()
        let second = AVPlayer()
        let policy = LiveChannelExternalPlaybackPolicy(isAllowed: false)
        defer { policy.bind(nil) }
        policy.bind(first)
        policy.bind(second)
        XCTAssertFalse(second.allowsExternalPlayback)
        policy.isAllowed = true
        XCTAssertTrue(second.allowsExternalPlayback)
        XCTAssertTrue(second.usesExternalPlaybackWhileExternalScreenIsActive)
        XCTAssertFalse(first.allowsExternalPlayback)
    }

    func testDetachingPolicyDoesNotMutateOtherPlayersOrKeepObservingTheOldOne() {
        let player = AVPlayer()
        let other = AVPlayer()
        other.allowsExternalPlayback = false
        let policy = LiveChannelExternalPlaybackPolicy(isAllowed: false)
        policy.bind(player)
        policy.bind(nil)
        player.allowsExternalPlayback = true
        XCTAssertTrue(player.allowsExternalPlayback)
        XCTAssertFalse(other.allowsExternalPlayback)
    }
}
#endif
