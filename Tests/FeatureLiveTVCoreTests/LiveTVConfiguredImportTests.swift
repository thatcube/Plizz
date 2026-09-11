import CoreModels
import Foundation
import XCTest
@testable import FeatureLiveTVCore

@MainActor
final class LiveTVConfiguredImportTests: XCTestCase {
    func testOnlySafeDeclaredGuidesAreDiscoveredAfterChannelsPublish() async throws {
        let playlist = source()
        let safe = URL(string: "https://example.test/discovered.xml")!
        let text = m3u.replacingOccurrences(
            of: "#EXTM3U", with: "#EXTM3U url-tvg=\"\(safe.absoluteString),https://other.test/guide.xml\""
        )
        let loader = ConfiguredImportLoader(playlists: [playlist.playlistURL: text], guides: [:])
        let imports = LiveTVPrototypeImportModel(
            configuration: .init(playlists: [playlist]), loader: loader
        )
        let model = LiveTVPrototypeModel(channels: [])
        await imports.reload(into: model)
        XCTAssertEqual(model.channels.count, 1)
        XCTAssertEqual(imports.guideSources.map(\.source.url), [safe])
        XCTAssertEqual(imports.guideDiscoveryFailures[playlist.id], .unsafeGuideOrigin)
        let calls = await loader.calls
        XCTAssertEqual(calls.guides, [safe])
    }

    func testDefaultImporterNeverSelectsOrLoadsPublicFeeds() async {
        let loader = ConfiguredImportLoader()
        let imports = LiveTVPrototypeImportModel(loader: loader)
        await imports.reload(into: LiveTVPrototypeModel(channels: []))
        XCTAssertEqual(imports.configuration, .empty)
        XCTAssertNil(imports.playlistURL)
        XCTAssertTrue(imports.guideSources.isEmpty)
        let calls = await loader.calls
        XCTAssertTrue(calls.playlists.isEmpty)
        XCTAssertTrue(calls.guides.isEmpty)
    }

    func testExplicitPlaylistDoesNotImplicitlyAddPublicGuides() async {
        let playlist = source()
        let loader = ConfiguredImportLoader(playlists: [playlist.playlistURL: m3u])
        let imports = LiveTVPrototypeImportModel(playlistURL: playlist.playlistURL, loader: loader)
        await imports.reload(into: LiveTVPrototypeModel(channels: []))
        XCTAssertTrue(imports.guideSources.isEmpty)
        let calls = await loader.calls
        XCTAssertEqual(calls.playlists, [playlist.playlistURL])
        XCTAssertTrue(calls.guides.isEmpty)
    }

    func testApplyingAnAlreadyEmptyConfigurationClearsAnExistingCatalogImmediately() throws {
        let model = LiveTVPrototypeModel()
        let imports = LiveTVPrototypeImportModel(configuration: .empty, loader: ConfiguredImportLoader())
        try imports.applyConfiguration(.empty, into: model)
        XCTAssertTrue(model.channels.isEmpty)
        XCTAssertNil(imports.playlistURL)
    }

    func testEmptyAndDisabledConfigurationsClearChannelsWithoutAnyNetworkRequests() async {
        for configuration in [
            LiveTVSourcesConfiguration.empty,
            LiveTVSourcesConfiguration(playlists: [source(isEnabled: false)])
        ] {
            let loader = ConfiguredImportLoader()
            let model = LiveTVPrototypeModel()
            model.tune(model.channels[0].id)
            let imports = LiveTVPrototypeImportModel(configuration: configuration, loader: loader)
            await imports.reload(into: model)
            XCTAssertTrue(model.channels.isEmpty)
            XCTAssertNil(model.playingChannelID)
            XCTAssertEqual(imports.configuration, configuration)
            XCTAssertEqual(imports.playlistPhase, .idle)
            XCTAssertEqual(imports.guidePhase, .idle)
            XCTAssertFalse(imports.isLoading)
            let calls = await loader.calls
            XCTAssertTrue(calls.playlists.isEmpty)
            XCTAssertTrue(calls.guides.isEmpty)
        }
    }

