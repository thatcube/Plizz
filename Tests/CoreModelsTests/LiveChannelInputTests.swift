import XCTest
@testable import CoreModels

final class LiveChannelInputTests: XCTestCase {
    func testLibraryInputChangesWhenAuthorizationChanges() {
        let id = UUID()
        let original = LiveChannelInput.libraryChannel(id: id, authorizationID: "first-generation")
        XCTAssertEqual(original, .libraryChannel(id: id, authorizationID: "first-generation"))
        XCTAssertNotEqual(original, .libraryChannel(id: id, authorizationID: "second-generation"))
    }

    func testLibraryInputDescriptionsDoNotExposeAuthorization() {
        let id = UUID()
        let authorization = "private-authorization-marker"
        let input = LiveChannelInput.libraryChannel(id: id, authorizationID: authorization)
        XCTAssertTrue(input.description.contains(id.uuidString))
        XCTAssertFalse(input.description.contains(authorization))
        XCTAssertFalse(input.debugDescription.contains(authorization))
    }
}
