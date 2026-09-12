import Foundation
import XCTest
@testable import FeatureLiveTVCore

@MainActor
final class LiveTVGuideSectionTests: XCTestCase {
    func testUnwatchedCatalogDoesNotInventRecentOrFavoriteSections() {
        let model = makeModel()
        XCTAssertEqual(model.guideChannels.map(\.channel.id), model.visibleChannels.map(\.id))
        XCTAssertEqual(Set(model.guideChannels.map(\.section)), [.channels])
        XCTAssertEqual(model.guideChannels.filter(\.startsSection).map(\.channel.id), ["0"])
    }

    func testPreviewAndFailedOrStaleTunesDoNotRecordWatching() {
        let model = makeModel()
        model.tune("0")
        XCTAssertTrue(model.recentChannelIDs.isEmpty)
        XCTAssertFalse(model.recordWatched("1"))
        XCTAssertFalse(model.recordWatched("missing"))
        XCTAssertTrue(model.recordWatched("0"))
        model.tune("1")
        XCTAssertFalse(model.recordWatched("0"))
        model.simulateTunerBusy = true
        model.tune("2")
        XCTAssertTrue(model.tuneFailed)
        XCTAssertFalse(model.recordWatched("2"))
        model.stop()
        XCTAssertFalse(model.recordWatched("1"))
        XCTAssertEqual(model.recentChannelIDs, ["0"])
    }

    func testRecentHistoryIsUniqueBoundedAndMostRecentFirst() {
        let model = makeModel()
        for id in ["0", "1", "2", "3", "1", "1"] {
            model.tune(id)
            XCTAssertTrue(model.recordWatched(id))
        }
        XCTAssertEqual(model.recentChannelIDs, ["1", "3", "2"])
        XCTAssertEqual(model.guideChannels.prefix(3).map(\.channel.id), ["1", "3", "2"])
        XCTAssertEqual(model.guideChannels.filter { $0.section == .recent }.count, 3)
        XCTAssertTrue(model.guideChannels.contains { $0.channel.id == "0" && $0.section == .channels })
    }

    func testRecentAndFavoriteShortcutsKeepEveryChannelInTheMainList() {
        let model = makeModel()
        model.toggleFavorite("0")
        model.toggleFavorite("2")
        for id in ["1", "2"] {
            model.tune(id)
            model.recordWatched(id)
        }
        XCTAssertEqual(model.guideChannels.map(\.channel.id), ["2", "1", "0", "2", "0", "1", "2", "3", "4", "5", "6", "7"])
        XCTAssertEqual(model.guideChannels.filter(\.startsSection).map(\.section), [.recent, .favorites, .channels])
        XCTAssertTrue(model.favoriteIDs.contains("2"))
        XCTAssertEqual(Set(model.guideChannels.map(\.id)).count, model.guideChannels.count)
        XCTAssertEqual(
            model.guideChannels.filter { $0.channel.id == "2" }.map(\.section),
            [.recent, .favorites, .channels]
        )
        XCTAssertEqual(model.guideChannels.filter { $0.section == .channels }.map(\.channel.id), model.visibleChannels.map(\.id))
        model.toggleFavorite("0")
        XCTAssertEqual(model.guideChannels.filter { $0.section == .favorites }.map(\.channel.id), ["2"])
        XCTAssertEqual(model.guideChannels.first?.channel.id, "2")
    }

    func testEveryGroupRespectsSearchCategorySourceAndGuideFilters() throws {
        let model = makeModel()
        model.toggleFavorite("0")
        model.toggleFavorite("1")
        for id in ["1", "2", "3"] {
            model.tune(id)
            model.recordWatched(id)
        }
        model.category = "News"
        XCTAssertEqual(model.guideChannels.map(\.channel.id), ["2", "0", "0", "2", "4", "6"])
        model.query = "Channel 2"
        XCTAssertEqual(model.guideChannels.map(\.channel.id), ["2", "2"])
        model.query = ""
        model.source = .plex
        XCTAssertEqual(model.guideChannels.map(\.channel.id), ["4", "6"])
        try model.replacePrograms([
            LiveTVPrototypeProgram(
                id: "listing", channelID: "6", title: "Actual programme", subtitle: "",
                start: model.now, end: model.now.addingTimeInterval(1_800)
            )
        ])
        model.guideOnly = true
        XCTAssertEqual(model.guideChannels.map(\.channel.id), ["6"])
        model.resetFilters()
        model.favoritesOnly = true
        XCTAssertEqual(model.guideChannels.map(\.channel.id), ["1", "0", "1", "0", "1"])
        XCTAssertEqual(model.recentChannelIDs, ["3", "2", "1"])
    }