    func testPlaylistWithoutGuideIsValidAndOnlyUsesItsConfiguredAddress() async throws {
        let playlist = source()
        let loader = ConfiguredImportLoader(playlists: [playlist.playlistURL: m3u])
        let imports = LiveTVPrototypeImportModel(
            configuration: LiveTVSourcesConfiguration(playlists: [playlist]), loader: loader
        )
        let model = LiveTVPrototypeModel(channels: [])
        await imports.reload(into: model)
        let channel = try XCTUnwrap(model.channels.first)
        XCTAssertEqual(imports.playlistPhase, .loaded)
        XCTAssertEqual(imports.guidePhase, .idle)
        XCTAssertEqual(imports.gapState(for: channel), .disabled)
        XCTAssertEqual(imports.entryCount, 1)
        XCTAssertEqual(imports.playlistSources[0].channelCount, 1)
        XCTAssertNotNil(imports.playlistSources[0].lastRefresh)
        XCTAssertNil(imports.playlistSources[0].failure)
        let calls = await loader.calls
        XCTAssertEqual(calls.playlists, [playlist.playlistURL])
        XCTAssertTrue(calls.guides.isEmpty)
        XCTAssertTrue(model.recentChannelIDs.isEmpty)
    }

    func testIdenticalChannelsAndGuidesFromDifferentPlaylistsNeverCollideOrCrossMatch() async throws {
        let now = Date()
        let guideURL = URL(string: "https://example.test/shared.xml.gz?token=sample-only")!
        let first = source(id: "one", guides: [guideURL])
        let second = source(id: "two", guides: [guideURL])
        let loader = ConfiguredImportLoader(
            playlists: [first.playlistURL: m3u, second.playlistURL: m3u],
            guides: [guideURL: xml(title: "Same schedule", now: now)]
        )
        let imports = LiveTVPrototypeImportModel(
            configuration: LiveTVSourcesConfiguration(playlists: [first, second]), loader: loader
        )
        let model = LiveTVPrototypeModel(now: now, channels: [])
        await imports.reload(into: model)
        XCTAssertEqual(model.channels.count, 2)
        XCTAssertEqual(Set(model.channels.map(\.id)).count, 2)
        XCTAssertEqual(imports.entryCount, 2)
        XCTAssertEqual(imports.programCount, 2)
        XCTAssertEqual(imports.guideSources.count, 2)
        XCTAssertEqual(Set(imports.guideSources.map(\.id)).count, 2)
        let programs = try model.channels.map { try XCTUnwrap(model.currentProgram(for: $0.id)) }
        XCTAssertEqual(Set(programs.map(\.id)).count, 2)
        for channel in model.channels {
            let guideID = try XCTUnwrap(imports.selectedSourceByChannel[channel.id])
            let guide = try XCTUnwrap(imports.guideSources.first { $0.id == guideID })
            XCTAssertEqual(guide.playlistSourceID, imports.playlistSourceIDByChannel[channel.id])
            XCTAssertEqual(channel.playlistSourceID, imports.playlistSourceIDByChannel[channel.id])
        }
        let submitted = await loader.submittedChannels
        XCTAssertEqual(submitted.count, 2)
        XCTAssertEqual(submitted.map(\.count), [1, 1])
        XCTAssertNotEqual(submitted[0], submitted[1])
    }

