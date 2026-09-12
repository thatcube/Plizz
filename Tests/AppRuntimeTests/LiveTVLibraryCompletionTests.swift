#if DEBUG && canImport(AVFoundation)
import CoreModels
import XCTest
@testable import AppRuntime

@MainActor
final class LiveTVLibraryCompletionTests: XCTestCase {
    func testRawProviderItemUsesScheduledAccountForCanonicalCompletion() throws {
        let item = MediaItem(id: "episode", title: "Episode", kind: .episode, runtime: 1_800)
        let completed = try LiveTVLibraryRuntime.completedItem(item, scheduled: schedule(item))
        XCTAssertEqual(completed.sourceAccountID, "scheduled-account")
        XCTAssertEqual(completed.id, item.id)
        XCTAssertEqual(completed.kind, item.kind)
    }

    func testMatchingProviderAccountIsPreserved() throws {
        var item = MediaItem(id: "episode", title: "Episode", kind: .episode, runtime: 1_800)
        item.sourceAccountID = "scheduled-account"
        XCTAssertEqual(
            try LiveTVLibraryRuntime.completedItem(item, scheduled: schedule(item)).sourceAccountID,
            item.sourceAccountID
        )
    }

    func testDifferentAccountOrProgrammeCannotCompleteScheduledItem() throws {
        let item = MediaItem(id: "episode", title: "Episode", kind: .episode, runtime: 1_800)
        let scheduled = try schedule(item)
        var foreignItem = item
        foreignItem.sourceAccountID = "another-account"
        let differentID = MediaItem(id: "another-episode", title: "Episode", kind: .episode, runtime: 1_800)
        let differentKind = MediaItem(id: "episode", title: "Movie", kind: .movie, runtime: 1_800)
        for candidate in [foreignItem, differentID, differentKind] {
            XCTAssertThrowsError(try LiveTVLibraryRuntime.completedItem(candidate, scheduled: scheduled)) {
                XCTAssertEqual($0 as? LibraryChannelError, .mediaChanged)
            }
        }
    }

    private func schedule(_ item: MediaItem) throws -> LibraryChannelItem {
        try LibraryChannelItem(
            item: item,
            library: LibraryChannelLibrary(accountID: "scheduled-account", libraryID: "shows"),
            serverID: "server",
            userID: "user"
        )
    }
}
#endif
