#if DEBUG && canImport(SwiftUI)
import CoreModels
import FeatureLiveTVCore
import Foundation
import XCTest
@testable import FeatureLiveTV

final class PrototypeLibraryGuideRequestTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testWindowIsBoundedAndExcludesNetworkChannels() throws {
        let channels = (0..<100).map { channel("library-\($0)") }
        let rows = (0..<5_000).map { index in
            LiveTVGuideRowID(channelID: index < 100 ? "library-\(index)" : "network-\(index)")
        }
        let catalog = PrototypeLibraryCatalogRevision(
            channels: channels, generation: UUID(), revisionIDs: [UUID()], isLoaded: true
        )
        let request = try XCTUnwrap(PrototypeLibraryGuideRequest(
            catalog: catalog, rows: rows, anchor: rows[90],
            from: start, to: start.addingTimeInterval(21_600)
        ))
        XCTAssertEqual(request.channelIDs, Set((87..<100).map { "library-\($0)" }))
        XCTAssertEqual(request.range.duration, 21_600)
        XCTAssertNil(PrototypeLibraryGuideRequest(
            catalog: catalog, rows: rows, anchor: rows[1_000],
            from: start, to: start.addingTimeInterval(21_600)
        ))
    }

    func testUnavailableCatalogAndInvalidRangeDoNotPublish() {
        let catalog = PrototypeLibraryCatalogRevision(
            channels: [channel("one")], generation: UUID(), revisionIDs: [], isLoaded: false
        )
        XCTAssertNil(PrototypeLibraryGuideRequest(
            catalog: catalog, rows: [LiveTVGuideRowID(channelID: "one")], anchor: nil,
            from: start, to: start.addingTimeInterval(3_600)
        ))
        XCTAssertNil(PrototypeLibraryGuideRequest(
            catalog: catalog, rows: [], anchor: nil, from: start, to: start
        ))
    }

    func testPublishedRevisionAndAuthorizationInvalidateCatalogIdentity() {
        let generation = UUID()
        let revision = UUID()
        let first = PrototypeLibraryCatalogRevision(
            channels: [channel("one")], generation: generation, revisionIDs: [revision], isLoaded: true
        )
        XCTAssertEqual(first, PrototypeLibraryCatalogRevision(
            channels: [channel("one")], generation: generation, revisionIDs: [revision], isLoaded: true
        ))
        XCTAssertNotEqual(first, PrototypeLibraryCatalogRevision(
            channels: [channel("one")], generation: UUID(), revisionIDs: [revision], isLoaded: true
        ))
        XCTAssertNotEqual(first, PrototypeLibraryCatalogRevision(
            channels: [channel("one")], generation: generation, revisionIDs: [UUID()], isLoaded: true
        ))
    }

    private func channel(_ id: String) -> LiveTVPrototypeChannel {
        LiveTVPrototypeChannel(
            id: id, number: 1, name: id, category: "Plozz", symbol: "tv",
            accent: 0, source: .plozz, tagline: ""
        )
    }
}
#endif