    func testSourceRenameAndOrderEditsKeepIDsPreferencesAndCachedChannelsWithoutFetching() async throws {
        let first = source(id: "one")
        let second = source(id: "two")
        let loader = ConfiguredImportLoader(playlists: [first.playlistURL: m3u, second.playlistURL: m3u])
        let imports = LiveTVPrototypeImportModel(
            configuration: LiveTVSourcesConfiguration(playlists: [first, second]), loader: loader
        )
        let model = LiveTVPrototypeModel(channels: [])
        await imports.reload(into: model)
        let ids = Set(model.channels.map(\.id))
        let favorite = try XCTUnwrap(model.channels.first?.id)
        model.toggleFavorite(favorite)
        var renamed = first
        renamed.name = "Renamed playlist"
        try imports.applyConfiguration(LiveTVSourcesConfiguration(playlists: [second, renamed]), into: model)
        XCTAssertEqual(Set(model.channels.map(\.id)), ids)
        XCTAssertTrue(model.favoriteIDs.contains(favorite))
        let beforeReload = await loader.calls
        XCTAssertEqual(beforeReload.playlists.count, 2)
        await imports.reload(into: model)
        XCTAssertEqual(Set(model.channels.map(\.id)), ids)
        XCTAssertEqual(imports.playlistSources.map(\.source.name), [second.name, renamed.name])
    }

    func testFailedPlaylistDoesNotHideHealthySourcesOrDiscardItsLastGoodChannels() async {
        let first = source(id: "one")
        let second = source(id: "two")
        let loader = ConfiguredImportLoader(playlists: [first.playlistURL: m3u, second.playlistURL: m3u])
        let imports = LiveTVPrototypeImportModel(
            configuration: LiveTVSourcesConfiguration(playlists: [first, second]), loader: loader
        )
        let model = LiveTVPrototypeModel(channels: [])
        await imports.reload(into: model)
        let original = model.channels
        await loader.failPlaylist(second.playlistURL)
        await imports.reload(into: model)
        XCTAssertEqual(model.channels, original)
        XCTAssertEqual(imports.playlistPhase, .loaded)
        XCTAssertEqual(imports.playlistSources[0].phase, .loaded)
        XCTAssertEqual(imports.playlistSources[1].phase, .failed)
        XCTAssertEqual(imports.playlistSources[1].failure, .downloadFailed)
        XCTAssertNotNil(imports.playlistSources[1].lastRefresh)
        XCTAssertFalse(imports.isLoading)
    }

    func testFirstLoadFailureStillPublishesOtherConfiguredSources() async {
        let first = source(id: "missing")
        let second = source(id: "working")
        let loader = ConfiguredImportLoader(playlists: [second.playlistURL: m3u])
        let imports = LiveTVPrototypeImportModel(
            configuration: LiveTVSourcesConfiguration(playlists: [first, second]), loader: loader
        )
        let model = LiveTVPrototypeModel(channels: [])
        await imports.reload(into: model)
        XCTAssertEqual(model.channels.count, 1)
        XCTAssertEqual(Set(imports.playlistSourceIDByChannel.values), [second.id])
        XCTAssertEqual(imports.playlistSources[0].failure, .downloadFailed)
        XCTAssertEqual(imports.playlistSources[1].phase, .loaded)
    }

    func testDisableAndReenablePlaylistsAlsoRestoreTheirGuideSources() async throws {
        let now = Date()
        let guideURL = URL(string: "https://example.test/guide.xml")!
        let playlist = source(guides: [guideURL])
        let loader = ConfiguredImportLoader(
            playlists: [playlist.playlistURL: m3u], guides: [guideURL: xml(title: "Schedule", now: now)]
        )
        let imports = LiveTVPrototypeImportModel(
            configuration: LiveTVSourcesConfiguration(playlists: [playlist]), loader: loader
        )
        let model = LiveTVPrototypeModel(now: now, channels: [])
        await imports.reload(into: model)
        let originalID = try XCTUnwrap(model.channels.first?.id)
        let guideID = try XCTUnwrap(imports.guideSources.first?.id)
        try imports.setPlaylistEnabled(playlist.id, enabled: false, into: model)
        XCTAssertTrue(model.channels.isEmpty)
        XCTAssertTrue(imports.enabledSourceIDs.isEmpty)
        XCTAssertEqual(imports.programCount, 0)
        XCTAssertNil(imports.lastGuideRefresh)
        await imports.reload(into: model)
        let disabledCalls = await loader.calls
        XCTAssertEqual(disabledCalls.playlists.count, 1)
        XCTAssertEqual(disabledCalls.guides.count, 1)
        try imports.setPlaylistEnabled(playlist.id, enabled: true, into: model)
        XCTAssertTrue(imports.enabledSourceIDs.contains(guideID))
        await imports.reload(into: model)
        XCTAssertEqual(model.channels.first?.id, originalID)
        XCTAssertEqual(model.currentProgram(for: originalID)?.title, "Schedule")
    }

