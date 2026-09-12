import CoreModels
import Foundation
import XCTest
@testable import FeatureLiveTVCore

@MainActor
final class LiveTVPlaybackCoordinatorTests: XCTestCase {
    func testAdoptingMultiviewOwnerRetainsPreparedIdentityAndNormalStopOwnership() async throws {
        let fixture = CoordinatorFixture()
        let retained = LiveTVPlaybackPreparation()
        let channel = try XCTUnwrap(fixture.model.channel(id: "iptv"))
        _ = await retained.prepare(channel, isAuthorized: { true }, accept: { true })
        let preparedID = retained.current?.id
        XCTAssertTrue(fixture.coordinator.adoptPreparation(retained))
        XCTAssertTrue(fixture.coordinator.preparation === retained)
        XCTAssertEqual(retained.current?.id, preparedID)
        XCTAssertEqual(fixture.model.playingChannelID, "iptv")
        XCTAssertTrue(fixture.preview.isExpanded)
        fixture.coordinator.setActive(false)
        XCTAssertNil(retained.current)
        await retained.close()
    }

    func testAdoptingMultiviewOwnerRechecksCurrentCatalogNotOnlyItsOriginalClosure() async throws {
        let fixture = CoordinatorFixture()
        let retained = LiveTVPlaybackPreparation()
        let channel = try XCTUnwrap(fixture.model.channel(id: "iptv"))
        _ = await retained.prepare(channel, isAuthorized: { true }, accept: { true })
        fixture.scope.enabledSources.remove("playlist")
        XCTAssertFalse(fixture.coordinator.adoptPreparation(retained))
        XCTAssertTrue(fixture.coordinator.preparation === retained)
        XCTAssertNil(retained.current)
        XCTAssertEqual(retained.failure, .sourceUnavailable)
        await retained.close()
    }

    func testCancelledWatchCannotReopenFullscreenOrReplacePreviousFeed() async throws {
        let entered = expectation(description: "Watch opens")
        let gate = CoordinatorFixtureGate()
        let candidate = try CoordinatorFixtureLease("one")
        let fixture = CoordinatorFixture(replies: [
            "one": [.init(lease: candidate, entered: entered, gate: gate)]
        ])
        _ = await fixture.coordinator.watch("iptv").value
        fixture.preview.returnToGuide(restoresFocus: false)
        let oldID = fixture.preparation.current?.id
        let watch = fixture.coordinator.watch("one")
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertEqual(fixture.model.playingChannelID, "iptv")
        XCTAssertFalse(fixture.preview.isExpanded)
        fixture.coordinator.cancelWatch()
        await gate.release()
        let accepted = await watch.value
        XCTAssertFalse(accepted)
        XCTAssertNil(fixture.coordinator.pendingWatchChannelID)
        XCTAssertNil(fixture.coordinator.watchFailure)
        XCTAssertFalse(fixture.preview.isExpanded)
        XCTAssertEqual(fixture.preparation.current?.id, oldID)
        let closes = await candidate.closeCalls
        XCTAssertEqual(closes, 1)
        await fixture.preparation.close()
    }

    func testLatestWatchWinsWhenEarlierOpenIgnoresCancellation() async throws {
        let entered = expectation(description: "Older Watch opens")
        let gate = CoordinatorFixtureGate()
        let first = try CoordinatorFixtureLease("one")
        let second = try CoordinatorFixtureLease("two")
        let fixture = CoordinatorFixture(replies: [
            "one": [.init(lease: first, entered: entered, gate: gate)],
            "two": [.init(lease: second)]
        ])
        let older = fixture.coordinator.watch("one")
        await fulfillment(of: [entered], timeout: 2)
        let latest = await fixture.coordinator.watch("two").value
        let currentID = fixture.preparation.current?.id
        await gate.release()
        let stale = await older.value
        XCTAssertTrue(latest)
        XCTAssertFalse(stale)
        XCTAssertEqual(fixture.preparation.current?.id, currentID)
        XCTAssertEqual(fixture.model.playingChannelID, "two")
        XCTAssertTrue(fixture.preview.isExpanded)
        let closes = await first.closeCalls
        XCTAssertEqual(closes, 1)
        await fixture.preparation.close()
    }

    func testFocusPreviewCannotStealPendingWatch() async throws {
        let entered = expectation(description: "Watch opens")
        let gate = CoordinatorFixtureGate()
        let fixture = CoordinatorFixture(replies: [
            "one": [.init(lease: try CoordinatorFixtureLease("one"), entered: entered, gate: gate)]
        ])
        let watch = fixture.coordinator.watch("one")
        await fulfillment(of: [entered], timeout: 2)
        fixture.preview.focus("two")
        let request = try XCTUnwrap(fixture.preview.pendingRequest)
        let previewed = await fixture.coordinator.preparePreview(request)
        XCTAssertFalse(previewed)
        let opens = await fixture.provider.opens
        XCTAssertEqual(opens, ["one"])
        XCTAssertEqual(fixture.coordinator.pendingWatchChannelID, "one")
        await gate.release()
        let accepted = await watch.value
        XCTAssertTrue(accepted)
        XCTAssertEqual(fixture.model.playingChannelID, "one")
        await fixture.preparation.close()
    }