    func testCatalogRefreshKeepsMainRowIDsAndRetainsTemporarilyMissingHistory() throws {
        let model = makeModel()
        let before = Set(model.guideChannels.map(\.id))
        model.toggleFavorite("5")
        model.tune("5")
        model.recordWatched("5")
        XCTAssertEqual(Set(model.guideChannels.filter { $0.section == .channels }.map(\.id)), before)
        XCTAssertEqual(model.guideChannels.first?.channel.id, "5")
        try model.replaceChannels(model.channels.filter { $0.id != "5" })
        XCTAssertEqual(model.recentChannelIDs, ["5"])
        XCTAssertFalse(model.guideChannels.contains { $0.channel.id == "5" })
        XCTAssertTrue(model.favoriteIDs.contains("5"))
        try model.replaceChannels([])
        XCTAssertTrue(model.guideChannels.isEmpty)
    }

    func testTransportSnapshotDoesNotBounceAsRecentsReorder() {
        let model = makeModel()
        let sequence = LiveTVChannelSequence(channels: model.guideChannels.map(\.channel))
        for id in ["0", "1", "2"] {
            model.tune(id)
            model.recordWatched(id)
        }
        XCTAssertEqual(model.guideChannels.prefix(3).map(\.channel.id), ["2", "1", "0"])
        XCTAssertEqual(sequence.neighbor(of: "2", offset: 1, visibleChannels: model.visibleChannels), "3")
        XCTAssertEqual(sequence.neighbor(of: "2", offset: -1, visibleChannels: model.visibleChannels), "1")
        XCTAssertEqual(sequence.neighbor(of: "0", offset: -1, visibleChannels: model.visibleChannels), "7")
        model.category = "News"
        XCTAssertEqual(sequence.neighbor(of: "2", offset: 1, visibleChannels: model.visibleChannels), "4")
        XCTAssertNil(sequence.neighbor(of: "3", offset: 1, visibleChannels: model.visibleChannels))
        XCTAssertNil(sequence.neighbor(of: "0", offset: 1, visibleChannels: []))
    }

    func testLargeCatalogKeepsMainRowsStableWhenShortcutsAreAdded() {
        let model = LiveTVPrototypeModel(scenario: .noGuide, isLargeCatalog: true)
        let id = model.channels[4_999].id
        model.tune(id)
        model.recordWatched(id)
        XCTAssertEqual(model.guideChannels.first?.channel.id, id)
        XCTAssertEqual(model.guideChannels.filter { $0.section == .channels }.count, 5_000)
        XCTAssertEqual(model.guideChannels.count, 5_000 + model.favoriteIDs.count + 1)
        XCTAssertEqual(Set(model.guideChannels.map(\.id)).count, model.guideChannels.count)
        model.stop()
        XCTAssertEqual(LiveTVGuideFocusTarget.returningToPlayback(in: model, selectedChannelID: nil), .channelContent(id))
    }

    func testTransportSnapshotSkipsDuplicateShortcutOccurrences() {
        let model = makeModel()
        model.toggleFavorite("1")
        model.toggleFavorite("2")
        model.tune("2")
        model.recordWatched("2")
        let sequence = LiveTVChannelSequence(channels: model.guideChannels.map(\.channel))
        XCTAssertEqual(sequence.neighbor(of: "2", offset: 1, visibleChannels: model.visibleChannels), "1")
        XCTAssertEqual(sequence.neighbor(of: "1", offset: 1, visibleChannels: model.visibleChannels), "0")
        XCTAssertEqual(sequence.neighbor(of: "0", offset: 1, visibleChannels: model.visibleChannels), "3")
        XCTAssertEqual(sequence.neighbor(of: "3", offset: -1, visibleChannels: model.visibleChannels), "0")
    }

    private func makeModel() -> LiveTVPrototypeModel {
        LiveTVPrototypeModel(scenario: .noGuide, channels: (0 ..< 8).map { index in
            LiveTVPrototypeChannel(
                id: "\(index)", number: index, name: "Channel \(index)",
                category: index.isMultiple(of: 2) ? "News" : "Movies",
                symbol: "tv", accent: 0, source: index < 4 ? .iptv : .plex, tagline: ""
            )
        })
    }
}