    func testGuideOptOutSurvivesPlaylistDisableAndReenableWithoutAffectingOtherGuides() async throws {
        let now = Date()
        let firstGuide = URL(string: "https://example.test/first.xml")!
        let secondGuide = URL(string: "https://example.test/second.xml")!
        let playlist = source(guides: [firstGuide, secondGuide])
        let loader = ConfiguredImportLoader(
            playlists: [playlist.playlistURL: m3u],
            guides: [firstGuide: xml(title: "First", now: now), secondGuide: xml(title: "Second", now: now)]
        )
        let imports = LiveTVPrototypeImportModel(
            configuration: LiveTVSourcesConfiguration(playlists: [playlist]), loader: loader
        )
        let model = LiveTVPrototypeModel(now: now, channels: [])
        await imports.reload(into: model)
        let firstID = try XCTUnwrap(imports.guideSources.first?.id)
        try imports.setSourceEnabled(firstID, enabled: false, into: model)
        XCTAssertEqual(model.currentProgram(for: model.channels[0].id)?.title, "Second")
        try imports.setPlaylistEnabled(playlist.id, enabled: false, into: model)
        XCTAssertThrowsError(try imports.setSourceEnabled(firstID, enabled: true, into: model))
        try imports.setPlaylistEnabled(playlist.id, enabled: true, into: model)
        XCTAssertFalse(imports.enabledSourceIDs.contains(firstID))
        XCTAssertEqual(imports.enabledSourceIDs.count, 1)
        await imports.reload(into: model)
        XCTAssertEqual(model.currentProgram(for: model.channels[0].id)?.title, "Second")
    }

    func testEditingPlaylistAddressRemovesOnlyThatSourcesCachedChannelsAndGuides() async throws {
        let now = Date()
        let guideURL = URL(string: "https://example.test/guide.xml")!
        let first = source(id: "one", guides: [guideURL])
        let second = source(id: "two")
        var edited = first
        edited.playlistURL = URL(string: "https://example.test/changed.m3u?token=new-sample")!
        let loader = ConfiguredImportLoader(
            playlists: [first.playlistURL: m3u, second.playlistURL: m3u, edited.playlistURL: m3u],
            guides: [guideURL: xml(title: "Old schedule", now: now)]
        )
        let imports = LiveTVPrototypeImportModel(
            configuration: LiveTVSourcesConfiguration(playlists: [first, second]), loader: loader
        )
        let model = LiveTVPrototypeModel(now: now, channels: [])
        await imports.reload(into: model)
        let previousIDs = Set(model.channels.map(\.id))
        try imports.applyConfiguration(LiveTVSourcesConfiguration(playlists: [edited, second]), into: model)
        XCTAssertEqual(model.channels.count, 1)
        XCTAssertEqual(Set(imports.playlistSourceIDByChannel.values), [second.id])
        XCTAssertEqual(imports.programCount, 0)
        await imports.reload(into: model)
        XCTAssertEqual(Set(model.channels.map(\.id)), previousIDs)
    }

