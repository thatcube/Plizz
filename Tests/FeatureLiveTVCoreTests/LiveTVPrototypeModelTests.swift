import CoreModels
import Foundation
import XCTest
@testable import FeatureLiveTVCore

@MainActor
final class LiveTVPrototypeModelTests: XCTestCase {
    func testNoGuideCatalogRemainsSearchableAndFavoritable() throws {
        let model = LiveTVPrototypeModel(scenario: .noGuide)

        XCTAssertEqual(model.channels.count, 30)
        XCTAssertEqual(model.channel(id: model.channels[0].id), model.channels[0])
        XCTAssertEqual(model.categories, model.categories.sorted())
        XCTAssertTrue(model.channels.allSatisfy {
            model.currentProgram(for: $0.id) == nil
                && model.programs(for: $0.id, from: model.now).isEmpty
        })

        model.query = "quiet channel"
        let channel = try XCTUnwrap(model.visibleChannels.first)
        XCTAssertEqual(channel.name, "Quiet Channel")
        XCTAssertFalse(model.favoriteIDs.contains(channel.id))

        model.toggleFavorite(channel.id)
        model.favoritesOnly = true

        XCTAssertEqual(model.visibleChannels.map(\.id), [channel.id])
    }

    func testGuideCoverageMatchesScenariosAndIncludesEveryPlozzChannel() {
        let model = LiveTVPrototypeModel(scenario: .noGuide)
        let coveredCount = {
            model.channels.filter {
                model.currentProgram(for: $0.id) != nil
            }.count
        }

        XCTAssertEqual(coveredCount(), 0)
        model.scenario = .failedGuide
        XCTAssertEqual(coveredCount(), 0)

        model.scenario = .mixedGuide
        let mixedCount = coveredCount()
        XCTAssertGreaterThan(mixedCount, 10)
        XCTAssertLessThan(mixedCount, 20)
        XCTAssertTrue(
            model.channels
                .filter { $0.source == .plozz }
                .allSatisfy { model.currentProgram(for: $0.id) != nil }
        )

        model.scenario = .fullGuide
        XCTAssertEqual(coveredCount(), 30)
        model.scenario = .staleGuide
        XCTAssertEqual(coveredCount(), 30)
    }

    func testProgramsUseStableAbsoluteSlotsAndBoundedRequests() throws {
        let model = LiveTVPrototypeModel(scenario: .fullGuide)
        let channel = try XCTUnwrap(model.channels.first)
        let requestedStart = Date(timeIntervalSince1970: 1_788_719_777)
        let first = model.programs(for: channel.id, from: requestedStart, hours: 3)

        XCTAssertFalse(first.isEmpty)
        XCTAssertTrue(first.allSatisfy {
            [1_800.0, 3_600.0].contains($0.end.timeIntervalSince($0.start))
        })
        XCTAssertTrue(first.allSatisfy {
            Int($0.start.timeIntervalSince1970).isMultiple(of: 1_800)
        })
        XCTAssertLessThanOrEqual(
            model.programs(for: channel.id, from: requestedStart, hours: 100).count,
            49
        )

        model.advanceClock(by: 7_200)
        let second = model.programs(for: channel.id, from: requestedStart, hours: 3)
        XCTAssertEqual(second, first)
        let freshModel = LiveTVPrototypeModel(scenario: .fullGuide)
        XCTAssertEqual(
            freshModel.programs(for: channel.id, from: requestedStart, hours: 3),
            first
        )

        let program = try XCTUnwrap(first.first)
        XCTAssertEqual(program.progress(at: program.start.addingTimeInterval(-1)), 0)
        XCTAssertEqual(program.progress(at: program.end.addingTimeInterval(1)), 1)
        XCTAssertEqual(
            program.progress(at: program.start.addingTimeInterval(program.end.timeIntervalSince(program.start) / 2)),
            0.5,
            accuracy: 0.000_001
        )
    }