    func testWatchSupersedesAnAlreadyOpeningPreview() async throws {
        let entered = expectation(description: "Preview opens")
        let gate = CoordinatorFixtureGate()
        let first = try CoordinatorFixtureLease("one")
        let fixture = CoordinatorFixture(replies: [
            "one": [.init(lease: first, entered: entered, gate: gate)],
            "two": [.init(lease: try CoordinatorFixtureLease("two"))]
        ])
        fixture.preview.focus("one")
        let request = try XCTUnwrap(fixture.preview.pendingRequest)
        let preview = Task { await fixture.coordinator.preparePreview(request) }
        await fulfillment(of: [entered], timeout: 2)
        let watched = await fixture.coordinator.watch("two").value
        await gate.release()
        let stale = await preview.value
        XCTAssertTrue(watched)
        XCTAssertFalse(stale)
        XCTAssertEqual(fixture.preparation.current?.channel.id, "two")
        XCTAssertTrue(fixture.preview.isExpanded)
        let closes = await first.closeCalls
        XCTAssertEqual(closes, 1)
        await fixture.preparation.close()
    }

    func testCancelledPreviewDoesNotDiscardNewFocusSettlingRequest() async throws {
        let entered = expectation(description: "Older preview opens")
        let gate = CoordinatorFixtureGate()
        let fixture = CoordinatorFixture(replies: [
            "one": [.init(lease: try CoordinatorFixtureLease("one"), entered: entered, gate: gate)],
            "two": [.init(lease: try CoordinatorFixtureLease("two"))]
        ])
        fixture.preview.focus("one")
        let firstRequest = try XCTUnwrap(fixture.preview.pendingRequest)
        let older = Task { await fixture.coordinator.preparePreview(firstRequest) }
        await fulfillment(of: [entered], timeout: 2)
        fixture.preview.focus("two")
        let latestRequest = try XCTUnwrap(fixture.preview.pendingRequest)
        older.cancel()
        await gate.release()
        let stale = await older.value
        XCTAssertFalse(stale)
        XCTAssertEqual(fixture.preview.pendingRequest, latestRequest)
        let latest = await fixture.coordinator.preparePreview(latestRequest)
        XCTAssertTrue(latest)
        XCTAssertEqual(fixture.preparation.current?.channel.id, "two")
        await fixture.preparation.close()
    }

    func testSameChannelFocusAndPromotionReusePreparedIdentityWithoutRecordingPreview() async throws {
        let fixture = CoordinatorFixture(replies: [
            "one": [.init(lease: try CoordinatorFixtureLease("one"))]
        ])
        fixture.preview.focus("one")
        let request = try XCTUnwrap(fixture.preview.pendingRequest)
        let previewed = await fixture.coordinator.preparePreview(request)
        XCTAssertTrue(previewed)
        let id = try XCTUnwrap(fixture.preparation.current?.id)
        fixture.coordinator.confirmWatching(id)
        XCTAssertTrue(fixture.model.recentChannelIDs.isEmpty)
        fixture.preview.focus("one")
        XCTAssertNil(fixture.preview.pendingRequest)
        let watched = await fixture.coordinator.watch("one").value
        XCTAssertTrue(watched)
        XCTAssertEqual(fixture.preparation.current?.id, id)
        XCTAssertTrue(fixture.model.recentChannelIDs.isEmpty, "Intent alone is not a presented first frame")
        fixture.coordinator.confirmWatching(id)
        XCTAssertEqual(fixture.model.recentChannelIDs, ["one"])
        let opens = await fixture.provider.opens
        XCTAssertEqual(opens, ["one"])
        await fixture.preparation.close()
    }

    func testPreviewOpenFailureIsQuietAndKeepsPreviousFeed() async throws {
        let fixture = CoordinatorFixture(replies: ["one": [.init(error: .tunerUnavailable)]])
        _ = await fixture.coordinator.watch("iptv").value
        fixture.preview.returnToGuide(restoresFocus: false)
        let id = fixture.preparation.current?.id
        fixture.preview.focus("one")
        let request = try XCTUnwrap(fixture.preview.pendingRequest)
        let accepted = await fixture.coordinator.preparePreview(request)
        XCTAssertFalse(accepted)
        XCTAssertNil(fixture.coordinator.watchFailure)
        XCTAssertEqual(fixture.preparation.current?.id, id)
        XCTAssertFalse(fixture.preview.isExpanded)
        await fixture.preparation.close()
    }

    func testReportsAreOrderedEvenWhileFirstReportIsSuspended() async throws {
        let entered = expectation(description: "Started report enters lease")
        let gate = CoordinatorFixtureGate()
        let lease = try CoordinatorFixtureLease("one", reportEntered: entered, reportGate: gate)
        let fixture = CoordinatorFixture(replies: ["one": [.init(lease: lease)]])
        _ = await fixture.coordinator.watch("one").value
        let id = try XCTUnwrap(fixture.preparation.current?.id)
        fixture.coordinator.report(.init(state: .started), for: id)
        await fulfillment(of: [entered], timeout: 2)
        fixture.coordinator.report(.init(state: .playing, positionSeconds: 5), for: id)
        let last = fixture.coordinator.report(.init(state: .paused, positionSeconds: 6), for: id)
        let before = await lease.reports
        XCTAssertEqual(before.map(\.state), [.started])
        await gate.release()
        await last.value
        let reports = await lease.reports
        XCTAssertEqual(reports.map(\.state), [.started, .playing, .paused])
        await fixture.preparation.close()
    }