    func testRemovingAllSourcesImmediatelyClearsPlaybackAndListingsButNotSavedFavorites() async throws {
        let playlist = source()
        let loader = ConfiguredImportLoader(playlists: [playlist.playlistURL: m3u])
        let imports = LiveTVPrototypeImportModel(
            configuration: LiveTVSourcesConfiguration(playlists: [playlist]), loader: loader
        )
        let model = LiveTVPrototypeModel(channels: [])
        await imports.reload(into: model)
        let channel = try XCTUnwrap(model.channels.first)
        model.toggleFavorite(channel.id)
        model.tune(channel.id)
        try imports.applyConfiguration(.empty, into: model)
        XCTAssertNil(imports.playlistURL)
        XCTAssertTrue(model.channels.isEmpty)
        XCTAssertNil(model.playingChannelID)
        XCTAssertTrue(model.favoriteIDs.contains(channel.id))
        XCTAssertEqual(imports.entryCount, 0)
        XCTAssertEqual(imports.programCount, 0)
        XCTAssertTrue(imports.guideSources.isEmpty)
        XCTAssertFalse(imports.isLoading)
    }

    func testLatePlaylistCannotRepopulateAReplacedConfiguration() async throws {
        let first = source(id: "old")
        let second = source(id: "new")
        let started = expectation(description: "Old playlist suspended")
        let loader = ConfiguredImportLoader(
            playlists: [first.playlistURL: m3u, second.playlistURL: m3u],
            suspendedPlaylist: first.playlistURL, started: started
        )
        let imports = LiveTVPrototypeImportModel(
            configuration: LiveTVSourcesConfiguration(playlists: [first]), loader: loader
        )
        let model = LiveTVPrototypeModel(channels: [])
        let old = Task { await imports.reload(into: model) }
        await fulfillment(of: [started], timeout: 2)
        try imports.applyConfiguration(LiveTVSourcesConfiguration(playlists: [second]), into: model)
        await imports.reload(into: model)
        await loader.resume()
        await old.value
        XCTAssertEqual(model.channels.count, 1)
        XCTAssertEqual(Set(imports.playlistSourceIDByChannel.values), [second.id])
        XCTAssertEqual(imports.playlistSources.map(\.id), [second.id])
        XCTAssertEqual(imports.playlistPhase, .loaded)
    }

    func testLateGuideCannotOverwriteAnEditedGuideConfiguration() async throws {
        let now = Date()
        let oldURL = URL(string: "https://example.test/old.xml")!
        let newURL = URL(string: "https://example.test/new.xml")!
        let playlist = source(guides: [oldURL])
        let started = expectation(description: "Old guide suspended")
        let loader = ConfiguredImportLoader(
            playlists: [playlist.playlistURL: m3u],
            guides: [oldURL: xml(title: "Stale", now: now), newURL: xml(title: "Current", now: now)],
            suspendedGuide: oldURL, started: started
        )
        let imports = LiveTVPrototypeImportModel(
            configuration: LiveTVSourcesConfiguration(playlists: [playlist]), loader: loader
        )
        let model = LiveTVPrototypeModel(now: now, channels: [])
        let old = Task { await imports.reload(into: model) }
        await fulfillment(of: [started], timeout: 2)
        var edited = playlist
        edited.guideURLs = [newURL]
        try imports.applyConfiguration(LiveTVSourcesConfiguration(playlists: [edited]), into: model)
        await imports.reload(into: model)
        await loader.resume()
        await old.value
        let channel = try XCTUnwrap(model.channels.first)
        XCTAssertEqual(model.currentProgram(for: channel.id)?.title, "Current")
        XCTAssertEqual(imports.guideSources.map(\.source.url), [newURL])
        XCTAssertEqual(imports.guidePhase, .loaded)
    }