    func testFiltersCombineResetAndPreserveSort() {
        let model = LiveTVPrototypeModel()
        model.sort = .name
        model.query = "CINÉMA"
        model.category = "Movies"
        model.source = .jellyfin
        model.favoritesOnly = true

        XCTAssertEqual(model.visibleChannels.map(\.name), ["Cinema Club"])

        model.resetFilters()

        XCTAssertEqual(model.query, "")
        XCTAssertNil(model.category)
        XCTAssertNil(model.source)
        XCTAssertFalse(model.favoritesOnly)
        XCTAssertEqual(model.sort, .name)
        XCTAssertEqual(model.visibleChannels.count, 30)
        XCTAssertEqual(
            model.visibleChannels.map(\.name),
            model.visibleChannels.map(\.name).sorted {
                let locale = Locale(identifier: "en_US_POSIX")
                return $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
                    < $1.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
            }
        )
    }

    func testSearchIsDiacriticInsensitiveAndRanksExactNumberFirst() {
        let model = LiveTVPrototypeModel()

        model.query = "cafe"
        XCTAssertEqual(model.visibleChannels.map(\.name), ["Café Society"])

        model.sort = .name
        model.query = "2"
        XCTAssertEqual(model.visibleChannels.first?.number, 2)
        XCTAssertTrue(model.visibleChannels.dropFirst().contains { $0.number == 20 })
    }

    func testLogoMetadataSurvivesCatalogExpansionAndHasSafePublicURLs() throws {
        let model = LiveTVPrototypeModel(channels: LiveTVPrototypeCatalog.channels)
        let original = model.channels
        XCTAssertEqual(original.compactMap(\.logoURL).count, original.count)
        XCTAssertTrue(original.compactMap(\.logoURL).allSatisfy {
            $0.scheme == "https" && $0.user == nil && $0.password == nil
        })
        model.isLargeCatalog = true
        XCTAssertEqual(Array(model.channels.prefix(original.count)), original)
        XCTAssertEqual(model.channels[original.count].logoURL, original[0].logoURL)
        XCTAssertEqual(model.channels[original.count].streamURL, original[0].streamURL)
        let tastemade = try XCTUnwrap(model.channels.first { $0.name == "Tastemade" })
        XCTAssertTrue(tastemade.logoNeedsDarkBackground)
    }

    func testRealChannelsNeverAcquireSyntheticGuidePrograms() {
        let model = LiveTVPrototypeModel(channels: LiveTVPrototypeCatalog.channels)
        XCTAssertTrue(model.usesPublicStreams)
        XCTAssertEqual(Set(model.channels.map(\.id)).count, model.channels.count)
        XCTAssertEqual(model.channels.map(\.number), Array(1...model.channels.count))
        XCTAssertTrue(model.channels.allSatisfy {
            $0.source == .iptv && $0.streamURL?.scheme == "https"
                && $0.streamURL?.user == nil && $0.streamURL?.password == nil
        })
        for scenario in LiveTVPrototypeScenario.allCases {
            model.scenario = scenario
            XCTAssertTrue(model.channels.allSatisfy {
                model.programs(for: $0.id, from: model.now).isEmpty
            })
        }
        model.query = "espanol"
        XCTAssertEqual(model.visibleChannels.map(\.name), ["DW Español"])
    }

    func testImportedListingsDriveGuideWithoutFillingRealGaps() throws {
        let model = LiveTVPrototypeModel(channels: LiveTVPrototypeCatalog.channels)
        let channel = model.channels[0]
        let start = model.now.addingTimeInterval(600)
        let program = LiveTVPrototypeProgram(
            id: "real-program", channelID: channel.id, title: "Actual listing",
            subtitle: "", start: start, end: start.addingTimeInterval(1_800)
        )
        try model.replacePrograms([program])
        XCTAssertEqual(model.guideChannelCount, 1)
        XCTAssertNil(model.currentProgram(for: channel.id))
        XCTAssertEqual(model.programs(for: channel.id, from: model.now, hours: 2), [program])
        XCTAssertTrue(model.programs(for: model.channels[1].id, from: model.now).isEmpty)
        model.synchronizeClock(to: start)
        XCTAssertEqual(model.currentProgram(for: channel.id), program)
        model.synchronizeClock(to: program.end)
        XCTAssertNil(model.currentProgram(for: channel.id))
    }

