#if DEBUG
import CoreModels
import XCTest
@testable import FeatureLiveTVCore

@MainActor
final class LiveTVMultiviewCoordinatorTests: XCTestCase {
    private func channel(_ number: Int) -> LiveTVPrototypeChannel {
        LiveTVPrototypeChannel(
            id: "multiview-\(number)", number: number, name: "Channel \(number)",
            category: "Sports", symbol: "tv", accent: 0, source: .iptv,
            tagline: "", streamURL: URL(string: "https://example.invalid/\(number).m3u8")!
        )
    }

    private func makeCoordinator(
        authorizes: @escaping @MainActor @Sendable (
            LiveTVPrototypeChannel, LiveTVServerChannelReference?
        ) -> Bool = { _, _ in true },
        watched: @escaping @MainActor (String) -> Void = { _ in }
    ) async -> LiveTVMultiviewCoordinator {
        let primary = LiveTVPlaybackPreparation()
        let loaded = await primary.prepare(channel(1), isAuthorized: { true }, accept: { true })
        XCTAssertTrue(loaded)
        return LiveTVMultiviewCoordinator(
            primary: primary, makePreparation: { LiveTVPlaybackPreparation() },
            reference: { _ in nil }, authorizes: authorizes, recordWatched: watched
        )
    }

    func testEntryAndLayoutChangesRetainPrimaryPreparationAndStream() async {
        let coordinator = await makeCoordinator()
        let original = coordinator.panes[0]
        let stream = original.preparation.current
        XCTAssertTrue(coordinator.begin())
        await coordinator.add(channel(2))?.value
        let ids = coordinator.panes.map(\.id)
        coordinator.layout = .corner
        coordinator.corner = .topLeading
        coordinator.insetSize = .large
        coordinator.promote(ids[1])
        coordinator.expand(ids[1])
        coordinator.collapse()
        XCTAssertEqual(coordinator.panes.map(\.id), ids)
        XCTAssertTrue(coordinator.panes[0].preparation === original.preparation)
        XCTAssertEqual(original.preparation.current, stream)
        await coordinator.close()
    }

    func testDuplicateSelectsExistingPaneWithoutAnotherStream() async {
        let coordinator = await makeCoordinator()
        coordinator.begin()
        await coordinator.add(channel(2))?.value
        let second = coordinator.panes[1]
        let preparedID = second.preparation.current?.id
        XCTAssertNil(coordinator.add(channel(2)))
        XCTAssertEqual(coordinator.panes.count, 2)
        XCTAssertEqual(coordinator.audiblePaneID, second.id)
        XCTAssertEqual(second.preparation.current?.id, preparedID)
        await coordinator.close()
    }

    func testSelectingAnAlreadyPendingGuideChannelDoesNotMuteCurrentAudioOrAllocateAnotherPane() async {
        let coordinator = await makeCoordinator()
        coordinator.begin()
        let originalAudio = coordinator.audiblePaneID
        let pending = coordinator.add(channel(2))
        XCTAssertNil(coordinator.add(channel(2)))
        XCTAssertEqual(coordinator.panes.count, 2)
        XCTAssertEqual(coordinator.audiblePaneID, originalAudio)
        await pending?.value
        await coordinator.close()
    }

    func testFourChannelCapacityRejectsFifthWithoutTouchingExistingStreams() async {
        let coordinator = await makeCoordinator()
        coordinator.begin()
        for number in 2...4 {
            XCTAssertTrue(coordinator.canAdd)
            await coordinator.add(channel(number))?.value
        }
        XCTAssertEqual(coordinator.maximumPanes, 4)
        XCTAssertEqual(coordinator.panes.count, 4)
        XCTAssertFalse(coordinator.canAdd)
        let ids = coordinator.panes.map { $0.preparation.current?.id }
        XCTAssertNil(coordinator.add(channel(5)))
        XCTAssertNotNil(coordinator.issue)
        XCTAssertEqual(coordinator.panes.map { $0.preparation.current?.id }, ids)
        await coordinator.close()
    }

    func testSetupWatchExpansionAndPromotionRetainAllFourPreparedStreams() async {
        let coordinator = await makeCoordinator()
        coordinator.begin()
        XCTAssertTrue(coordinator.isEditingLayout)
        for number in 2...4 { await coordinator.add(channel(number))?.value }
        let owners = coordinator.panes.map(\.preparation)
        let ids = coordinator.panes.map { $0.preparation.current?.id }
        coordinator.finishEditingLayout()
        XCTAssertFalse(coordinator.isEditingLayout)
        for pane in coordinator.panes {
            coordinator.selectAudio(pane.id)
            coordinator.expand(pane.id)
            coordinator.collapse()
            coordinator.promote(pane.id)
        }
        coordinator.beginEditingLayout()
        XCTAssertTrue(coordinator.isEditingLayout)
        XCTAssertNil(coordinator.expandedPaneID)
        XCTAssertEqual(coordinator.panes.map { $0.preparation.current?.id }, ids)
        XCTAssertTrue(zip(coordinator.panes, owners).allSatisfy { $0.0.preparation === $0.1 })
        await coordinator.close()
    }