    func testOldCallbacksCannotReportFailOrRecordNewCurrent() async throws {
        let first = try CoordinatorFixtureLease("one")
        let second = try CoordinatorFixtureLease("two")
        let fixture = CoordinatorFixture(replies: [
            "one": [.init(lease: first)], "two": [.init(lease: second)]
        ])
        _ = await fixture.coordinator.watch("one").value
        let oldID = try XCTUnwrap(fixture.preparation.current?.id)
        _ = await fixture.coordinator.watch("two").value
        let newID = try XCTUnwrap(fixture.preparation.current?.id)
        await fixture.coordinator.report(.init(state: .started), for: oldID).value
        fixture.coordinator.playbackFailed(oldID)
        fixture.coordinator.confirmWatching(oldID)
        XCTAssertEqual(fixture.preparation.current?.id, newID)
        XCTAssertTrue(fixture.model.recentChannelIDs.isEmpty)
        let reports = await second.reports
        XCTAssertTrue(reports.isEmpty)
        fixture.coordinator.confirmWatching(newID)
        XCTAssertEqual(fixture.model.recentChannelIDs, ["two"])
        await fixture.preparation.close()
    }

    func testNewCurrentReportingDoesNotWaitForOldSessionReport() async throws {
        let entered = expectation(description: "Old report is suspended")
        let gate = CoordinatorFixtureGate()
        let first = try CoordinatorFixtureLease("one", reportEntered: entered, reportGate: gate)
        let second = try CoordinatorFixtureLease("two")
        let fixture = CoordinatorFixture(replies: [
            "one": [.init(lease: first)], "two": [.init(lease: second)]
        ])
        _ = await fixture.coordinator.watch("one").value
        let oldID = try XCTUnwrap(fixture.preparation.current?.id)
        let oldReport = fixture.coordinator.report(.init(state: .started), for: oldID)
        await fulfillment(of: [entered], timeout: 2)
        _ = await fixture.coordinator.watch("two").value
        let newID = try XCTUnwrap(fixture.preparation.current?.id)
        let finished = expectation(description: "New report finishes independently")
        let newReport = fixture.coordinator.report(.init(state: .started), for: newID)
        let observed = Task {
            await newReport.value
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 2)
        let reports = await second.reports
        XCTAssertEqual(reports.map(\.state), [.started])
        await gate.release()
        await observed.value
        await oldReport.value
        await fixture.preparation.close()
    }

    func testTerminalCurrentFailurePreservesDifferentPendingTarget() async throws {
        let entered = expectation(description: "Replacement opens")
        let gate = CoordinatorFixtureGate()
        let first = try CoordinatorFixtureLease("one")
        let fixture = CoordinatorFixture(replies: [
            "one": [.init(lease: first)],
            "two": [.init(lease: try CoordinatorFixtureLease("two"), entered: entered, gate: gate)]
        ])
        _ = await fixture.coordinator.watch("one").value
        let oldID = try XCTUnwrap(fixture.preparation.current?.id)
        let replacement = fixture.coordinator.watch("two")
        await fulfillment(of: [entered], timeout: 2)
        fixture.coordinator.playbackFailed(oldID)
        XCTAssertNil(fixture.preparation.current)
        XCTAssertEqual(fixture.preparation.preparingChannelID, "two")
        XCTAssertEqual(fixture.coordinator.pendingWatchChannelID, "two")
        XCTAssertTrue(fixture.preview.isExpanded)
        XCTAssertNil(fixture.coordinator.watchFailure)
        await gate.release()
        let accepted = await replacement.value
        XCTAssertTrue(accepted)
        XCTAssertEqual(fixture.preparation.current?.channel.id, "two")
        XCTAssertTrue(fixture.preview.isExpanded)
        await fixture.preparation.close()
        let closes = await first.closeCalls
        XCTAssertEqual(closes, 1)
    }

    func testFailedCurrentIsNotReusedWhenSameChannelIsChosenAgain() async throws {
        let first = try CoordinatorFixtureLease("one")
        let second = try CoordinatorFixtureLease("one")
        let fixture = CoordinatorFixture(replies: ["one": [.init(lease: first), .init(lease: second)]])
        _ = await fixture.coordinator.watch("one").value
        let oldID = try XCTUnwrap(fixture.preparation.current?.id)
        fixture.coordinator.playbackFailed(oldID)
        XCTAssertNil(fixture.preparation.current)
        XCTAssertFalse(fixture.preview.isExpanded)
        _ = await fixture.coordinator.watch("one").value
        XCTAssertNotEqual(fixture.preparation.current?.id, oldID)
        fixture.coordinator.playbackFailed(oldID)
        XCTAssertNotNil(fixture.preparation.current)
        let opens = await fixture.provider.opens
        XCTAssertEqual(opens, ["one", "one"])
        await fixture.preparation.close()
    }

    func testNativePresentationSurvivesZapsButRetiredDismissalCannotAffectReplacement() async throws {
        let fixture = CoordinatorFixture(replies: [
            "one": [.init(lease: try CoordinatorFixtureLease("one"))],
            "two": [
                .init(lease: try CoordinatorFixtureLease("two")),
                .init(lease: try CoordinatorFixtureLease("two"))
            ]
        ])
        _ = await fixture.coordinator.watch("one").value
        let presentationID = fixture.coordinator.presentationID
        _ = await fixture.coordinator.watch("two").value
        XCTAssertTrue(fixture.coordinator.ownsPlayerPresentation(presentationID))
        fixture.coordinator.playbackFailed(try XCTUnwrap(fixture.preparation.current?.id))
        XCTAssertFalse(fixture.coordinator.ownsPlayerPresentation(presentationID))
        _ = await fixture.coordinator.watch("two").value
        XCTAssertFalse(fixture.coordinator.ownsPlayerPresentation(presentationID))
        XCTAssertTrue(fixture.coordinator.ownsPlayerPresentation(fixture.coordinator.presentationID))
        await fixture.preparation.close()
    }