    func testCatalogAndGuideRefreshPreserveIndependentFiltersAndFavorites() throws {
        let model = LiveTVPrototypeModel(channels: [])
        try model.replaceChannels(LiveTVPrototypeCatalog.channels)
        XCTAssertTrue(model.favoriteIDs.isEmpty)
        let channel = model.channels[0]
        model.query = channel.name
        model.category = channel.category
        model.sort = .name
        model.toggleFavorite(channel.id)
        model.favoritesOnly = true
        model.guideOnly = true
        XCTAssertTrue(model.visibleChannels.isEmpty)

        let program = LiveTVPrototypeProgram(
            id: "listing", channelID: channel.id, title: "Actual listing", subtitle: "",
            start: model.now, end: model.now.addingTimeInterval(3_600)
        )
        try model.replacePrograms([program])
        try model.replaceChannels(Array(LiveTVPrototypeCatalog.channels.reversed()))
        XCTAssertEqual(model.visibleChannels, [channel])
        XCTAssertEqual(model.currentProgram(for: channel.id), program)
        XCTAssertEqual(model.query, channel.name)
        XCTAssertEqual(model.category, channel.category)
        XCTAssertEqual(model.sort, .name)
        XCTAssertTrue(model.favoritesOnly)
        XCTAssertTrue(model.guideOnly)
        model.resetFilters()
        XCTAssertFalse(model.guideOnly)
        XCTAssertFalse(model.favoritesOnly)
        XCTAssertTrue(model.favoriteIDs.contains(channel.id))
    }

    func testBadImportedDataDoesNotReplaceLastGoodData() throws {
        let model = LiveTVPrototypeModel(channels: LiveTVPrototypeCatalog.channels)
        let original = model.channels
        XCTAssertThrowsError(try model.replaceChannels([original[0], original[0]]))
        XCTAssertEqual(model.channels, original)
        let program = LiveTVPrototypeProgram(
            id: "listing", channelID: original[0].id, title: "Listing", subtitle: "",
            start: model.now, end: model.now.addingTimeInterval(1_800)
        )
        try model.replacePrograms([program])
        XCTAssertThrowsError(try model.replacePrograms([program, program]))
        XCTAssertEqual(model.currentProgram(for: original[0].id), program)
        let invalid = LiveTVPrototypeProgram(
            id: "invalid", channelID: original[0].id, title: "Invalid", subtitle: "",
            start: model.now, end: model.now
        )
        XCTAssertThrowsError(try model.replacePrograms([invalid]))
        XCTAssertEqual(model.currentProgram(for: original[0].id), program)
        try model.replaceChannels(Array(original.dropFirst()))
        XCTAssertEqual(model.guideChannelCount, 0)
    }

    func testImportedGuideMetadataAndHeadersSurviveStressCopies() {
        let channel = LiveTVPrototypeChannel(
            id: "source-stream", number: 1, name: "Station", category: "News",
            symbol: "tv", accent: 0, source: .iptv, tagline: "",
            guideID: "provider.id", guideName: "Station HD",
            httpHeaders: ["User-Agent": "Test"]
        )
        let model = LiveTVPrototypeModel(isLargeCatalog: true, channels: [channel])
        XCTAssertEqual(model.channels[1].guideID, channel.guideID)
        XCTAssertEqual(model.channels[1].guideName, channel.guideName)
        XCTAssertEqual(model.channels[1].httpHeaders, channel.httpHeaders)
    }

