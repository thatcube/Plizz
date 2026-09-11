import CoreModels
import Foundation
import Observation
import XCTest
@testable import FeatureLiveTVCore

private extension LiveTVPrototypeImportModel {
    convenience init(sources: [LiveTVGuideSource], loader: any LiveTVSourceLoading) {
        self.init(
            playlistURL: URL(string: "https://iptv-org.github.io/iptv/countries/us.m3u")!,
            sources: sources, loader: loader
        )
    }
}

@MainActor
final class LiveTVPrototypeImportModelTests: XCTestCase {
    func testSuppliedGuideIDsRemainConfiguredAcrossPlaylistDiscovery() async {
        let sources = testSources()
        let loader = ImportLoaderStub(channels: [LiveTVPrototypeCatalog.channels[0]])
        let imports = LiveTVPrototypeImportModel(sources: sources, loader: loader)
        XCTAssertEqual(imports.configuration.playlists.first?.guideSourceIDs, sources.map(\.id))
        await imports.reload(into: LiveTVPrototypeModel(channels: []))
        XCTAssertEqual(imports.guideSources.map(\.id), sources.map(\.id))
        XCTAssertEqual(imports.enabledSourceIDs, Set(sources.map(\.id)))
        let loads = await loader.guideLoads
        XCTAssertEqual(loads, sources.count)
    }

    func testGuideImportUsesTheCatalogClockForRetentionAndWindowQueries() async {
        let now = Date(timeIntervalSince1970: 1_767_225_600)
        let channel = LiveTVPrototypeCatalog.channels[0]
        let program = LiveTVPrototypeProgram(
            id: "clock-program", channelID: channel.id, title: "Clock schedule", subtitle: "",
            start: now.addingTimeInterval(-60), end: now.addingTimeInterval(3_600)
        )
        let loader = ImportLoaderStub(channels: [channel], programs: [program])
        let imports = LiveTVPrototypeImportModel(sources: [.us2], loader: loader)
        let model = LiveTVPrototypeModel(now: now, channels: [])
        await imports.reload(into: model)
        let guideDate = await loader.submittedGuideDate
        XCTAssertEqual(guideDate, now)
        XCTAssertEqual(model.currentProgram(for: channel.id), program)
    }

    func testCatalogHooksRunSynchronouslyBeforeRefreshAndPublication() async throws {
        let channels = Array(LiveTVPrototypeCatalog.channels.prefix(2))
        let imports = LiveTVPrototypeImportModel(sources: [.us2], loader: ImportLoaderStub(channels: channels))
        let model = LiveTVPrototypeModel(channels: [])
        var events: [String] = []
        imports.beforeSourceRefresh = { ids in
            XCTAssertEqual(ids, ["prototype"])
            events.append("refresh")
        }
        imports.beforeCatalogPublication = { [weak imports] configuration, proposed in
            if events == ["refresh"] { XCTAssertTrue(model.channels.isEmpty) }
            XCTAssertEqual(configuration, imports?.configuration)
            events.append("publish")
            model.setScanHiddenChannelIDs(Set(proposed.prefix(1).map(\.id)))
        }
        await imports.reload(into: model)
        XCTAssertEqual(events.first, "refresh")
        XCTAssertEqual(model.channels, channels)
        XCTAssertEqual(model.visibleChannels.map(\.id), [channels[1].id])
        try imports.applyConfiguration(.empty, into: model)
        XCTAssertEqual(events.suffix(2), ["refresh", "publish"])
        XCTAssertTrue(model.channels.isEmpty)
        XCTAssertTrue(model.scanHiddenChannelIDs.isEmpty)
    }