    func testRemovingSourceDuringDownloadFencesItsLateResultWithoutReplacementReload() async throws {
        let playlist = source()
        let started = expectation(description: "Playlist suspended")
        let loader = ConfiguredImportLoader(
            playlists: [playlist.playlistURL: m3u], suspendedPlaylist: playlist.playlistURL, started: started
        )
        let imports = LiveTVPrototypeImportModel(
            configuration: LiveTVSourcesConfiguration(playlists: [playlist]), loader: loader
        )
        let model = LiveTVPrototypeModel(channels: [])
        let task = Task { await imports.reload(into: model) }
        await fulfillment(of: [started], timeout: 2)
        try imports.applyConfiguration(.empty, into: model)
        await loader.resume()
        await task.value
        XCTAssertTrue(model.channels.isEmpty)
        XCTAssertEqual(imports.configuration, .empty)
        XCTAssertFalse(imports.isLoading)
        XCTAssertNil(imports.playlistFailure)
    }

    func testCancelledPlaylistNeverPublishesLateChannelsOrReportsAParseFailure() async {
        let playlist = source()
        let started = expectation(description: "Playlist suspended")
        let loader = ConfiguredImportLoader(
            playlists: [playlist.playlistURL: m3u], suspendedPlaylist: playlist.playlistURL, started: started
        )
        let imports = LiveTVPrototypeImportModel(
            configuration: LiveTVSourcesConfiguration(playlists: [playlist]), loader: loader
        )
        let model = LiveTVPrototypeModel(channels: [])
        let task = Task { await imports.reload(into: model) }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        await loader.resume()
        await task.value
        XCTAssertTrue(model.channels.isEmpty)
        XCTAssertEqual(imports.playlistPhase, .idle)
        XCTAssertNil(imports.playlistFailure)
        XCTAssertFalse(imports.isLoading)
    }

    func testUnconfiguredGuideOnOnePlaylistNeverUsesAnotherPlaylistsFailedGuide() async throws {
        let first = source(id: "without-guide")
        let second = source(id: "with-guide", guides: [URL(string: "https://example.test/missing.xml")!])
        let loader = ConfiguredImportLoader(playlists: [first.playlistURL: m3u, second.playlistURL: m3u])
        let imports = LiveTVPrototypeImportModel(
            configuration: LiveTVSourcesConfiguration(playlists: [first, second]), loader: loader
        )
        let model = LiveTVPrototypeModel(channels: [])
        await imports.reload(into: model)
        let channel = try XCTUnwrap(model.channels.first {
            imports.playlistSourceIDByChannel[$0.id] == first.id
        })
        XCTAssertEqual(imports.gapState(for: channel), .disabled)
        XCTAssertEqual(imports.failedSourceCount, 1)
    }

    func testSavedDeveloperTestPlaylistPreservesLegacyChannelAndGuideIDs() async throws {
        let configuration = LiveTVSourcesConfiguration(playlists: [
            LiveTVPlaylistSource(
                id: "free-us", name: "Developer test channels",
                playlistURL: URL(string: "https://iptv-org.github.io/iptv/countries/us.m3u")!,
                guideURLs: LiveTVGuideSource.recognizedSources.map(\.url)
            )
        ])
        try configuration.validate()
        let playlist = try XCTUnwrap(configuration.playlists.first)
        XCTAssertEqual(playlist.guideURLs, LiveTVGuideSource.recognizedSources.map(\.url))
        let loader = ConfiguredImportLoader(playlists: [playlist.playlistURL: m3u])
        let imports = LiveTVPrototypeImportModel(configuration: configuration, loader: loader)
        let model = LiveTVPrototypeModel(channels: [])
        await imports.reload(into: model)
        let parsed = try LiveTVPlaylistParser().parse(m3u)
        XCTAssertEqual(model.channels.map(\.id), parsed.channels.map(\.id))
        XCTAssertTrue(model.channels.allSatisfy { $0.playlistSourceID == playlist.id })
        XCTAssertEqual(imports.guideSources.map(\.id), LiveTVGuideSource.recognizedSources.map(\.id))
    }