    func testPrototypeLaunchPersistenceIsExplicitAndReversible() throws {
        let suite = "LiveTVPrototypeLaunchTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertFalse(LiveTVPrototypeLaunch.isEnabled(arguments: [], defaults: defaults))
        XCTAssertTrue(LiveTVPrototypeLaunch.isEnabled(arguments: ["--live-tv-prototype"], defaults: defaults))
        XCTAssertFalse(LiveTVPrototypeLaunch.isEnabled(arguments: [], defaults: defaults))
        XCTAssertTrue(LiveTVPrototypeLaunch.isEnabled(arguments: ["--live-tv-prototype-remember"], defaults: defaults))
        XCTAssertTrue(LiveTVPrototypeLaunch.isEnabled(arguments: [], defaults: defaults))
        XCTAssertFalse(LiveTVPrototypeLaunch.isEnabled(
            arguments: ["--live-tv-prototype-off", "--live-tv-prototype-remember", "--live-tv-prototype"],
            defaults: defaults
        ))
        XCTAssertFalse(LiveTVPrototypeLaunch.isEnabled(arguments: [], defaults: defaults))
    }

    func testLargeCatalogKeepsBaseIDsAndOffCatalogFavorites() throws {
        let model = LiveTVPrototypeModel()
        let baseIDs = model.channels.map(\.id)
        let baseFavoriteIDs = model.favoriteIDs

        model.isLargeCatalog = true

        XCTAssertEqual(model.channels.count, 5_000)
        XCTAssertEqual(Array(model.channels.prefix(30).map(\.id)), baseIDs)
        XCTAssertTrue(baseFavoriteIDs.isSubset(of: model.favoriteIDs))
        let largeOnlyID = try XCTUnwrap(model.channels.last?.id)
        model.toggleFavorite(largeOnlyID)

        model.isLargeCatalog = false
        XCTAssertTrue(model.favoriteIDs.contains(largeOnlyID))
        XCTAssertEqual(model.channels.count, 30)

        model.isLargeCatalog = true
        model.favoritesOnly = true
        XCTAssertTrue(model.visibleChannels.contains { $0.id == largeOnlyID })
    }

    func testShrinkingCatalogReleasesUnavailableDemoChannel() throws {
        let model = LiveTVPrototypeModel(isLargeCatalog: true)
        let largeOnlyID = try XCTUnwrap(model.channels.last?.id)
        model.tune(largeOnlyID)
        model.togglePause()
        model.advanceClock(by: 30)

        model.isLargeCatalog = false

        XCTAssertNil(model.playingChannelID)
        XCTAssertNil(model.previousChannelID)
        XCTAssertFalse(model.isPaused)
        XCTAssertEqual(model.behindLiveSeconds, 0)
    }

    func testTunePausePreviousBusyAndStopBehavior() throws {
        let model = LiveTVPrototypeModel()
        let first = try XCTUnwrap(model.channels.first?.id)
        let second = try XCTUnwrap(model.channels.dropFirst().first?.id)

        model.tune("not-a-fixture-channel")
        XCTAssertTrue(model.tuneFailed)
        XCTAssertNil(model.playingChannelID)
        model.clearTuneFailure()

        model.tune(first)
        XCTAssertEqual(model.playingChannelID, first)
        XCTAssertNil(model.previousChannelID)

        model.simulateTunerBusy = true
        model.tune(first)
        XCTAssertFalse(model.tuneFailed)
        model.tune(second)
        XCTAssertTrue(model.tuneFailed)
        XCTAssertEqual(model.playingChannelID, first)

        model.simulateTunerBusy = false
        model.tune(second)
        XCTAssertEqual(model.playingChannelID, second)
        XCTAssertEqual(model.previousChannelID, first)

        model.togglePause()
        model.advanceClock(by: 45)
        XCTAssertTrue(model.isPaused)
        XCTAssertEqual(model.behindLiveSeconds, 45)
        model.togglePause()
        model.advanceClock(by: 15)
        XCTAssertEqual(model.behindLiveSeconds, 45)
        model.goLive()
        XCTAssertFalse(model.isPaused)
        XCTAssertEqual(model.behindLiveSeconds, 0)

        model.tunePrevious()
        XCTAssertEqual(model.playingChannelID, first)
        XCTAssertEqual(model.previousChannelID, second)
        model.tunePrevious()
        XCTAssertEqual(model.playingChannelID, second)
        XCTAssertEqual(model.previousChannelID, first)

        model.stop()
        XCTAssertNil(model.playingChannelID)
        XCTAssertNil(model.previousChannelID)
        XCTAssertFalse(model.isPaused)
        XCTAssertEqual(model.behindLiveSeconds, 0)
        XCTAssertFalse(model.tuneFailed)
    }