    func testAuthorizationLossCallsRetirementHookAndCannotResurrectGeneratedData() async throws {
        var authorized = true
        let imports = LiveTVPrototypeImportModel(catalogIsAuthorized: { authorized })
        let model = LiveTVPrototypeModel(channels: [])
        let generated = LiveTVPrototypeChannel(
            id: "generated", number: 1, name: "Generated", category: "Test", symbol: "tv",
            accent: 0, source: .plozz, tagline: ""
        )
        try imports.setGeneratedCatalog(channels: [generated], programs: [], into: model)
        model.setScanHiddenChannelIDs([generated.id])
        var cleared = false
        imports.beforeCatalogPublication = { configuration, channels in
            XCTAssertEqual(configuration, .empty)
            XCTAssertTrue(channels.isEmpty)
            cleared = true
        }
        authorized = false
        await imports.restoreCachedCatalog(into: model)
        XCTAssertTrue(cleared)
        XCTAssertTrue(model.channels.isEmpty)
        XCTAssertTrue(model.scanHiddenChannelIDs.isEmpty)
        XCTAssertTrue(imports.configuredSourceIDByChannel.isEmpty)
        authorized = true
        try imports.applyConfiguration(.empty, into: model)
        XCTAssertTrue(model.channels.isEmpty)
    }

    func testGuideCoverageFacetPreservesPublicObservation() async {
        let changed = expectation(description: "Coverage count remains observable")
        let imports = LiveTVPrototypeImportModel(
            sources: [.us2], loader: ImportLoaderStub(
                channels: [LiveTVPrototypeCatalog.channels[0]],
                programs: [.init(
                    id: "program", channelID: LiveTVPrototypeCatalog.channels[0].id, title: "Title",
                    subtitle: "", start: Date(), end: Date().addingTimeInterval(3_600)
                )]
            )
        )
        withObservationTracking {
            _ = imports.programCount
        } onChange: {
            changed.fulfill()
        }
        await imports.reload(into: LiveTVPrototypeModel(channels: []))
        await fulfillment(of: [changed], timeout: 1)
    }

    func testChannelsPublishBeforeGuideAndGuideFailureDoesNotRemoveThem() async {
        let model = LiveTVPrototypeModel(channels: [])
        let channels = LiveTVPrototypeCatalog.channels
        let loader = ImportLoaderStub(channels: channels, guideFails: true) { @MainActor in
            XCTAssertEqual(model.channels, channels)
        }
        let imports = LiveTVPrototypeImportModel(sources: [.us2], loader: loader)
        await imports.reload(into: model)
        XCTAssertEqual(imports.playlistPhase, .loaded)
        XCTAssertEqual(imports.guidePhase, .failed)
        XCTAssertFalse(imports.isLoading)
        XCTAssertEqual(imports.entryCount, channels.count)
        XCTAssertEqual(model.channels, channels)
        XCTAssertTrue(model.channels.allSatisfy { model.currentProgram(for: $0.id) == nil })
    }

    func testSuccessfulGuideImportUsesActualProgramsAndReportsCoverage() async {
        let channels = LiveTVPrototypeCatalog.channels
        let now = Date()
        let program = LiveTVPrototypeProgram(
            id: "real-program", channelID: channels[0].id, title: "Actual schedule",
            subtitle: "", start: now.addingTimeInterval(-60), end: now.addingTimeInterval(3_600)
        )
        let loader = ImportLoaderStub(channels: channels, programs: [program])
        let model = LiveTVPrototypeModel(now: now, channels: [])
        let imports = LiveTVPrototypeImportModel(sources: [.us2], loader: loader)
        await imports.reload(into: model)
        XCTAssertEqual(imports.guidePhase, .loaded)
        XCTAssertEqual(imports.matchedChannelCount, 1)
        XCTAssertEqual(imports.programCount, 1)
        XCTAssertEqual(imports.coverageStart, program.start)
        XCTAssertEqual(imports.coverageEnd, program.end)
        XCTAssertEqual(model.currentProgram(for: channels[0].id), program)
        XCTAssertNotNil(imports.lastGuideRefresh)
    }

    func testPlaylistFailurePreservesExistingChannelsAndDoesNotAttemptGuide() async {
        let channels = LiveTVPrototypeCatalog.channels
        let loader = ImportLoaderStub(channels: channels, playlistFails: true)
        let model = LiveTVPrototypeModel(channels: channels)
        model.toggleFavorite(channels[0].id)
        let imports = LiveTVPrototypeImportModel(sources: [.us2], loader: loader)
        await imports.reload(into: model)
        XCTAssertEqual(imports.playlistPhase, .failed)
        XCTAssertEqual(model.channels, channels)
        XCTAssertTrue(model.favoriteIDs.contains(channels[0].id))
        XCTAssertFalse(imports.isLoading)
        let guideLoads = await loader.guideLoads
        XCTAssertEqual(guideLoads, 0)
    }