    func testAspectRatioUpdatesBelongOnlyToTheMatchingPreparedStream() async throws {
        let coordinator = await makeCoordinator()
        let pane = coordinator.panes[0]
        let preparedID = try XCTUnwrap(pane.preparation.current?.id)
        coordinator.updateVideoAspectRatio(4 / 3, paneID: pane.id, preparedID: preparedID)
        XCTAssertEqual(pane.videoAspectRatio, 4 / 3)
        coordinator.updateVideoAspectRatio(2, paneID: pane.id, preparedID: UUID())
        XCTAssertEqual(pane.videoAspectRatio, 4 / 3)
        coordinator.updateVideoAspectRatio(.infinity, paneID: pane.id, preparedID: preparedID)
        XCTAssertNil(pane.videoAspectRatio)
        await coordinator.close()
    }

    func testExitKeepsAudibleOwnerWithoutRepreparingIt() async {
        let coordinator = await makeCoordinator()
        coordinator.begin()
        let original = coordinator.panes[0]
        await coordinator.add(channel(2))?.value
        let selected = coordinator.panes[1]
        let prepared = selected.preparation.current
        coordinator.selectAudio(selected.id)
        let survivor = coordinator.exit()
        XCTAssertTrue(survivor === selected.preparation)
        XCTAssertEqual(survivor?.current, prepared)
        XCTAssertEqual(coordinator.panes.map(\.id), [selected.id])
        XCTAssertNil(original.preparation.current)
        XCTAssertFalse(coordinator.isEnabled)
        await coordinator.close()
    }

    func testDeniedAdditionalSourceDoesNotStopCurrentChannel() async {
        let coordinator = await makeCoordinator(authorizes: { channel, _ in channel.id == "multiview-1" })
        let original = coordinator.panes[0].preparation.current
        coordinator.begin()
        await coordinator.add(channel(2))?.value
        XCTAssertEqual(coordinator.panes[0].preparation.current, original)
        XCTAssertNil(coordinator.panes[1].preparation.current)
        XCTAssertEqual(coordinator.panes[1].preparation.failure, .sourceUnavailable)
        await coordinator.close()
    }

    func testFailedReplacementKeepsExistingPaneAndOtherFeed() async {
        let coordinator = await makeCoordinator(authorizes: { channel, _ in channel.id != "multiview-3" })
        coordinator.begin()
        await coordinator.add(channel(2))?.value
        let original = coordinator.panes.map { $0.preparation.current }
        await coordinator.replace(coordinator.panes[1].id, with: channel(3))?.value
        XCTAssertEqual(coordinator.panes.map { $0.preparation.current }, original)
        await coordinator.close()
    }

    func testOnlyMatchingPresentedStreamRecordsChannelHistory() async throws {
        var watched: [String] = []
        let coordinator = await makeCoordinator(watched: { watched.append($0) })
        coordinator.begin()
        await coordinator.add(channel(2))?.value
        let pane = coordinator.panes[1]
        coordinator.confirmWatching(pane.id, preparedID: UUID())
        XCTAssertTrue(watched.isEmpty)
        coordinator.confirmWatching(pane.id, preparedID: try XCTUnwrap(pane.preparation.current?.id))
        coordinator.confirmWatching(pane.id, preparedID: try XCTUnwrap(pane.preparation.current?.id))
        XCTAssertEqual(watched, ["multiview-2"])
        await coordinator.close()
    }

    func testPlayPauseTargetsAudioSelectionNotOtherPanes() async {
        let coordinator = await makeCoordinator()
        coordinator.begin()
        await coordinator.add(channel(2))?.value
        coordinator.selectAudio(coordinator.panes[1].id)
        coordinator.requestPlayPause()
        XCTAssertEqual(coordinator.panes.map(\.playPauseRequest), [0, 1])
        await coordinator.close()
    }

    func testLateFailureCannotResetReplacementPresentationOrHistory() async throws {
        var watched: [String] = []
        let coordinator = await makeCoordinator(watched: { watched.append($0) })
        coordinator.begin()
        await coordinator.add(channel(2))?.value
        let pane = coordinator.panes[1]
        let previous = try XCTUnwrap(pane.preparation.current?.id)
        await coordinator.replace(pane.id, with: channel(3))?.value
        let current = try XCTUnwrap(pane.preparation.current?.id)
        coordinator.confirmWatching(pane.id, preparedID: current)
        coordinator.playbackFailed(pane.id, preparedID: previous)
        XCTAssertTrue(pane.hasPresentedFrame)
        XCTAssertEqual(pane.preparation.current?.id, current)
        coordinator.confirmWatching(pane.id, preparedID: current)
        XCTAssertEqual(watched, ["multiview-3"])
        await coordinator.close()
    }