    func testHidingChannelFiltersEverySectionWithoutErasingStateOrPlayback() throws {
        let store = HiddenChannelsFixtureStore()
        let channels = hiddenChannelFixtures
        let model = LiveTVPrototypeModel(channels: channels, preferencesStore: store)
        let hidden = channels[0]

        model.toggleFavorite(hidden.id)
        model.tune(hidden.id)
        XCTAssertTrue(model.recordWatched(hidden.id))
        XCTAssertTrue(model.hideChannel(hidden))

        XCTAssertEqual(model.channels, channels)
        XCTAssertEqual(model.channel(id: hidden.id), hidden)
        XCTAssertEqual(model.playingChannelID, hidden.id)
        XCTAssertTrue(model.favoriteIDs.contains(hidden.id))
        XCTAssertTrue(model.recentChannelIDs.contains(hidden.id))
        XCTAssertEqual(model.hiddenChannels, [
            LiveTVHiddenChannel(id: hidden.id, name: hidden.name),
        ])
        XCTAssertFalse(model.visibleChannels.contains { $0.id == hidden.id })
        XCTAssertFalse(model.guideChannels.contains { $0.channel.id == hidden.id })
        XCTAssertFalse(model.categories.contains(hidden.category))

        model.query = hidden.name
        XCTAssertTrue(model.visibleChannels.isEmpty)
        model.resetFilters()
        XCTAssertFalse(model.visibleChannels.contains { $0.id == hidden.id })
        XCTAssertEqual(store.value.favoriteIDs, [hidden.id])
        XCTAssertEqual(store.value.recentChannelIDs, [hidden.id])
    }

    func testFavoriteAndRecentWritesPreserveHiddenMetadata() {
        let store = HiddenChannelsFixtureStore()
        let channels = hiddenChannelFixtures
        let model = LiveTVPrototypeModel(channels: channels, preferencesStore: store)

        XCTAssertTrue(model.hideChannel(channels[0]))
        model.toggleFavorite(channels[1].id)
        model.tune(channels[1].id)
        XCTAssertTrue(model.recordWatched(channels[1].id))

        XCTAssertEqual(store.value.hiddenChannels, [
            LiveTVHiddenChannel(id: channels[0].id, name: channels[0].name),
        ])
        XCTAssertEqual(store.value.favoriteIDs, [channels[1].id])
        XCTAssertEqual(store.value.recentChannelIDs, [channels[1].id])
    }

    func testHiddenMissingSourceSurvivesCatalogReplacementAndReloadedRestore() throws {
        let store = HiddenChannelsFixtureStore()
        let channels = hiddenChannelFixtures
        let hidden = channels[0]
        let model = LiveTVPrototypeModel(channels: channels, preferencesStore: store)

        XCTAssertTrue(model.hideChannel(hidden))
        try model.replaceChannels(Array(channels.dropFirst()))
        XCTAssertEqual(model.hiddenChannels.map(\.id), [hidden.id])
        XCTAssertEqual(store.value.hiddenChannels.map(\.id), [hidden.id])

        try store.save(store.value.restoringChannel(id: hidden.id))
        model.reloadPreferences()
        XCTAssertTrue(model.hiddenChannels.isEmpty)
        XCTAssertFalse(model.visibleChannels.contains { $0.id == hidden.id })

        try model.replaceChannels(channels)
        XCTAssertTrue(model.visibleChannels.contains { $0.id == hidden.id })
        XCTAssertTrue(model.categories.contains(hidden.category))
    }