    func testStressCopiesAreNotSubmittedAsAdditionalGuideMatches() async {
        let channels = LiveTVPrototypeCatalog.channels
        let loader = ImportLoaderStub(channels: channels)
        let model = LiveTVPrototypeModel(isLargeCatalog: true, channels: [])
        let imports = LiveTVPrototypeImportModel(sources: [.us2], loader: loader)
        await imports.reload(into: model)
        XCTAssertEqual(model.channels.count, 5_000)
        let submittedChannels = await loader.submittedChannelCount
        XCTAssertEqual(submittedChannels, channels.count)
    }

    func testLateOrCancelledRefreshCannotOverwriteANewerImport() async {
        for cancelFirst in [false, true] {
            let started = expectation(description: "First playlist is suspended")
            let old = LiveTVPrototypeCatalog.channels[0]
            let fresh = LiveTVPrototypeCatalog.channels[1]
            let loader = OverlappingImportLoader(old: old, fresh: fresh, started: started)
            let model = LiveTVPrototypeModel(channels: [])
            let imports = LiveTVPrototypeImportModel(sources: [.us2], loader: loader)
            let first = Task { await imports.reload(into: model) }
            await fulfillment(of: [started], timeout: 2)
            if cancelFirst { first.cancel() }
            await imports.reload(into: model)
            await loader.finishFirst()
            await first.value
            XCTAssertEqual(model.channels, [fresh])
            XCTAssertEqual(imports.playlistPhase, .loaded)
            XCTAssertEqual(imports.guidePhase, .loaded)
            XCTAssertFalse(imports.isLoading)
        }
    }

    func testMultipleFeedsPublishIncrementallyAndKeepOneAuthoritativeSchedule() async {
        let channels = Array(LiveTVPrototypeCatalog.channels.prefix(2))
        let now = Date()
        let first = guide(channelID: channels[0].id, title: "Primary", method: .nativeID, now: now)
        let other = guide(channelID: channels[0].id, title: "Other provider", method: .displayName, now: now)
        let model = LiveTVPrototypeModel(now: now, channels: [])
        let sources = testSources()
        let loader = MultiGuideLoader(
            channels: channels, guides: [sources[0].url: first, sources[1].url: other],
            failures: [sources[2].url]
        ) { url in
            if url == sources[1].url {
                await MainActor.run {
                    XCTAssertEqual(model.currentProgram(for: channels[0].id)?.title, "Primary")
                }
            }
        }
        let imports = LiveTVPrototypeImportModel(sources: sources, loader: loader)
        await imports.reload(into: model)
        XCTAssertEqual(imports.guidePhase, .loaded)
        XCTAssertEqual(imports.failedSourceCount, 1)
        XCTAssertEqual(imports.completedSourceCount, 3)
        XCTAssertEqual(imports.programCount, 1)
        XCTAssertEqual(imports.matchedChannelCount, 1)
        XCTAssertEqual(imports.selectedSourceByChannel[channels[0].id], sources[0].id)
        XCTAssertEqual(model.currentProgram(for: channels[0].id)?.title, "Primary")
        XCTAssertEqual(imports.gapState(for: channels[0]), .noListings)
    }

    func testExplicitSourcePriorityWinsAndDisablingRemovesItsContributionImmediately() async throws {
        let channel = LiveTVPrototypeCatalog.channels[0]
        let now = Date()
        let sources = Array(testSources().prefix(2))
        let lower = guide(channelID: channel.id, title: "Name match", method: .displayName, now: now)
        let higher = guide(channelID: channel.id, title: "Native match", method: .nativeID, now: now)
        let loader = MultiGuideLoader(channels: [channel], guides: [sources[0].url: lower, sources[1].url: higher])
        let imports = LiveTVPrototypeImportModel(sources: sources, loader: loader)
        let model = LiveTVPrototypeModel(now: now, channels: [])
        await imports.reload(into: model)
        XCTAssertEqual(model.currentProgram(for: channel.id)?.title, "Name match")
        await loader.setFailure(sources[1].url)
        await imports.reload(into: model)
        XCTAssertEqual(model.currentProgram(for: channel.id)?.title, "Name match")
        XCTAssertEqual(imports.failedSourceCount, 1)
        XCTAssertNotNil(imports.guideSources[1].lastRefresh)
        try imports.setSourceEnabled(sources[1].id, enabled: false, into: model)
        XCTAssertEqual(model.currentProgram(for: channel.id)?.title, "Name match")
        try imports.setSourceEnabled(sources[0].id, enabled: false, into: model)
        XCTAssertNil(model.currentProgram(for: channel.id))
        XCTAssertEqual(imports.programCount, 0)
        XCTAssertEqual(imports.gapState(for: channel), .disabled)
        XCTAssertFalse(imports.isLoading)
    }