    func testSourceRevocationStopsIPTVButUnrelatedAccountChangeDoesNot() async throws {
        let fixture = CoordinatorFixture()
        _ = await fixture.coordinator.watch("iptv").value
        let id = fixture.preparation.current?.id
        fixture.scope.authorizationID = "another-server-user"
        fixture.coordinator.validateAuthorization()
        XCTAssertEqual(fixture.preparation.current?.id, id)
        fixture.scope.enabledSources.remove("playlist")
        fixture.coordinator.validateAuthorization()
        XCTAssertNil(fixture.preparation.current)
        XCTAssertNil(fixture.model.playingChannelID)
        XCTAssertFalse(fixture.preview.isExpanded)
        await fixture.preparation.close()
    }

    func testProfileRevocationStopsIPTVWithoutDependingOnServerAccounts() async throws {
        let fixture = CoordinatorFixture()
        _ = await fixture.coordinator.watch("iptv").value
        fixture.scope.profileID = "other-profile"
        fixture.coordinator.validateAuthorization()
        XCTAssertNil(fixture.preparation.current)
        XCTAssertFalse(fixture.preview.isExpanded)
        await fixture.preparation.close()
    }

    func testSourceRevocationCancelsWatchButKeepsUnrelatedIPTV() async throws {
        let entered = expectation(description: "Watch opens")
        let gate = CoordinatorFixtureGate()
        let lease = try CoordinatorFixtureLease("one")
        let fixture = CoordinatorFixture(replies: [
            "one": [.init(lease: lease, entered: entered, gate: gate)]
        ])
        _ = await fixture.coordinator.watch("iptv").value
        let id = fixture.preparation.current?.id
        let watch = fixture.coordinator.watch("one")
        await fulfillment(of: [entered], timeout: 2)
        fixture.scope.enabledSources.remove("server")
        fixture.coordinator.validateAuthorization()
        XCTAssertNil(fixture.coordinator.pendingWatchChannelID)
        XCTAssertEqual(fixture.preparation.current?.id, id)
        await gate.release()
        let accepted = await watch.value
        XCTAssertFalse(accepted)
        XCTAssertEqual(fixture.preparation.current?.id, id)
        let closes = await lease.closeCalls
        XCTAssertEqual(closes, 1)
        await fixture.preparation.close()
    }

    func testBackgroundStopsCurrentAndFencesLateWatch() async throws {
        let entered = expectation(description: "Watch opens")
        let gate = CoordinatorFixtureGate()
        let lease = try CoordinatorFixtureLease("one")
        let fixture = CoordinatorFixture(replies: [
            "one": [.init(lease: lease, entered: entered, gate: gate)]
        ])
        _ = await fixture.coordinator.watch("iptv").value
        let watch = fixture.coordinator.watch("one")
        await fulfillment(of: [entered], timeout: 2)
        fixture.coordinator.setActive(false)
        XCTAssertNil(fixture.preparation.current)
        XCTAssertFalse(fixture.preview.isExpanded)
        fixture.coordinator.setActive(true)
        await gate.release()
        let accepted = await watch.value
        XCTAssertFalse(accepted)
        XCTAssertNil(fixture.preparation.current)
        XCTAssertFalse(fixture.preview.isExpanded)
        let closes = await lease.closeCalls
        XCTAssertEqual(closes, 1)
        await fixture.preparation.close()
    }

    func testInactiveCancelsWatchWithoutReleasingCurrentOrResurrectingFocusedTarget() async throws {
        let entered = expectation(description: "Watch is opening before inactivity")
        let gate = CoordinatorFixtureGate()
        defer { Task { await gate.release() } }
        let cancelled = try CoordinatorFixtureLease("one")
        let replacement = try CoordinatorFixtureLease("one")
        let fixture = CoordinatorFixture(replies: [
            "one": [.init(lease: cancelled, entered: entered, gate: gate), .init(lease: replacement)]
        ])
        _ = await fixture.coordinator.watch("iptv").value
        fixture.preview.returnToGuide(restoresFocus: false)
        fixture.coordinator.focus("one")
        let currentID = fixture.preparation.current?.id
        let acceptedWatchID = fixture.coordinator.acceptedWatchID
        let watch = fixture.coordinator.watch("one")
        await fulfillment(of: [entered], timeout: 2)
        fixture.coordinator.setInteractionActive(false)
        fixture.coordinator.validateAuthorization()
        XCTAssertTrue(fixture.coordinator.isActive)
        XCTAssertFalse(fixture.coordinator.canAutoPreview)
        XCTAssertNil(fixture.coordinator.pendingWatchChannelID)
        XCTAssertEqual(fixture.preparation.current?.id, currentID)
        XCTAssertFalse(fixture.preview.isExpanded)
        let inactiveWatch = await fixture.coordinator.watch("one").value
        XCTAssertFalse(inactiveWatch)
        fixture.coordinator.setInteractionActive(true)
        fixture.coordinator.focus("one")
        fixture.preview.setBrowsingActive(true)
        let resumedRequest = try XCTUnwrap(fixture.preview.pendingRequest)
        let resumedPreview = await fixture.coordinator.preparePreview(resumedRequest)
        XCTAssertFalse(resumedPreview)
        await gate.release()
        let accepted = await watch.value
        XCTAssertFalse(accepted)
        XCTAssertFalse(fixture.preview.isExpanded)
        XCTAssertEqual(fixture.preparation.current?.id, currentID)
        XCTAssertEqual(fixture.coordinator.acceptedWatchID, acceptedWatchID)
        let opensBeforeNewIntent = await fixture.provider.opens
        let closes = await cancelled.closeCalls
        XCTAssertEqual(opensBeforeNewIntent, ["one"])
        XCTAssertEqual(closes, 1)
        let deliberateWatch = await fixture.coordinator.watch("one").value
        XCTAssertTrue(deliberateWatch)
        XCTAssertNotEqual(fixture.coordinator.acceptedWatchID, acceptedWatchID)
        await fixture.preparation.close()
    }