    func testDeactivationStopsEveryPaneAndPendingWork() async {
        let coordinator = await makeCoordinator()
        coordinator.begin()
        for number in 2...4 { await coordinator.add(channel(number))?.value }
        let owners = coordinator.panes.map(\.preparation)
        XCTAssertEqual(owners.count, 4)
        coordinator.setActive(false)
        XCTAssertFalse(coordinator.isEnabled)
        XCTAssertTrue(owners.allSatisfy { $0.current == nil })
        await coordinator.close()
    }

    func testFavoriteCapturesDisplayedOrderAndLayoutNotChangingAudioFocus() async throws {
        let coordinator = await makeCoordinator()
        coordinator.begin()
        for number in 2...4 { await coordinator.add(channel(number))?.value }
        coordinator.layout = .mainAndStack
        coordinator.promote(coordinator.panes[2].id)
        let favorite = try XCTUnwrap(coordinator.favoriteSnapshot())
        XCTAssertEqual(favorite.channelIDs, ["multiview-3", "multiview-1", "multiview-2", "multiview-4"])
        XCTAssertEqual(favorite.layout, .mainAndStack)
        coordinator.selectAudio(coordinator.panes[3].id)
        XCTAssertTrue(coordinator.matches(favorite))
        coordinator.layout = .sideBySide
        XCTAssertFalse(coordinator.matches(favorite))
        await coordinator.close()
    }

    func testRestoreFavoriteReusesMatchingFirstStreamAndPreparesOnlyRemainingChannels() async {
        let coordinator = await makeCoordinator()
        let original = coordinator.panes[0].preparation.current
        let favorite = LiveTVMultiviewFavorite(
            name: "Four channels", channelIDs: (1...4).map { channel($0).id }, layout: .mainAndStack)
        XCTAssertTrue(coordinator.restore(favorite, from: (1...4).map(channel)))
        for _ in 0..<100 {
            if coordinator.panes.allSatisfy({ $0.preparation.current != nil }) { break }
            await Task.yield()
        }
        XCTAssertEqual(coordinator.panes.count, 4)
        XCTAssertTrue(coordinator.panes.allSatisfy { $0.preparation.current != nil })
        XCTAssertEqual(coordinator.panes[0].preparation.current, original)
        XCTAssertFalse(coordinator.isEditingLayout)
        XCTAssertTrue(coordinator.matches(favorite))
        await coordinator.close()
    }

    func testMissingFavoriteChannelsDoNotReplaceCurrentPlayback() async {
        let coordinator = await makeCoordinator()
        let original = coordinator.panes[0].preparation.current
        let favorite = LiveTVMultiviewFavorite(
            name: "Missing channel", channelIDs: [channel(1).id, "missing"], layout: .mainAndStack)
        XCTAssertFalse(coordinator.restore(favorite, from: [channel(1)]))
        XCTAssertFalse(coordinator.isEnabled)
        XCTAssertEqual(coordinator.panes.count, 1)
        XCTAssertEqual(coordinator.panes[0].preparation.current, original)
        XCTAssertNotNil(coordinator.issue)
        await coordinator.close()
    }

    func testRestoringFavoriteReusesCurrentChannelWhenItBelongsInSideColumn() async {
        let coordinator = await makeCoordinator()
        let retained = coordinator.panes[0]
        let prepared = retained.preparation.current
        let favorite = LiveTVMultiviewFavorite(
            name: "Different main", channelIDs: [channel(2).id, channel(1).id, channel(3).id],
            layout: .mainAndStack)
        XCTAssertTrue(coordinator.restore(favorite, from: (1...3).map(channel)))
        for _ in 0..<100 {
            if coordinator.panes.allSatisfy({ $0.preparation.current != nil }) { break }
            await Task.yield()
        }
        XCTAssertEqual(coordinator.panes.map { $0.channel?.id }, favorite.channelIDs)
        XCTAssertTrue(coordinator.panes[1] === retained)
        XCTAssertEqual(retained.preparation.current, prepared)
        XCTAssertEqual(coordinator.primaryPaneID, coordinator.panes[0].id)
        XCTAssertTrue(coordinator.matches(favorite))
        await coordinator.close()
    }

    func testUnauthorizedFavoriteDoesNotAcquireAdditionalStreams() async {
        let coordinator = await makeCoordinator(authorizes: { channel, _ in channel.id == "multiview-1" })
        let favorite = LiveTVMultiviewFavorite(
            name: "Restricted channel", channelIDs: [channel(1).id, channel(2).id], layout: .sideBySide)
        XCTAssertFalse(coordinator.restore(favorite, from: [channel(1), channel(2)]))
        XCTAssertFalse(coordinator.isEnabled)
        XCTAssertEqual(coordinator.panes.count, 1)
        XCTAssertNotNil(coordinator.issue)
        await coordinator.close()
    }
}
#endif
