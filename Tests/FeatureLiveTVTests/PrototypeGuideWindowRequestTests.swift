#if DEBUG && canImport(SwiftUI)
import FeatureLiveTVCore
import Foundation
import XCTest
@testable import FeatureLiveTV

@MainActor
final class PrototypeGuideWindowRequestTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testLargeCatalogOnlyRequestsTheCurrentNeighborhood() throws {
        let rows = (0..<5_000).map { LiveTVGuideRowID(channelID: "channel-\($0)") }
        for (anchor, expected) in [(0, 0..<48), (2_500, 2_497..<2_545), (4_999, 4_952..<5_000)] {
            let value = try XCTUnwrap(request(rows: rows, anchor: rows[anchor]))
            XCTAssertEqual(value.channelIDs, expected.map { "channel-\($0)" })
            XCTAssertEqual(value.range.duration, 21_600)
        }
    }

    func testRepeatedSectionsAndRemovedSectionAnchorRemainStable() throws {
        let rows = [
            LiveTVGuideRowID(channelID: "one", section: .recent),
            LiveTVGuideRowID(channelID: "one", section: .favorites),
            LiveTVGuideRowID(channelID: "one"),
            LiveTVGuideRowID(channelID: "two"),
        ]
        let value = try XCTUnwrap(
            request(
                rows: rows, anchor: LiveTVGuideRowID(channelID: "two", section: .favorites)
            ))
        XCTAssertEqual(value.channelIDs, ["one", "two"])
    }

    func testDisabledSourcesEmptyRowsAndInvalidTimesDoNotRequestData() {
        let rows = [LiveTVGuideRowID(channelID: "one")]
        XCTAssertNil(request(rows: []))
        XCTAssertNil(request(rows: rows, enabledSourceIDs: []))
        XCTAssertNil(request(rows: rows, end: start))
        XCTAssertNil(request(rows: rows, end: start.addingTimeInterval(-1)))
    }

    func testTimeAndRelevantMappingChangesInvalidateRequest() throws {
        let rows = [LiveTVGuideRowID(channelID: "one")]
        let first = try XCTUnwrap(request(rows: rows))
        let mapping = LiveTVGuideMappingOverride(guideSourceID: "guide", guideChannelID: "schedule")
        XCTAssertNotEqual(first, request(rows: rows, end: start.addingTimeInterval(43_200)))
        XCTAssertNotEqual(first, request(rows: rows, mappings: ["one": mapping]))
        XCTAssertEqual(first, request(rows: rows, mappings: ["outside-viewport": mapping]))
        XCTAssertEqual(first, request(rows: rows))
    }

    private func request(
        rows: [LiveTVGuideRowID], anchor: LiveTVGuideRowID? = nil,
        enabledSourceIDs: Set<String> = ["guide"], end: Date? = nil,
        mappings: [String: LiveTVGuideMappingOverride] = [:]
    ) -> PrototypeGuideWindowRequest? {
        let imports = LiveTVPrototypeImportModel(
            playlistURL: URL(string: "https://example.invalid/channels.m3u")!,
            guideURL: URL(string: "https://example.invalid/guide.xml")!
        )
        return PrototypeGuideWindowRequest(
            rows: rows, anchor: anchor, from: start, to: end ?? start.addingTimeInterval(21_600),
            sources: imports.guideSources, enabledSourceIDs: enabledSourceIDs, mappings: mappings
        )
    }
}
#endif