    func testInactiveCancelsOwnedPreviewEvenIfCallerTaskRemainsAlive() async throws {
        let entered = expectation(description: "Preview is opening before inactivity")
        let gate = CoordinatorFixtureGate()
        defer { Task { await gate.release() } }
        let cancelled = try CoordinatorFixtureLease("one")
        let fixture = CoordinatorFixture(replies: [
            "one": [.init(lease: cancelled, entered: entered, gate: gate)]
        ])
        _ = await fixture.coordinator.watch("iptv").value
        fixture.preview.returnToGuide(restoresFocus: false)
        fixture.coordinator.focus("one")
        let request = try XCTUnwrap(fixture.preview.pendingRequest)
        let currentID = fixture.preparation.current?.id
        let preview = Task { await fixture.coordinator.preparePreview(request) }
        await fulfillment(of: [entered], timeout: 2)
        fixture.coordinator.setInteractionActive(false)
        fixture.coordinator.setInteractionActive(true)
        await gate.release()
        let accepted = await preview.value
        XCTAssertFalse(accepted)
        XCTAssertEqual(fixture.preparation.current?.id, currentID)
        XCTAssertFalse(fixture.preview.isExpanded)
        XCTAssertFalse(fixture.coordinator.canAutoPreview)
        fixture.coordinator.focus("one")
        fixture.preview.setBrowsingActive(true)
        let sameChannel = try XCTUnwrap(fixture.preview.pendingRequest)
        let restarted = await fixture.coordinator.preparePreview(sameChannel)
        XCTAssertFalse(restarted)
        let opens = await fixture.provider.opens
        let closes = await cancelled.closeCalls
        XCTAssertEqual(opens, ["one"])
        XCTAssertEqual(closes, 1)
        await fixture.preparation.close()
    }

    func testInactiveRetainsCurrentLeaseAndPausedReportsButBackgroundClosesIt() async throws {
        let lease = try CoordinatorFixtureLease("one")
        let fixture = CoordinatorFixture(replies: ["one": [.init(lease: lease)]])
        _ = await fixture.coordinator.watch("one").value
        let id = try XCTUnwrap(fixture.preparation.current?.id)
        let presentationID = fixture.coordinator.presentationID
        fixture.coordinator.setInteractionActive(false)
        fixture.coordinator.validateAuthorization()
        await fixture.coordinator.report(.init(state: .paused, positionSeconds: 12), for: id).value
        XCTAssertEqual(fixture.preparation.current?.id, id)
        XCTAssertEqual(fixture.coordinator.presentationID, presentationID)
        XCTAssertTrue(fixture.preview.isExpanded)
        let reports = await lease.reports
        let inactiveCloses = await lease.closeCalls
        XCTAssertEqual(reports.map(\.state), [.paused])
        XCTAssertEqual(inactiveCloses, 0)
        let rejected = await fixture.coordinator.watch("two").value
        XCTAssertFalse(rejected)
        XCTAssertEqual(fixture.preparation.current?.id, id)
        fixture.coordinator.setActive(false)
        XCTAssertNil(fixture.preparation.current)
        XCTAssertFalse(fixture.preview.isExpanded)
        await fixture.preparation.close()
        let backgroundCloses = await lease.closeCalls
        let opens = await fixture.provider.opens
        XCTAssertEqual(backgroundCloses, 1)
        XCTAssertEqual(opens, ["one"])
    }

    func testTunerRecoveryRequiresExplicitConsentAndAwaitsCurrentCleanup() async throws {
        let closing = expectation(description: "Old tuner starts closing")
        let closeGate = CoordinatorFixtureGate()
        let first = try CoordinatorFixtureLease("one", closeEntered: closing, closeGate: closeGate)
        let fixture = CoordinatorFixture(replies: [
            "one": [.init(lease: first)],
            "two": [.init(error: .tunerUnavailable), .init(lease: try CoordinatorFixtureLease("two"))]
        ])
        _ = await fixture.coordinator.watch("one").value
        let oldID = try XCTUnwrap(fixture.preparation.current?.id)
        let failed = await fixture.coordinator.watch("two").value
        XCTAssertFalse(failed)
        let failure = try XCTUnwrap(fixture.coordinator.watchFailure)
        XCTAssertEqual(failure.currentToStop, oldID)
        XCTAssertEqual(fixture.preparation.current?.id, oldID)
        let before = await first.closeCalls
        XCTAssertEqual(before, 0)
        // SwiftUI can dismiss an alert before delivering its selected action.
        fixture.coordinator.dismissFailure()
        let retry = fixture.coordinator.stopCurrentAndRetry(failure)
        await fulfillment(of: [closing], timeout: 2)
        XCTAssertNil(fixture.preparation.current)
        let beforeCleanup = await fixture.provider.opens
        XCTAssertEqual(beforeCleanup, ["one", "two"])
        await closeGate.release()
        let accepted = await retry.value
        XCTAssertTrue(accepted)
        XCTAssertEqual(fixture.preparation.current?.channel.id, "two")
        let afterCleanup = await fixture.provider.opens
        XCTAssertEqual(afterCleanup, ["one", "two", "two"])
        await fixture.preparation.close()
    }