    func testReloadRestoresHiddenChannelSubjectToCurrentFilters() throws {
        let store = HiddenChannelsFixtureStore()
        let channels = hiddenChannelFixtures
        let hidden = channels[0]
        let model = LiveTVPrototypeModel(channels: channels, preferencesStore: store)
        model.category = hidden.category

        XCTAssertTrue(model.hideChannel(hidden))
        XCTAssertTrue(model.visibleChannels.isEmpty)
        try store.save(store.value.restoringAllChannels())

        model.reloadPreferences()

        XCTAssertEqual(model.category, hidden.category)
        XCTAssertEqual(model.visibleChannels, [hidden])
    }

    func testHiddenPreferenceSaveFailureRetriesWithoutLosingMutation() {
        let store = HiddenChannelsFixtureStore()
        let channels = hiddenChannelFixtures
        let model = LiveTVPrototypeModel(channels: channels, preferencesStore: store)
        store.failSave = true

        XCTAssertFalse(model.hideChannel(channels[0]))
        XCTAssertEqual(model.preferencesIssue, .saveFailed)
        XCTAssertTrue(model.hiddenChannels.isEmpty)
        XCTAssertTrue(model.visibleChannels.contains { $0.id == channels[0].id })

        store.failSave = false
        model.reloadPreferences()

        XCTAssertNil(model.preferencesIssue)
        XCTAssertEqual(model.hiddenChannels.map(\.id), [channels[0].id])
        XCTAssertFalse(model.visibleChannels.contains { $0.id == channels[0].id })
    }

    func testReloadFailurePreservesLastKnownHiddenChannels() {
        let store = HiddenChannelsFixtureStore()
        store.value = LiveTVPreferences(
            hiddenChannels: [
                LiveTVHiddenChannel(id: hiddenChannelFixtures[0].id, name: "Saved Name"),
            ]
        )
        let model = LiveTVPrototypeModel(
            channels: hiddenChannelFixtures,
            preferencesStore: store
        )
        store.value = .empty
        store.failLoad = true

        model.reloadPreferences()

        XCTAssertEqual(model.preferencesIssue, .loadFailed)
        XCTAssertEqual(model.hiddenChannels.map(\.id), [hiddenChannelFixtures[0].id])
        XCTAssertFalse(model.visibleChannels.contains { $0.id == hiddenChannelFixtures[0].id })
    }

    func testRetryingAFavoriteDoesNotUndoSettingsRestoration() {
        let store = HiddenChannelsFixtureStore()
        let channels = hiddenChannelFixtures
        let model = LiveTVPrototypeModel(channels: channels, preferencesStore: store)
        XCTAssertTrue(model.hideChannel(channels[0]))
        store.failSave = true
        model.toggleFavorite(channels[1].id)
        store.value = store.value.restoringAllChannels()

        model.reloadPreferences()
        XCTAssertEqual(model.preferencesIssue, .saveFailed)
        store.failSave = false
        model.reloadPreferences()

        XCTAssertTrue(model.hiddenChannels.isEmpty)
        XCTAssertTrue(store.value.hiddenChannels.isEmpty)
        XCTAssertEqual(store.value.favoriteIDs, [channels[1].id])
    }

