import Foundation
import XCTest
@testable import CoreModels

@MainActor
final class LiveTVPlaybackIdentityHoldTests: XCTestCase {
    func testUnstartedOwnerDoesNotBlockCatalogChanges() {
        let profile = UUID().uuidString
        let owner = LiveTVPlaybackIdentityHold(profileID: profile)
        XCTAssertFalse(LiveTVPlaybackIdentityHold.isHeld(profileID: profile))
        owner.update(false)
        XCTAssertFalse(LiveTVPlaybackIdentityHold.isHeld(profileID: profile))
    }

    func testHoldsAreProfileScopedAndRequireEveryOwnerToFinish() {
        let profile = UUID().uuidString
        let first = LiveTVPlaybackIdentityHold(profileID: profile)
        let second = LiveTVPlaybackIdentityHold(profileID: profile)
        first.update(true)
        second.update(true)
        XCTAssertTrue(LiveTVPlaybackIdentityHold.isHeld(profileID: profile))
        XCTAssertFalse(LiveTVPlaybackIdentityHold.isHeld(profileID: UUID().uuidString))
        first.update(false)
        XCTAssertTrue(LiveTVPlaybackIdentityHold.isHeld(profileID: profile))
        second.update(false)
        XCTAssertFalse(LiveTVPlaybackIdentityHold.isHeld(profileID: profile))
    }

    func testRegistryDoesNotRetainAnAbandonedPlayerOwner() async {
        let profile = UUID().uuidString
        var owner: LiveTVPlaybackIdentityHold? = LiveTVPlaybackIdentityHold(profileID: profile)
        weak var reference = owner
        owner?.update(true)
        XCTAssertTrue(LiveTVPlaybackIdentityHold.isHeld(profileID: profile))
        owner = nil
        XCTAssertNil(reference)
        XCTAssertFalse(LiveTVPlaybackIdentityHold.isHeld(profileID: profile))
        await Task.yield()
    }
}