    func testEqualConfidenceUsesSourceOrderButEmptyScheduleCanFallBack() async {
        let channel = LiveTVPrototypeCatalog.channels[0]
        let now = Date()
        let sources = Array(testSources().prefix(2))
        let first = guide(channelID: channel.id, title: "First", method: .providerName, now: now)
        let second = guide(channelID: channel.id, title: "Second", method: .providerName, now: now)
        for firstHasPrograms in [true, false] {
            let empty = LiveTVGuideImport(
                programs: [], matchedChannelCount: 1, guideChannelCount: 1,
                programCount: 0, coverageStart: nil, coverageEnd: nil, matches: first.matches
            )
            let loader = MultiGuideLoader(
                channels: [channel], guides: [sources[0].url: firstHasPrograms ? first : empty, sources[1].url: second]
            )
            let imports = LiveTVPrototypeImportModel(sources: sources, loader: loader)
            let model = LiveTVPrototypeModel(now: now, channels: [])
            await imports.reload(into: model)
            XCTAssertEqual(model.currentProgram(for: channel.id)?.title, firstHasPrograms ? "First" : "Second")
            XCTAssertEqual(imports.programCount, 1)
        }
    }

    func testGuideLoadingAndUnmatchedAndEmptyListingStatesAreDistinct() async {
        let channels = Array(LiveTVPrototypeCatalog.channels.prefix(2))
        let source = LiveTVGuideSource.us2
        let empty = LiveTVGuideImport(
            programs: [], matchedChannelCount: 1, guideChannelCount: 1,
            programCount: 0, coverageStart: nil, coverageEnd: nil,
            matches: [channels[0].id: LiveTVGuideMatch(guideChannelID: "station", method: .exactID)]
        )
        let loader = MultiGuideLoader(channels: channels, guides: [source.url: empty])
        let imports = LiveTVPrototypeImportModel(sources: [source], loader: loader)
        let model = LiveTVPrototypeModel(channels: [])
        XCTAssertEqual(imports.gapState(for: channels[0]), .loading)
        await imports.reload(into: model)
        XCTAssertEqual(imports.gapState(for: channels[0]), .noListings)
        XCTAssertEqual(imports.gapState(for: channels[1]), .unmatched)
        await loader.setFailure(source.url)
        await imports.reload(into: model)
        XCTAssertEqual(imports.gapState(for: channels[0]), .noListings)
        XCTAssertEqual(imports.gapState(for: channels[1]), .failed)
        XCTAssertEqual(model.channels.count, 2)
    }

    func testSourceSelectionFencesLateGuideResults() async throws {
        let channel = LiveTVPrototypeCatalog.channels[0]
        let now = Date()
        let started = expectation(description: "Guide suspended")
        let source = LiveTVGuideSource.us2
        let loader = SuspendedGuideLoader(
            channel: channel, guide: guide(channelID: channel.id, title: "Late", method: .nativeID, now: now),
            started: started
        )
        let imports = LiveTVPrototypeImportModel(sources: [source], loader: loader)
        let model = LiveTVPrototypeModel(now: now, channels: [])
        let task = Task { await imports.reload(into: model) }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(imports.gapState(for: channel), .loading)
        try imports.setSourceEnabled(source.id, enabled: false, into: model)
        await loader.finish()
        await task.value
        XCTAssertEqual(imports.gapState(for: channel), .disabled)
        XCTAssertEqual(imports.programCount, 0)
        XCTAssertNil(model.currentProgram(for: channel.id))
        XCTAssertFalse(imports.isLoading)
    }

