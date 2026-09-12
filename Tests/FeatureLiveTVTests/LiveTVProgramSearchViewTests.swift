#if DEBUG
import FeatureLiveTVCore
import Foundation
import XCTest
@testable import FeatureLiveTV

@MainActor
final class LiveTVProgramSearchViewTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_767_225_600)

    func testChannelNameQueryDoesNotRestrictProgrammeScope() throws {
        let (model, imports, _) = try fixture()
        let before = view(model, imports).searchRequest
        model.query = "No channel has this name"
        XCTAssertTrue(model.visibleChannels.isEmpty)
        XCTAssertEqual(view(model, imports).searchRequest.channelIDs, before.channelIDs)
    }

    func testHidingAndFavoriteFiltersInvalidateResultsAndRenderRejectsStaleScope() throws {
        let (model, imports, program) = try fixture()
        let request = view(model, imports).searchRequest
        XCTAssertEqual(
            request.filtering([program], completedRequest: request, model: model, imports: imports), [program]
        )
        model.favoritesOnly = true
        XCTAssertNotEqual(view(model, imports).searchRequest, request)
        XCTAssertTrue(request.filtering(
            [program], completedRequest: request, model: model, imports: imports
        ).isEmpty)
        model.toggleFavorite(program.channelID)
        let favoriteRequest = view(model, imports).searchRequest
        XCTAssertEqual(favoriteRequest.channelIDs, [program.channelID])
        XCTAssertTrue(model.hideChannel(try XCTUnwrap(model.channel(id: program.channelID))))
        XCTAssertNotEqual(view(model, imports).searchRequest, favoriteRequest)
        XCTAssertTrue(favoriteRequest.filtering(
            [program], completedRequest: favoriteRequest, model: model, imports: imports
        ).isEmpty)
    }

    func testProgrammePublicationInvalidatesSameQueryAndChannelIDs() throws {
        let (model, imports, program) = try fixture()
        let previous = view(model, imports).searchRequest
        try model.replacePrograms([.init(
            id: program.id, channelID: program.channelID, title: "Replacement", subtitle: "",
            start: program.start, end: program.end
        )])
        let current = view(model, imports).searchRequest
        XCTAssertEqual(current.query, previous.query)
        XCTAssertEqual(current.channelIDs, previous.channelIDs)
        XCTAssertNotEqual(current, previous)
        XCTAssertTrue(current.filtering(
            [program], completedRequest: previous, model: model, imports: imports
        ).isEmpty)
    }

    func testEnabledGuideChangesInvalidateNativeResultsWithoutRemovingTheirChannel() throws {
        let (model, _, program) = try fixture()
        let imports = LiveTVPrototypeImportModel(
            playlistURL: try XCTUnwrap(URL(string: "https://example.test/list.m3u")),
            guideURL: try XCTUnwrap(URL(string: "https://example.test/guide.xml")),
            loader: ProgramSearchViewLoader()
        )
        let channel = try XCTUnwrap(model.channel(id: program.channelID))
        try imports.setGeneratedCatalog(channels: [channel], programs: [program], into: model)
        let before = view(model, imports).searchRequest
        try imports.setSourceEnabled("guide", enabled: false, into: model)
        let after = view(model, imports).searchRequest
        XCTAssertEqual(before.channelIDs, after.channelIDs)
        XCTAssertNotEqual(before.enabledGuideIDs, after.enabledGuideIDs)
        XCTAssertNotEqual(before, after)
        XCTAssertTrue(after.filtering(
            [program], completedRequest: before, model: model, imports: imports
        ).isEmpty)
    }

    func testScanExclusionsAndSourceFilterChangeTheSearchScope() throws {
        let (model, imports, program) = try fixture()
        let normal = view(model, imports).searchRequest
        let excluded = LiveTVProgramSearchView(
            imports: imports, model: model, query: "Report", watch: { _ in },
            showDetails: { _ in }, excludedChannelIDs: [program.channelID]
        ).searchRequest
        XCTAssertNotEqual(normal, excluded)
        XCTAssertTrue(excluded.channelIDs.isEmpty)
        model.source = .iptv
        XCTAssertTrue(view(model, imports).searchRequest.channelIDs.isEmpty)
    }

    func testEndedProgrammesAreRemovedAtRenderBeforeTheNextSearchCompletes() throws {
        let (model, imports, program) = try fixture()
        let request = view(model, imports).searchRequest
        model.synchronizeClock(to: program.end)
        XCTAssertTrue(request.filtering(
            [program], completedRequest: request, model: model, imports: imports
        ).isEmpty)
    }

    func testAnotherProfileModelCannotReuseResultsEvenWithIdenticalIDsAndRevisions() throws {
        let (firstModel, firstImports, program) = try fixture()
        let (secondModel, secondImports, _) = try fixture()
        let first = view(firstModel, firstImports).searchRequest
        let second = view(secondModel, secondImports).searchRequest
        XCTAssertEqual(first.channelIDs, second.channelIDs)
        XCTAssertEqual(first.catalogRevision, second.catalogRevision)
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(first.filtering(
            [program], completedRequest: first, model: secondModel, imports: secondImports
        ).isEmpty)
    }

    private func fixture() throws -> (LiveTVPrototypeModel, LiveTVPrototypeImportModel, LiveTVPrototypeProgram) {
        let channel = LiveTVPrototypeChannel(
            id: "library", number: 1, name: "Library", category: "Test", symbol: "tv",
            accent: 0, source: .plozz, tagline: "Test"
        )
        let program = LiveTVPrototypeProgram(
            id: "programme", channelID: channel.id, title: "Evening Report", subtitle: "",
            start: now, end: now.addingTimeInterval(3_600)
        )
        let model = LiveTVPrototypeModel(now: now, channels: [channel])
        try model.replacePrograms([program])
        return (model, LiveTVPrototypeImportModel(loader: ProgramSearchViewLoader()), program)
    }

    private func view(_ model: LiveTVPrototypeModel, _ imports: LiveTVPrototypeImportModel) -> LiveTVProgramSearchView {
        LiveTVProgramSearchView(imports: imports, model: model, query: "Report", watch: { _ in }, showDetails: { _ in })
    }
}

private struct ProgramSearchViewLoader: LiveTVSourceLoading {
    func loadPlaylist(from url: URL) async throws -> LiveTVPlaylistImport { throw LiveTVSourceImportError.downloadFailed }
    func loadGuide(from url: URL, channels: [LiveTVPrototypeChannel], now: Date) async throws -> LiveTVGuideImport {
        throw LiveTVSourceImportError.downloadFailed
    }
}
#endif