    func testInvalidConfigurationNeverFetchesAndCanBeReplacedWithoutAffectingValidWork() async throws {
        let playlist = source()
        let loader = ConfiguredImportLoader(playlists: [playlist.playlistURL: m3u])
        let invalid = LiveTVSourcesConfiguration(playlists: [playlist, playlist])
        let imports = LiveTVPrototypeImportModel(configuration: invalid, loader: loader)
        let model = LiveTVPrototypeModel(channels: [])
        await imports.reload(into: model)
        XCTAssertEqual(imports.playlistFailure, .invalidPlaylist)
        let calls = await loader.calls
        XCTAssertTrue(calls.playlists.isEmpty)
        let valid = LiveTVSourcesConfiguration(playlists: [playlist])
        try imports.applyConfiguration(valid, into: model)
        await imports.reload(into: model)
        let channels = model.channels
        XCTAssertThrowsError(try imports.applyConfiguration(invalid, into: model))
        XCTAssertEqual(imports.configuration, valid)
        XCTAssertEqual(model.channels, channels)
    }

    func testNamedPlaylistFilterCombinesWithKindFavoritesAndSearchAndResetsCleanly() async throws {
        let first = source(id: "one")
        let second = source(id: "two")
        let loader = ConfiguredImportLoader(playlists: [first.playlistURL: m3u, second.playlistURL: m3u])
        let imports = LiveTVPrototypeImportModel(
            configuration: LiveTVSourcesConfiguration(playlists: [first, second]), loader: loader
        )
        let model = LiveTVPrototypeModel(channels: [])
        await imports.reload(into: model)
        let firstChannel = try XCTUnwrap(model.channels.first { $0.playlistSourceID == first.id })
        let secondChannel = try XCTUnwrap(model.channels.first { $0.playlistSourceID == second.id })
        model.toggleFavorite(firstChannel.id)
        model.toggleFavorite(secondChannel.id)
        model.source = .iptv
        model.playlistSourceID = first.id
        model.query = "same"
        model.favoritesOnly = true
        XCTAssertEqual(model.visibleChannels.map(\.id), [firstChannel.id])
        XCTAssertTrue(model.guideChannels.allSatisfy { $0.channel.playlistSourceID == first.id })
        model.source = .plex
        XCTAssertTrue(model.visibleChannels.isEmpty)
        model.source = .iptv
        model.playlistSourceID = second.id
        XCTAssertEqual(model.visibleChannels.map(\.id), [secondChannel.id])
        model.resetFilters()
        XCTAssertNil(model.playlistSourceID)
        XCTAssertNil(model.source)
        XCTAssertEqual(model.visibleChannels.count, 2)
    }

    func testRenamingSelectedPlaylistKeepsFilteringAndDisablingItRevealsOtherSources() async throws {
        let first = source(id: "one")
        let second = source(id: "two")
        let loader = ConfiguredImportLoader(playlists: [first.playlistURL: m3u, second.playlistURL: m3u])
        let imports = LiveTVPrototypeImportModel(
            configuration: LiveTVSourcesConfiguration(playlists: [first, second]), loader: loader
        )
        let model = LiveTVPrototypeModel(channels: [])
        await imports.reload(into: model)
        model.playlistSourceID = first.id
        let visibleIDs = model.visibleChannels.map(\.id)
        var renamed = first
        renamed.name = "New display name"
        try imports.applyConfiguration(LiveTVSourcesConfiguration(playlists: [renamed, second]), into: model)
        XCTAssertEqual(model.playlistSourceID, first.id)
        XCTAssertEqual(model.visibleChannels.map(\.id), visibleIDs)
        XCTAssertEqual(imports.playlistSources.first?.source.name, renamed.name)
        try imports.setPlaylistEnabled(first.id, enabled: false, into: model)
        XCTAssertNil(model.playlistSourceID)
        XCTAssertTrue(model.visibleChannels.allSatisfy { $0.playlistSourceID == second.id })
        XCTAssertEqual(model.visibleChannels.count, 1)
    }