    func testCancelledGuideDoesNotPublishOrPretendItFailedToParse() async {
        let channel = LiveTVPrototypeCatalog.channels[0]
        let started = expectation(description: "Guide suspended")
        let loader = SuspendedGuideLoader(
            channel: channel,
            guide: guide(channelID: channel.id, title: "Cancelled", method: .nativeID, now: Date()),
            started: started
        )
        let imports = LiveTVPrototypeImportModel(sources: [.us2], loader: loader)
        let model = LiveTVPrototypeModel(channels: [])
        let task = Task { await imports.reload(into: model) }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        await loader.finish()
        await task.value
        XCTAssertFalse(imports.isLoading)
        XCTAssertEqual(imports.guidePhase, .idle)
        XCTAssertEqual(imports.failedSourceCount, 0)
        XCTAssertNil(imports.guideFailure)
        XCTAssertEqual(imports.programCount, 0)
        XCTAssertEqual(model.channels, [channel])
    }

    func testFailureOfUnrelatedProviderDoesNotLabelUnmatchedBroadcastGuideAsFailed() async throws {
        let channel = try XCTUnwrap(LiveTVPlaylistParser().parse("""
            #EXTM3U
            #EXTINF:-1 tvg-id="Example.us",Example
            https://example.com/live.m3u8
            """).channels.first)
        let pluto = try XCTUnwrap(LiveTVGuideSource.recognizedSources.first { $0.provider == .pluto })
        let empty = LiveTVGuideImport(
            programs: [], matchedChannelCount: 0, guideChannelCount: 0,
            programCount: 0, coverageStart: nil, coverageEnd: nil
        )
        let loader = MultiGuideLoader(
            channels: [channel], guides: [LiveTVGuideSource.us2.url: empty], failures: [pluto.url]
        )
        let imports = LiveTVPrototypeImportModel(sources: [pluto, .us2], loader: loader)
        let model = LiveTVPrototypeModel(channels: [])
        await imports.reload(into: model)
        XCTAssertEqual(imports.failedSourceCount, 1)
        XCTAssertEqual(imports.gapState(for: channel), .unmatched)
        XCTAssertEqual(imports.guidePhase, .loaded)
    }

    private func testSources() -> [LiveTVGuideSource] {
        (1...3).map {
            LiveTVGuideSource(id: "source-\($0)", name: "Guide \($0)", url: URL(string: "https://example.com/\($0).xml")!)
        }
    }

    private func guide(
        channelID: String, title: String, method: LiveTVGuideMatchMethod, now: Date
    ) -> LiveTVGuideImport {
        let program = LiveTVPrototypeProgram(
            id: title, channelID: channelID, title: title, subtitle: "",
            start: now.addingTimeInterval(-60), end: now.addingTimeInterval(3_600)
        )
        return LiveTVGuideImport(
            programs: [program], matchedChannelCount: 1, guideChannelCount: 1, programCount: 1,
            coverageStart: program.start, coverageEnd: program.end,
            matches: [channelID: LiveTVGuideMatch(guideChannelID: "station", method: method)]
        )
    }
}

private actor MultiGuideLoader: LiveTVSourceLoading {
    let channels: [LiveTVPrototypeChannel]
    let guides: [URL: LiveTVGuideImport]
    var failures: Set<URL>
    let beforeGuide: @Sendable (URL) async -> Void

    init(
        channels: [LiveTVPrototypeChannel], guides: [URL: LiveTVGuideImport], failures: Set<URL> = [],
        beforeGuide: @escaping @Sendable (URL) async -> Void = { _ in }
    ) {
        self.channels = channels
        self.guides = guides
        self.failures = failures
        self.beforeGuide = beforeGuide
    }

    func setFailure(_ url: URL) { failures.insert(url) }

    func loadPlaylist(from url: URL) async throws -> LiveTVPlaylistImport {
        LiveTVPlaylistImport(channels: channels, entryCount: channels.count, skippedEntryCount: 0)
    }

    func loadGuide(from url: URL, channels: [LiveTVPrototypeChannel], now: Date) async throws -> LiveTVGuideImport {
        await beforeGuide(url)
        guard !failures.contains(url), let guide = guides[url] else { throw LiveTVSourceImportError.downloadFailed }
        return guide
    }
}