    func testTunerFailureNeverOffersToInterruptUnrelatedIPTV() async throws {
        let fixture = CoordinatorFixture(replies: ["one": [.init(error: .tunerUnavailable)]])
        _ = await fixture.coordinator.watch("iptv").value
        let oldID = fixture.preparation.current?.id
        _ = await fixture.coordinator.watch("one").value
        let failure = try XCTUnwrap(fixture.coordinator.watchFailure)
        XCTAssertNil(failure.currentToStop)
        let retried = await fixture.coordinator.stopCurrentAndRetry(failure).value
        XCTAssertFalse(retried)
        XCTAssertEqual(fixture.preparation.current?.id, oldID)
        await fixture.preparation.close()
    }

    func testNewWatchDuringRecoveryCleanupFencesTheOldRetry() async throws {
        let closing = expectation(description: "Consented cleanup enters")
        let gate = CoordinatorFixtureGate()
        let old = try CoordinatorFixtureLease("one", closeEntered: closing, closeGate: gate)
        let fixture = CoordinatorFixture(replies: [
            "one": [.init(lease: old)], "two": [.init(error: .tunerUnavailable)]
        ])
        _ = await fixture.coordinator.watch("one").value
        _ = await fixture.coordinator.watch("two").value
        let failure = try XCTUnwrap(fixture.coordinator.watchFailure)
        let retry = fixture.coordinator.stopCurrentAndRetry(failure)
        await fulfillment(of: [closing], timeout: 2)
        let watched = await fixture.coordinator.watch("iptv").value
        let newID = fixture.preparation.current?.id
        await gate.release()
        let retried = await retry.value
        XCTAssertTrue(watched)
        XCTAssertFalse(retried)
        XCTAssertEqual(fixture.preparation.current?.id, newID)
        XCTAssertEqual(fixture.model.playingChannelID, "iptv")
        let opens = await fixture.provider.opens
        XCTAssertEqual(opens, ["one", "two"])
        await fixture.preparation.close()
    }

    func testCancelledRecoveryBlocksResumedPreviewUntilCleanupAndFreshChannelFocus() async throws {
        let closing = expectation(description: "Consented cleanup is suspended")
        let gate = CoordinatorFixtureGate()
        defer { Task { await gate.release() } }
        let old = try CoordinatorFixtureLease("one", closeEntered: closing, closeGate: gate)
        let fixture = CoordinatorFixture(replies: [
            "one": [.init(lease: old)],
            "two": [.init(error: .tunerUnavailable), .init(lease: try CoordinatorFixtureLease("two"))]
        ])
        _ = await fixture.coordinator.watch("one").value
        fixture.preview.returnToGuide(restoresFocus: false)
        fixture.coordinator.focus("two")
        _ = await fixture.coordinator.watch("two").value
        let failure = try XCTUnwrap(fixture.coordinator.watchFailure)
        fixture.preview.setBrowsingActive(false)
        let retry = fixture.coordinator.stopCurrentAndRetry(failure)
        await fulfillment(of: [closing], timeout: 2)
        fixture.coordinator.cancelWatch()
        XCTAssertNil(fixture.coordinator.pendingWatchChannelID)
        XCTAssertTrue(fixture.coordinator.isCleaningUp)
        XCTAssertFalse(fixture.coordinator.canAutoPreview)

        // Simulate the root re-enabling browsing after pendingWatch becomes nil.
        // A request past its debounce must still be refused by the coordinator.
        fixture.preview.setBrowsingActive(true)
        let cancelledFocus = try XCTUnwrap(fixture.preview.pendingRequest)
        let duringCleanup = await fixture.coordinator.preparePreview(cancelledFocus)
        XCTAssertFalse(duringCleanup)
        let beforeCleanup = await fixture.provider.opens
        XCTAssertEqual(beforeCleanup, ["one", "two"])
        await gate.release()
        let retried = await retry.value
        XCTAssertFalse(retried)
        XCTAssertFalse(fixture.coordinator.isCleaningUp)
        XCTAssertFalse(fixture.coordinator.canAutoPreview)
        fixture.coordinator.focus("two")
        let unchangedProgrammeFocus = await fixture.coordinator.preparePreview(cancelledFocus)
        XCTAssertFalse(unchangedProgrammeFocus)
        XCTAssertFalse(fixture.coordinator.canAutoPreview)

        fixture.coordinator.focus("iptv")
        fixture.coordinator.focus("two")
        XCTAssertTrue(fixture.coordinator.canAutoPreview)
        let freshFocus = try XCTUnwrap(fixture.preview.pendingRequest)
        let previewed = await fixture.coordinator.preparePreview(freshFocus)
        XCTAssertTrue(previewed)
        XCTAssertFalse(fixture.preview.isExpanded)
        XCTAssertEqual(fixture.preparation.current?.channel.id, "two")
        let opens = await fixture.provider.opens
        XCTAssertEqual(opens, ["one", "two", "two"])
        await fixture.preparation.close()
    }

