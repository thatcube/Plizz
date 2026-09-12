import CoreModels
import Foundation
import XCTest
@testable import CoreUI

@MainActor
final class LiveTVPortableSyncPresentationTests: XCTestCase {
    func testAvailabilityBelongsToAnActuallyRegisteredProfileModel() throws {
        let first = try profiles()
        let other = try profiles()
        let presentation = LiveTVPortableSyncPresentation()
        XCTAssertFalse(presentation.isAvailable(profiles: first))
        var runtimeExists = true
        presentation.connect(profiles: first, isAvailable: { runtimeExists }) { _ in "Waiting to sync." }
        XCTAssertTrue(presentation.isAvailable(profiles: first))
        XCTAssertFalse(presentation.isAvailable(profiles: other))
        runtimeExists = false
        XCTAssertFalse(presentation.isAvailable(profiles: first))
    }

    private func profiles() throws -> ProfilesModel {
        let suite = "LiveTVPortableSyncPresentationTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return ProfilesModel(store: ProfileStore(defaults: defaults))
    }
}