private actor SuspendedGuideLoader: LiveTVSourceLoading {
    let channel: LiveTVPrototypeChannel
    let guide: LiveTVGuideImport
    let started: XCTestExpectation
    var continuation: CheckedContinuation<Void, Never>?

    init(channel: LiveTVPrototypeChannel, guide: LiveTVGuideImport, started: XCTestExpectation) {
        self.channel = channel
        self.guide = guide
        self.started = started
    }

    func loadPlaylist(from url: URL) async throws -> LiveTVPlaylistImport {
        LiveTVPlaylistImport(channels: [channel], entryCount: 1, skippedEntryCount: 0)
    }

    func loadGuide(from url: URL, channels: [LiveTVPrototypeChannel], now: Date) async throws -> LiveTVGuideImport {
        await withCheckedContinuation {
            continuation = $0
            started.fulfill()
        }
        return guide
    }

    func finish() {
        continuation?.resume()
        continuation = nil
    }
}

private actor OverlappingImportLoader: LiveTVSourceLoading {
    let old: LiveTVPrototypeChannel
    let fresh: LiveTVPrototypeChannel
    let started: XCTestExpectation
    private var callCount = 0
    private var continuation: CheckedContinuation<Void, Never>?

    init(old: LiveTVPrototypeChannel, fresh: LiveTVPrototypeChannel, started: XCTestExpectation) {
        self.old = old
        self.fresh = fresh
        self.started = started
    }

    func loadPlaylist(from url: URL) async throws -> LiveTVPlaylistImport {
        callCount += 1
        let first = callCount == 1
        if first {
            await withCheckedContinuation {
                continuation = $0
                started.fulfill()
            }
        }
        return LiveTVPlaylistImport(channels: [first ? old : fresh], entryCount: 1, skippedEntryCount: 0)
    }

    func finishFirst() {
        continuation?.resume()
        continuation = nil
    }

    func loadGuide(
        from url: URL, channels: [LiveTVPrototypeChannel], now: Date
    ) async throws -> LiveTVGuideImport {
        LiveTVGuideImport(
            programs: [], matchedChannelCount: 0, guideChannelCount: 0, programCount: 0,
            coverageStart: nil, coverageEnd: nil
        )
    }
}

private actor ImportLoaderStub: LiveTVSourceLoading {
    enum Failure: Error { case unavailable }
    let channels: [LiveTVPrototypeChannel]
    let programs: [LiveTVPrototypeProgram]
    let playlistFails: Bool
    let guideFails: Bool
    let beforeGuide: @Sendable () async -> Void
    private(set) var guideLoads = 0
    private(set) var submittedChannelCount = 0
    private(set) var submittedGuideDate: Date?

    init(
        channels: [LiveTVPrototypeChannel], programs: [LiveTVPrototypeProgram] = [],
        playlistFails: Bool = false, guideFails: Bool = false,
        beforeGuide: @escaping @Sendable () async -> Void = {}
    ) {
        self.channels = channels
        self.programs = programs
        self.playlistFails = playlistFails
        self.guideFails = guideFails
        self.beforeGuide = beforeGuide
    }

    func loadPlaylist(from url: URL) async throws -> LiveTVPlaylistImport {
        if playlistFails { throw Failure.unavailable }
        return LiveTVPlaylistImport(channels: channels, entryCount: channels.count, skippedEntryCount: 0)
    }

    func loadGuide(
        from url: URL, channels: [LiveTVPrototypeChannel], now: Date
    ) async throws -> LiveTVGuideImport {
        guideLoads += 1
        submittedChannelCount = channels.count
        submittedGuideDate = now
        await beforeGuide()
        if guideFails { throw Failure.unavailable }
        return LiveTVGuideImport(
            programs: programs, matchedChannelCount: Set(programs.map(\.channelID)).count,
            guideChannelCount: Set(programs.map(\.channelID)).count, programCount: programs.count,
            coverageStart: programs.map(\.start).min(), coverageEnd: programs.map(\.end).max()
        )
    }
}
