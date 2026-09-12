#if DEBUG
import Foundation
import XCTest
@testable import FeatureLiveTVCore

@MainActor
final class LiveTVProgramSearchTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_767_225_600)

    func testGeneratedSearchLoadsRequestedRangeRatherThanPublishedWindow() async throws {
        let imports = LiveTVPrototypeImportModel(loader: ProgramSearchNoNetworkLoader())
        let model = LiveTVPrototypeModel(now: now, channels: [])
        let channels = [channel("library", source: .plozz), channel("hidden", source: .plozz)]
        try imports.setGeneratedCatalog(
            channels: channels,
            programs: [program("cached", channelID: "library", title: "Stale Needle")], into: model
        )
        model.setScanHiddenChannelIDs(["hidden"])
        let requestedRange = DateInterval(start: now.addingTimeInterval(2 * 86_400), duration: 3_600)
        let expected = program("future", channelID: "library", title: "Future Needle", offset: 2 * 86_400)
        var calls = 0
        imports.generatedProgramLoader = { ids, range in
            calls += 1
            XCTAssertEqual(ids, ["library"])
            XCTAssertEqual(range, requestedRange)
            return [expected]
        }
        let found = try await imports.searchPrograms(
            query: "Needle", range: requestedRange, allowedChannelIDs: Set(channels.map(\.id)), catalog: model
        )
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(found, [expected])
        XCTAssertEqual(model.currentProgram(for: "library")?.title, "Stale Needle",
                       "Searching must not replace the visible guide window.")
    }

    func testGeneratedLoaderFailureIsNotReportedAsAnEmptySuccessfulSearch() async throws {
        let imports = LiveTVPrototypeImportModel(loader: ProgramSearchNoNetworkLoader())
        let model = LiveTVPrototypeModel(now: now, channels: [])
        try imports.setGeneratedCatalog(channels: [channel("library", source: .plozz)], programs: [], into: model)
        imports.generatedProgramLoader = { _, _ in throw LiveTVCacheError.unavailable }
        do {
            _ = try await imports.searchPrograms(
                query: "Needle", range: .init(start: now, duration: 3_600), catalog: model
            )
            XCTFail("Schedule errors must surface to the search UI.")
        } catch {
            XCTAssertEqual(error as? LiveTVCacheError, .unavailable)
        }
    }

    func testExplicitSearchIDsCannotReintroduceManuallyOrScanHiddenChannels() async throws {
        let channels = [channel("manual", source: .plex), channel("scan", source: .plozz), channel("shown", source: .emby)]
        let model = LiveTVPrototypeModel(now: now, channels: channels)
        try model.replacePrograms(channels.map { program($0.id, channelID: $0.id, title: "Needle") })
        XCTAssertTrue(model.hideChannel(channels[0]))
        model.setScanHiddenChannelIDs(["scan"])
        let imports = LiveTVPrototypeImportModel(loader: ProgramSearchNoNetworkLoader())
        let results = try await imports.searchPrograms(
            query: "Needle", range: .init(start: now, duration: 3_600),
            allowedChannelIDs: Set(channels.map(\.id)), catalog: model
        )
        XCTAssertEqual(results.map(\.channelID), ["shown"])
    }

    func testPublishedCachedServerAndLibraryProgrammesAreSearchableWithoutIPTVOrNetworking() async throws {
        let kinds: [LiveTVPrototypeSource] = [.jellyfin, .plex, .emby, .plozz, .iptv]
        let channels = kinds.map { channel($0.rawValue, source: $0) }
        let model = LiveTVPrototypeModel(now: now, channels: channels)
        try model.replacePrograms(channels.map { program($0.id, channelID: $0.id, title: "Morning Report") })
        let loader = ProgramSearchNoNetworkLoader()
        let imports = LiveTVPrototypeImportModel(loader: loader)
        let found = try await imports.searchPrograms(
            query: "mor rep", range: .init(start: now, duration: 3_600),
            allowedChannelIDs: model.programmeSearchChannelIDs, catalog: model
        )
        XCTAssertEqual(Set(found.map(\.channelID)), ["jellyfin", "plex", "emby", "plozz"])
        let requests = await loader.requests
        XCTAssertEqual(requests, 0)
    }

    func testNativeAllowedIDsAreAppliedBeforeTheResultLimit() async throws {
        let model = LiveTVPrototypeModel(now: now, channels: [
            channel("denied", source: .plex), channel("allowed", source: .plozz)
        ])
        let early = (0..<600).map {
            program("early-\($0)", channelID: "denied", title: "Needle", offset: Double($0))
        }
        try model.replacePrograms(early + [program("wanted", channelID: "allowed", title: "Needle", offset: 1_000)])
        let imports = LiveTVPrototypeImportModel(loader: ProgramSearchNoNetworkLoader())
        let found = try await imports.searchPrograms(
            query: "Needle", range: .init(start: now, duration: 7_200), limit: 1,
            allowedChannelIDs: ["allowed"], catalog: model
        )
        XCTAssertEqual(found.map(\.id), ["wanted"])
    }

    func testGeneratedSchedulePublicationAdvancesSearchRevisionAndReplacesTitles() async throws {
        let imports = LiveTVPrototypeImportModel(loader: ProgramSearchNoNetworkLoader())
        let model = LiveTVPrototypeModel(now: now, channels: [])
        let channel = channel("library", source: .plozz)
        let initial = program("slot", channelID: channel.id, title: "Old title")
        try imports.setGeneratedCatalog(channels: [channel], programs: [initial], into: model)
        let revision = imports.catalogRevision
        let modelRevision = model.catalogRevision
        let first = try await imports.searchPrograms(
            query: "Old", range: .init(start: now, duration: 3_600), catalog: model
        )
        XCTAssertEqual(first.map(\.id), ["slot"], "Published/native duplicates must be coalesced.")
        try imports.setGeneratedCatalog(
            channels: [channel], programs: [program("slot", channelID: channel.id, title: "Replacement")], into: model
        )
        XCTAssertGreaterThan(imports.catalogRevision, revision)
        XCTAssertGreaterThan(model.catalogRevision, modelRevision)
        let obsolete = try await imports.searchPrograms(
            query: "Old", range: .init(start: now, duration: 3_600), catalog: model
        )
        let current = try await imports.searchPrograms(
            query: "Replacement", range: .init(start: now, duration: 3_600), catalog: model
        )
        XCTAssertTrue(obsolete.isEmpty)
        XCTAssertEqual(current.map(\.title), ["Replacement"])
    }

    func testUnchangedProgrammePublicationDoesNotAdvanceModelRevision() throws {
        let model = LiveTVPrototypeModel(now: now, channels: [channel("native", source: .emby)])
        let programs = [program("slot", channelID: "native", title: "Title")]
        try model.replacePrograms(programs)
        let revision = model.catalogRevision
        try model.replacePrograms(programs)
        XCTAssertEqual(model.catalogRevision, revision)
    }

    func testBoundedMergeKeepsEarliestDistinctResultsInStableOrder() {
        let programs = (0..<1_000).map {
            program("slot-\($0)", channelID: "native", title: "Title", offset: Double($0 % 37))
        }
        var result = LiveTVProgramSearchResults(limit: 17)
        for program in programs.reversed() { result.insert(program); result.insert(program) }
        let expected = programs.sorted { ($0.start, $0.id) < ($1.start, $1.id) }.prefix(17)
        XCTAssertEqual(result.sorted, Array(expected))
        var empty = LiveTVProgramSearchResults(limit: 0)
        empty.insert(programs[0])
        XCTAssertTrue(empty.sorted.isEmpty)
    }

    func testSearchMatcherUsesBoundedCaseInsensitiveWordPrefixes() {
        XCTAssertTrue(LiveTVProgramSearchMatcher("morn réport").matches("MORNING regional report"))
        XCTAssertFalse(LiveTVProgramSearchMatcher("missing").matches("Morning report"))
        XCTAssertFalse(LiveTVProgramSearchMatcher(" ... ").matches("Anything"))
        XCTAssertEqual(LiveTVProgramSearchMatcher(String(repeating: "word ", count: 1_000)).tokens.count, 12)
    }

    private func channel(_ id: String, source: LiveTVPrototypeSource) -> LiveTVPrototypeChannel {
        .init(id: id, number: 1, name: id, category: "Test", symbol: "tv", accent: 0, source: source, tagline: "Test")
    }

    private func program(
        _ id: String, channelID: String, title: String, offset: TimeInterval = 0
    ) -> LiveTVPrototypeProgram {
        .init(
            id: id, channelID: channelID, title: title, subtitle: "",
            start: now.addingTimeInterval(offset), end: now.addingTimeInterval(offset + 3_600)
        )
    }
}

private actor ProgramSearchNoNetworkLoader: LiveTVSourceLoading {
    private(set) var requests = 0
    func loadPlaylist(from url: URL) async throws -> LiveTVPlaylistImport {
        requests += 1
        throw LiveTVSourceImportError.downloadFailed
    }
    func loadGuide(from url: URL, channels: [LiveTVPrototypeChannel], now: Date) async throws -> LiveTVGuideImport {
        requests += 1
        throw LiveTVSourceImportError.downloadFailed
    }
}
#endif
