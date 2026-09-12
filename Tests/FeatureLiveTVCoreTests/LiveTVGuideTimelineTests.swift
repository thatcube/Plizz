import Foundation
import XCTest
@testable import FeatureLiveTVCore

final class LiveTVGuideTimelineTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func program(_ id: String, _ from: TimeInterval, _ to: TimeInterval) -> LiveTVPrototypeProgram {
        LiveTVPrototypeProgram(
            id: id, channelID: "channel", title: id, subtitle: "",
            start: start.addingTimeInterval(from), end: start.addingTimeInterval(to)
        )
    }

    func testNoGuideProducesOneHonestGap() {
        let end = start.addingTimeInterval(7_200)
        let slots = LiveTVGuideTimeline.slots(programs: [], from: start, to: end)
        XCTAssertEqual(slots.count, 1)
        XCTAssertNil(slots[0].program)
        XCTAssertEqual(slots[0].start, start)
        XCTAssertEqual(slots[0].end, end)
    }

    func testLeadingMiddleAndTrailingGapsKeepProgramsOnTheirClock() {
        let slots = LiveTVGuideTimeline.slots(
            programs: [program("later", 4_000, 6_000), program("first", 600, 2_400)],
            from: start, to: start.addingTimeInterval(7_200)
        )
        XCTAssertEqual(slots.map { $0.program?.id }, [nil, "first", nil, "later", nil])
        XCTAssertEqual(slots.map { $0.start.timeIntervalSince(start) }, [0, 600, 2_400, 4_000, 6_000])
        XCTAssertEqual(slots.map { $0.end.timeIntervalSince(start) }, [600, 2_400, 4_000, 6_000, 7_200])
        XCTAssertEqual(Set(slots.map(\.id)).count, slots.count)
    }

    func testOverlapsAndWindowEdgesDoNotOverrunTheGrid() {
        let slots = LiveTVGuideTimeline.slots(
            programs: [
                program("first", -600, 1_800), program("overlap", 1_200, 3_600),
                program("covered", 1_300, 1_500), program("last", 3_600, 8_000)
            ],
            from: start, to: start.addingTimeInterval(7_200)
        )
        XCTAssertEqual(slots.map { $0.program?.id }, ["first", "overlap", "last"])
        XCTAssertEqual(slots.map { $0.end.timeIntervalSince($0.start) }.reduce(0, +), 7_200)
        XCTAssertEqual(slots[1].start, slots[0].end)
        XCTAssertEqual(slots[2].start, slots[1].end)
    }

    func testShortLeadingSliceKeepsTheOriginalProgramTimes() throws {
        let original = program("already-started", -1_080, 660)
        let slots = LiveTVGuideTimeline.slots(
            programs: [original, program("next", 660, 2_400)],
            from: start, to: start.addingTimeInterval(7_200)
        )
        let leading = try XCTUnwrap(slots.first)
        XCTAssertEqual(leading.start, start)
        XCTAssertEqual(leading.end.timeIntervalSince(leading.start), 660)
        XCTAssertEqual(leading.program, original)
        XCTAssertEqual(slots[1].start, original.end)
        XCTAssertEqual(slots.map { $0.end.timeIntervalSince($0.start) }.reduce(0, +), 7_200)
    }
}
