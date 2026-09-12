import CoreModels
import XCTest
@testable import AppRuntime

@MainActor
final class WatchlistActionFastPathTests: XCTestCase {
    func testRepeatedBookmarkPresentationDoesNoUnrelatedWork() {
        var identityQueries = 0
        var providerQueries = 0
        var capabilityQueries = 0
        var downloadQueries = 0
        var membershipQueries = 0
        var membership = false
        var revision: UInt64 = 1
        let coordinator = MediaItemActionCoordinator(
            providerResolver: { _ in providerQueries += 1; return nil },
            providerCapabilityResolver: { _ in capabilityQueries += 1; return (true, true, true) },
            additionalSources: { _ in identityQueries += 1; return [] },
            primaryAccountID: { "a" },
            crossServerWatchSyncEnabled: { false },
            enqueueWatchMutation: { _ in },
            universalWatchlistEnabled: { true },
            watchlistMembership: { _ in membershipQueries += 1; return membership },
            watchlistMembershipRevision: { revision },
            downloadState: { _ in downloadQueries += 1; return .some(nil) }
        )
        let item = MediaItem(
            id: "movie", title: "Movie", kind: .movie,
            locallyValidatedPlayableSource: true, sourceAccountID: "a"
        )
        for _ in 0..<100 {
            XCTAssertEqual(coordinator.watchlistAction(for: item, context: .none), .addToWatchlist)
        }
        XCTAssertEqual(identityQueries, 0)
        XCTAssertEqual(providerQueries, 0)
        XCTAssertEqual(capabilityQueries, 0)
        XCTAssertEqual(downloadQueries, 0)
        XCTAssertEqual(membershipQueries, 1)

        membership = true
        revision += 1
        XCTAssertEqual(coordinator.watchlistAction(for: item, context: .none), .removeFromWatchlist)
        XCTAssertEqual(membershipQueries, 2)

        // The complete menu still prepares its other actions when requested.
        XCTAssertTrue(coordinator.actions(for: item, context: .none).contains(.removeFromWatchlist))
        XCTAssertEqual(identityQueries, 1)
        XCTAssertEqual(downloadQueries, 1)
    }

    func testBookmarkMatchesFullMenuAcrossEligibilityAndFeatureModes() {
        let kinds: [MediaItemKind] = [.movie, .series, .episode, .season, .video, .folder, .collection, .unknown]
        for universal in [false, true] {
            for supportsWatchlist in [false, true] {
                for member in [false, true] {
                    for favorite in [false, true] {
                        let coordinator = MediaItemActionCoordinator(
                            providerResolver: { _ in nil },
                            providerCapabilityResolver: { _ in (true, supportsWatchlist, true) },
                            primaryAccountID: { "a" },
                            crossServerWatchSyncEnabled: { false },
                            enqueueWatchMutation: { _ in },
                            universalWatchlistEnabled: { universal },
                            watchlistMembership: { _ in member }
                        )
                        for discovery in [false, true] {
                            for kind in kinds {
                                let item = MediaItem(
                                    id: discovery ? "seer:1" : "owned:1",
                                    title: "Title", kind: kind,
                                    availability: discovery ? .unknown : nil,
                                    locallyValidatedPlayableSource: !discovery,
                                    sourceAccountID: discovery ? nil : "a",
                                    isFavorite: favorite
                                )
                                let expected = coordinator.actions(for: item, context: .none)
                                    .first { $0 == .addToWatchlist || $0 == .removeFromWatchlist }
                                XCTAssertEqual(
                                    coordinator.watchlistAction(for: item, context: .none), expected,
                                    "\(kind) universal=\(universal) provider=\(supportsWatchlist) discovery=\(discovery)"
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    func testDefaultHandlerRetainsExistingMenuSemantics() {
        let handler = MenuOnlyHandler()
        let item = MediaItem(id: "movie", title: "Movie", kind: .movie)
        let context = MediaItemActionContext(orderedSiblings: [item])
        let abstract: any MediaItemActionHandling = handler
        XCTAssertEqual(abstract.watchlistAction(for: item, context: context), .removeFromWatchlist)
        XCTAssertEqual(handler.lastContext, context)
    }
}

@MainActor
private final class MenuOnlyHandler: MediaItemActionHandling {
    var lastContext: MediaItemActionContext?

    func actions(for item: MediaItem, context: MediaItemActionContext) -> [MediaItemAction] {
        lastContext = context
        return [.markWatched, .removeFromWatchlist]
    }

    func perform(_ action: MediaItemAction, on item: MediaItem, context: MediaItemActionContext) {}
}