    func testFreshFocusStillCannotPreviewWhileCancelledCleanupIsOutstanding() async throws {
        let closing = expectation(description: "Cleanup remains outstanding")
        let gate = CoordinatorFixtureGate()
        defer { Task { await gate.release() } }
        let old = try CoordinatorFixtureLease("one", closeEntered: closing, closeGate: gate)
        let fixture = CoordinatorFixture(replies: [
            "one": [.init(lease: old)], "two": [.init(error: .tunerUnavailable)]
        ])
        _ = await fixture.coordinator.watch("one").value
        fixture.preview.returnToGuide(restoresFocus: false)
        fixture.coordinator.focus("two")
        _ = await fixture.coordinator.watch("two").value
        let retry = fixture.coordinator.stopCurrentAndRetry(try XCTUnwrap(fixture.coordinator.watchFailure))
        await fulfillment(of: [closing], timeout: 2)
        fixture.coordinator.cancelWatch()
        fixture.coordinator.focus("iptv")
        fixture.preview.setBrowsingActive(true)
        let freshFocus = try XCTUnwrap(fixture.preview.pendingRequest)
        XCTAssertTrue(fixture.coordinator.isCleaningUp)
        XCTAssertFalse(fixture.coordinator.canAutoPreview)
        let blocked = await fixture.coordinator.preparePreview(freshFocus)
        XCTAssertFalse(blocked)
        XCTAssertNil(fixture.preparation.current)
        await gate.release()
        _ = await retry.value
        XCTAssertTrue(fixture.coordinator.canAutoPreview)
        let afterCleanup = await fixture.coordinator.preparePreview(freshFocus)
        XCTAssertTrue(afterCleanup)
        XCTAssertEqual(fixture.preparation.current?.channel.id, "iptv")
        await fixture.preparation.close()
    }

    func testStaleTunerRecoveryCannotStopNewCurrent() async throws {
        let fixture = CoordinatorFixture(replies: [
            "one": [.init(lease: try CoordinatorFixtureLease("one"))],
            "two": [.init(error: .tunerUnavailable)]
        ])
        _ = await fixture.coordinator.watch("one").value
        _ = await fixture.coordinator.watch("two").value
        let failure = try XCTUnwrap(fixture.coordinator.watchFailure)
        _ = await fixture.coordinator.watch("iptv").value
        let newID = fixture.preparation.current?.id
        let retried = await fixture.coordinator.stopCurrentAndRetry(failure).value
        XCTAssertFalse(retried)
        XCTAssertEqual(fixture.preparation.current?.id, newID)
        await fixture.preparation.close()
    }

    func testGuideOnlySkipsFocusOpenAndExplainsExplicitWatchWithoutOpening() async throws {
        let fixture = CoordinatorFixture()
        fixture.scope.guideOnly.insert("one")
        fixture.preview.focus("one")
        let request = try XCTUnwrap(fixture.preview.pendingRequest)
        let previewed = await fixture.coordinator.preparePreview(request)
        XCTAssertFalse(previewed)
        XCTAssertNil(fixture.coordinator.watchFailure)
        let watched = await fixture.coordinator.watch("one").value
        XCTAssertFalse(watched)
        XCTAssertEqual(fixture.coordinator.watchFailure?.isGuideOnly, true)
        let opens = await fixture.provider.opens
        XCTAssertTrue(opens.isEmpty)
        await fixture.preparation.close()
    }

    func testCatalogAuthorizationIgnoresFiltersButDetectsSourceEditsBeforeReload() async throws {
        let playlist = LiveTVPlaylistSource(
            id: "playlist", name: "Fixture", playlistURL: URL(string: "https://fixture.invalid/list.m3u")!
        )
        let configuration = LiveTVSourcesConfiguration(playlists: [playlist])
        let model = LiveTVPrototypeModel(channels: [])
        let imports = LiveTVPrototypeImportModel(configuration: configuration, loader: CoordinatorCatalogLoader())
        await imports.reload(into: model)
        let channel = try XCTUnwrap(model.channels.first)
        model.query = "not in this catalog"
        XCTAssertTrue(model.visibleChannels.isEmpty)
        XCTAssertTrue(LiveTVPlaybackCatalogAuthorization.allows(
            channel, reference: nil, model: model, imports: imports, configuration: configuration
        ))
        var disabled = configuration
        disabled.playlists[0].isEnabled = false
        XCTAssertFalse(LiveTVPlaybackCatalogAuthorization.allows(
            channel, reference: nil, model: model, imports: imports, configuration: disabled
        ))
        var edited = configuration
        edited.playlists[0].playlistURL = URL(string: "https://fixture.invalid/other.m3u")!
        XCTAssertFalse(LiveTVPlaybackCatalogAuthorization.allows(
            channel, reference: nil, model: model, imports: imports, configuration: edited
        ))
        var renamed = configuration
        renamed.playlists[0].name = "A different name"
        XCTAssertTrue(LiveTVPlaybackCatalogAuthorization.allows(
            channel, reference: nil, model: model, imports: imports, configuration: renamed
        ))
    }
}

@MainActor
private final class CoordinatorFixture {
    let model: LiveTVPrototypeModel
    let preview: LiveTVPreviewController
    let preparation: LiveTVPlaybackPreparation
    let coordinator: LiveTVPlaybackCoordinator
    let scope = CoordinatorFixtureScope()
    let provider: CoordinatorFixtureProvider