    func testRetryingHidePreservesNewFavoritesAndRecentsSavedElsewhere() {
        let store = HiddenChannelsFixtureStore()
        let channels = hiddenChannelFixtures
        let model = LiveTVPrototypeModel(channels: channels, preferencesStore: store)
        store.failSave = true
        XCTAssertFalse(model.hideChannel(channels[0]))
        store.value = LiveTVPreferences(favoriteIDs: [channels[1].id], recentChannelIDs: [channels[1].id])
        store.failLoad = true
        model.reloadPreferences()
        XCTAssertEqual(model.preferencesIssue, .loadFailed)
        store.failLoad = false
        store.failSave = false
        model.reloadPreferences()

        XCTAssertEqual(model.hiddenChannelIDs, [channels[0].id])
        XCTAssertEqual(model.favoriteIDs, [channels[1].id])
        XCTAssertEqual(model.recentChannelIDs, [channels[1].id])
    }

    func testMultiviewFavoritesSurviveOrdinaryChannelPreferenceChanges() {
        let store = HiddenChannelsFixtureStore()
        let channels = hiddenChannelFixtures
        let model = LiveTVPrototypeModel(channels: channels, preferencesStore: store)
        let favorite = LiveTVMultiviewFavorite(
            id: "saved", name: "My channels", channelIDs: channels.map(\.id), layout: .mainAndStack)
        XCTAssertTrue(model.saveMultiviewFavorite(favorite))
        model.toggleFavorite(channels[0].id)
        model.tune(channels[0].id)
        XCTAssertTrue(model.recordWatched(channels[0].id))
        XCTAssertTrue(model.hideChannel(channels[1]))
        model.category = channels[0].category
        XCTAssertEqual(store.value.favoriteMultiviews, [favorite])
        model.reloadPreferences()
        XCTAssertEqual(model.favoriteMultiviews, [favorite])
        XCTAssertTrue(model.removeMultiviewFavorite(favorite.id))
        XCTAssertTrue(model.favoriteMultiviews.isEmpty)
        XCTAssertEqual(model.favoriteIDs, [channels[0].id])
    }

    func testFailedMultiviewSaveRetriesWithoutErasingConcurrentFavorites() {
        let store = HiddenChannelsFixtureStore()
        let channels = hiddenChannelFixtures
        let model = LiveTVPrototypeModel(channels: channels, preferencesStore: store)
        let requested = LiveTVMultiviewFavorite(
            id: "requested", name: "My channels", channelIDs: channels.map(\.id), layout: .sideBySide)
        let concurrent = LiveTVMultiviewFavorite(
            id: "concurrent", name: "Another setup", channelIDs: channels.map(\.id), layout: .mainAndStack)
        store.failSave = true
        XCTAssertFalse(model.saveMultiviewFavorite(requested))
        XCTAssertTrue(model.favoriteMultiviews.isEmpty)
        store.value = LiveTVPreferences(favoriteIDs: [channels[0].id], favoriteMultiviews: [concurrent])
        store.failSave = false
        model.retryPreferences()
        XCTAssertNil(model.preferencesIssue)
        XCTAssertEqual(model.favoriteMultiviews, [concurrent, requested])
        XCTAssertEqual(model.favoriteIDs, [channels[0].id])
    }

    private var hiddenChannelFixtures: [LiveTVPrototypeChannel] {
        [
            LiveTVPrototypeChannel(
                id: "news", number: 1, name: "News Channel", category: "News",
                symbol: "newspaper", accent: 0, source: .iptv, tagline: ""
            ),
            LiveTVPrototypeChannel(
                id: "sports", number: 2, name: "Sports Channel", category: "Sports",
                symbol: "sportscourt", accent: 1, source: .iptv, tagline: ""
            ),
        ]
    }
}

private final class HiddenChannelsFixtureStore: LiveTVPreferencesStoring, @unchecked Sendable {
    enum Failure: Error {
        case unavailable
    }

    var value = LiveTVPreferences.empty
    var failLoad = false
    var failSave = false

    func load() throws -> LiveTVPreferences {
        if failLoad {
            throw Failure.unavailable
        }
        return value
    }

    func save(_ preferences: LiveTVPreferences) throws {
        if failSave {
            throw Failure.unavailable
        }
        value = preferences
    }
}