    func testStressCatalogCopiesRetainConfiguredPlaylistProvenance() async {
        let first = source(id: "one")
        let second = source(id: "two")
        let loader = ConfiguredImportLoader(playlists: [first.playlistURL: m3u, second.playlistURL: m3u])
        let imports = LiveTVPrototypeImportModel(
            configuration: LiveTVSourcesConfiguration(playlists: [first, second]), loader: loader
        )
        let model = LiveTVPrototypeModel(isLargeCatalog: true, channels: [])
        await imports.reload(into: model)
        model.playlistSourceID = first.id
        XCTAssertEqual(model.visibleChannels.count, 2_500)
        XCTAssertTrue(model.visibleChannels.allSatisfy { $0.playlistSourceID == first.id })
    }

    private func source(id: String = "custom", guides: [URL] = [], isEnabled: Bool = true) -> LiveTVPlaylistSource {
        LiveTVPlaylistSource(
            id: id, name: id, playlistURL: URL(string: "https://example.test/\(id).m3u?token=sample-only")!,
            guideURLs: guides, isEnabled: isEnabled
        )
    }

    private var m3u: String {
        """
        #EXTM3U
        #EXTINF:-1 tvg-id="Same.us" tvg-name="Same channel",Same channel
        https://example.test/live.m3u8
        """
    }

    private func xml(title: String, now: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmmss Z"
        return """
        <tv>
          <channel id="Same.us"><display-name>Same channel</display-name></channel>
          <programme channel="Same.us" start="\(formatter.string(from: now.addingTimeInterval(-60)))"
                     stop="\(formatter.string(from: now.addingTimeInterval(3_600)))">
            <title>\(title)</title>
          </programme>
        </tv>
        """
    }
}

private actor ConfiguredImportLoader: LiveTVSourceLoading {
    let playlists: [URL: String]
    let guides: [URL: String]
    var suspendedPlaylist: URL?
    var suspendedGuide: URL?
    let started: XCTestExpectation?
    var continuation: CheckedContinuation<Void, Never>?
    var failedPlaylists: Set<URL> = []
    private(set) var calls: (playlists: [URL], guides: [URL]) = ([], [])
    private(set) var submittedChannels: [[String]] = []

    init(
        playlists: [URL: String] = [:], guides: [URL: String] = [:],
        suspendedPlaylist: URL? = nil, suspendedGuide: URL? = nil, started: XCTestExpectation? = nil
    ) {
        self.playlists = playlists
        self.guides = guides
        self.suspendedPlaylist = suspendedPlaylist
        self.suspendedGuide = suspendedGuide
        self.started = started
    }

    func failPlaylist(_ url: URL) { failedPlaylists.insert(url) }

    func loadPlaylist(from url: URL) async throws -> LiveTVPlaylistImport {
        calls.playlists.append(url)
        if url == suspendedPlaylist {
            suspendedPlaylist = nil
            await withCheckedContinuation {
                continuation = $0
                started?.fulfill()
            }
        }
        guard !failedPlaylists.contains(url), let playlist = playlists[url] else {
            throw LiveTVSourceImportError.downloadFailed
        }
        return try LiveTVPlaylistParser(baseURL: url).parse(playlist)
    }

    func loadGuide(from url: URL, channels: [LiveTVPrototypeChannel], now: Date) async throws -> LiveTVGuideImport {
        calls.guides.append(url)
        submittedChannels.append(channels.map(\.id))
        if url == suspendedGuide {
            suspendedGuide = nil
            await withCheckedContinuation {
                continuation = $0
                started?.fulfill()
            }
        }
        guard let guide = guides[url] else { throw LiveTVSourceImportError.downloadFailed }
        return try LiveTVXMLTVParser().parseXML(data: Data(guide.utf8), channels: channels, now: now)
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