    init(replies: [String: [CoordinatorFixtureProvider.Reply]] = [:]) {
        let provider = CoordinatorFixtureProvider(replies)
        self.provider = provider
        let channels = ["iptv", "one", "two"].enumerated().map { index, id in
            LiveTVPrototypeChannel(
                id: id, number: index + 1, name: id, category: "Fixture", symbol: "tv",
                accent: 0, source: id == "iptv" ? .iptv : .jellyfin, tagline: "",
                streamURL: id == "iptv" ? URL(string: "https://fixture.invalid/public.m3u8") : nil,
                configuredSourceID: id == "iptv" ? "playlist" : "server"
            )
        }
        model = LiveTVPrototypeModel(channels: channels)
        preview = LiveTVPreviewController(model: model)
        let scope = scope
        let profile = scope.profileID
        let model = model
        preparation = LiveTVPlaybackPreparation(serverProviderResolver: { id in
            guard id == "account", scope.profileID == profile else { return nil }
            return LiveTVAuthorizedServerProvider(
                accountID: id, authorizationID: scope.authorizationID, kind: .jellyfin, provider: provider
            )
        })
        coordinator = LiveTVPlaybackCoordinator(
            model: model, preview: preview, preparation: preparation,
            reference: { id in
                guard id != "iptv" else { return nil }
                return LiveTVServerChannelReference(
                    sourceID: "server", accountID: "account",
                    authorizationID: scope.authorizationID, channelID: id
                )
            },
            isAuthorized: { channel, _ in
                scope.profileID == profile && model.channel(id: channel.id) != nil
                    && scope.enabledSources.contains(channel.configuredSourceID ?? "")
            },
            isGuideOnly: { scope.guideOnly.contains($0) }
        )
    }
}

@MainActor
private final class CoordinatorFixtureScope {
    var profileID = "profile"
    var authorizationID = "server-user"
    var enabledSources: Set<String> = ["playlist", "server"]
    var guideOnly: Set<String> = []
}

private actor CoordinatorFixtureGate {
    private var isReleased = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isReleased else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        isReleased = true
        let waiters = waiters
        self.waiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor CoordinatorFixtureLease: LiveTVStreamLease {
    nonisolated let playbackSource: PlaybackSource
    let reportEntered: XCTestExpectation?
    let reportGate: CoordinatorFixtureGate?
    let closeEntered: XCTestExpectation?
    let closeGate: CoordinatorFixtureGate?
    private(set) var reports: [LiveTVPlaybackUpdate] = []
    private(set) var closeCalls = 0

    init(
        _ channel: String,
        reportEntered: XCTestExpectation? = nil,
        reportGate: CoordinatorFixtureGate? = nil,
        closeEntered: XCTestExpectation? = nil,
        closeGate: CoordinatorFixtureGate? = nil
    ) throws {
        playbackSource = .publicURL(try SecretFreeURLSource(
            url: URL(string: "https://fixture.invalid/\(channel).m3u8")!
        ))
        self.reportEntered = reportEntered
        self.reportGate = reportGate
        self.closeEntered = closeEntered
        self.closeGate = closeGate
    }

    func report(_ update: LiveTVPlaybackUpdate) async {
        reports.append(update)
        if update.state == .started {
            reportEntered?.fulfill()
            await reportGate?.wait()
        }
    }

    func close() async {
        closeCalls += 1
        closeEntered?.fulfill()
        await closeGate?.wait()
    }
}

private actor CoordinatorFixtureProvider: ServerLiveTVProviding {
    struct Reply: Sendable {
        var lease: CoordinatorFixtureLease?
        var error: ServerLiveTVError?
        var entered: XCTestExpectation?
        var gate: CoordinatorFixtureGate?
    }

    private var replies: [String: [Reply]]
    private(set) var opens: [String] = []

    init(_ replies: [String: [Reply]]) { self.replies = replies }
    func liveTVAvailability() -> ServerLiveTVAvailability {
        .init(status: .available, channelCount: replies.count)
    }
    func liveTVChannels() -> [ServerLiveTVChannel] { [] }
    func liveTVGuide(channelIDs: [String], from: Date, to: Date) -> [ServerLiveTVProgramme] { [] }

    func openLiveTVChannel(id: String) async throws -> any LiveTVStreamLease {
        opens.append(id)
        guard var responses = replies[id], !responses.isEmpty else {
            XCTFail("Unexpected fixture open")
            throw ServerLiveTVError.invalidChannel
        }
        let response = responses.removeFirst()
        replies[id] = responses
        response.entered?.fulfill()
        await response.gate?.wait()
        if let error = response.error { throw error }
        guard let lease = response.lease else { throw ServerLiveTVError.noCompatibleStream }
        return lease
    }
}

private struct CoordinatorCatalogLoader: LiveTVSourceLoading {
    func loadPlaylist(from url: URL) async throws -> LiveTVPlaylistImport {
        try LiveTVPlaylistParser(baseURL: url).parse("""
        #EXTM3U
        #EXTINF:-1 tvg-id="fixture",Fixture channel
        https://fixture.invalid/channel.m3u8
        """)
    }

    func loadGuide(
        from url: URL, channels: [LiveTVPrototypeChannel], now: Date
    ) async throws -> LiveTVGuideImport {
        XCTFail("Fixture has no guide source")
        throw LiveTVSourceImportError.invalidGuide
    }
}
