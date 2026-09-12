#if DEBUG && canImport(SwiftUI)
import FeatureLiveTVCore
import Foundation
import XCTest
@testable import FeatureLiveTV

@MainActor
final class PrototypeServerGuideRequestTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testFirstMiddleAndLastViewportsStayBounded() throws {
        let rows = rows(count: 100)
        let references = references(for: rows)
        for (anchor, expected) in [(0, 0..<12), (50, 47..<59), (99, 88..<100)] {
            let request = try XCTUnwrap(request(rows: rows, anchor: rows[anchor], references: references))
            XCTAssertEqual(request.channels.map(\.id), expected.map { "channel-\($0)" })
            XCTAssertLessThanOrEqual(request.channels.count, PrototypeServerGuideRequest.rowLimit)
        }
    }

    func testSmallCatalogDoesNotRequestOutsideItsRows() throws {
        let rows = rows(count: 3)
        let request = try XCTUnwrap(request(rows: rows, anchor: rows.last, references: references(for: rows)))
        XCTAssertEqual(request.channels.map(\.id), rows.map(\.channelID))
    }

    func testOnlyServerChannelsInTheNeighborhoodAreRequested() throws {
        let rows = rows(count: 100)
        let references = references(for: [rows[0], rows[50], rows[99]])
        let request = try XCTUnwrap(request(rows: rows, anchor: rows[50], references: references))
        XCTAssertEqual(request.channels.map(\.id), ["channel-50"])
        XCTAssertNil(self.request(rows: rows, anchor: rows[20], references: references))
        XCTAssertNil(self.request(rows: [], anchor: nil, references: references))
    }

    func testRepeatedFavoritesAndRecentRowsDoNotDuplicateRequests() throws {
        let rows = [
            LiveTVGuideRowID(channelID: "channel-0", section: .recent),
            LiveTVGuideRowID(channelID: "channel-0", section: .favorites),
            LiveTVGuideRowID(channelID: "channel-0"),
            LiveTVGuideRowID(channelID: "channel-1")
        ]
        let references = references(for: Array(rows.suffix(2)))
        let request = try XCTUnwrap(request(rows: rows, anchor: nil, references: references))
        XCTAssertEqual(request.channels.map(\.id), ["channel-0", "channel-1"])
    }

    func testRemovedSectionAnchorKeepsItsChannelNeighborhood() throws {
        let rows = rows(count: 100)
        let request = try XCTUnwrap(request(
            rows: rows,
            anchor: LiveTVGuideRowID(channelID: "channel-50", section: .favorites),
            references: references(for: rows)
        ))
        XCTAssertEqual(request.channels.first?.id, "channel-47")
        XCTAssertTrue(request.channels.contains { $0.id == "channel-50" })
    }

    func testAuthorizationAndTimeWindowChangesInvalidateTaskIdentity() throws {
        let rows = rows(count: 1)
        let first = try XCTUnwrap(request(rows: rows, references: references(for: rows)))
        let refreshed = try XCTUnwrap(request(
            rows: rows, references: references(for: rows, authorizationID: "refreshed")
        ))
        let later = try XCTUnwrap(PrototypeServerGuideRequest(
            rows: rows, anchor: nil, references: references(for: rows),
            from: start.addingTimeInterval(86_400), to: start.addingTimeInterval(108_000)
        ))
        XCTAssertNotEqual(first, refreshed)
        XCTAssertNotEqual(first, later)
        XCTAssertEqual(first, request(rows: rows, references: references(for: rows)))
        XCTAssertEqual(first.to.timeIntervalSince(first.from), 21_600)
    }

    private func rows(count: Int) -> [LiveTVGuideRowID] {
        (0..<count).map { LiveTVGuideRowID(channelID: "channel-\($0)") }
    }

    private func references(
        for rows: [LiveTVGuideRowID], authorizationID: String = "authorization"
    ) -> [String: LiveTVServerChannelReference] {
        Dictionary(uniqueKeysWithValues: rows.map { row in
            (row.channelID, LiveTVServerChannelReference(
                sourceID: "source", accountID: "account", authorizationID: authorizationID,
                channelID: row.channelID
            ))
        })
    }

    private func request(
        rows: [LiveTVGuideRowID], anchor: LiveTVGuideRowID? = nil,
        references: [String: LiveTVServerChannelReference]
    ) -> PrototypeServerGuideRequest? {
        PrototypeServerGuideRequest(
            rows: rows, anchor: anchor, references: references,
            from: start, to: start.addingTimeInterval(21_600)
        )
    }
}
#endif
