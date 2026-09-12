#if DEBUG && canImport(AVFoundation)
import CoreModels
import Foundation
import TraktService
import XCTest
#if canImport(UIKit)
import UIKit
#endif
#if os(iOS)
import AVKit
#endif
@testable import FeaturePlayback

@MainActor
final class LibraryLiveChannelEngineTests: XCTestCase {
    private let streamA = LiveChannelInput.stream(
        url: URL(string: "https://example.invalid/a.m3u8")!, httpHeaders: ["X-Fixture": "a"]
    )
    private let streamB = LiveChannelInput.stream(
        url: URL(string: "https://example.invalid/b.m3u8")!, httpHeaders: ["X-Fixture": "b"]
    )

    private func settle(
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        for _ in 0..<2_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Adapter did not reach its expected state", file: file, line: line)
    }

    private func assertCancelled(
        _ task: Task<Void, Error>, file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            try await task.value
            XCTFail("Superseded load should throw cancellation", file: file, line: line)
        } catch {
            XCTAssertTrue(error is CancellationError, file: file, line: line)
        }
    }

    func testStreamLibraryStreamReuseDecoderAndPreserveStreamHeaders() async throws {
        let fixture = try UniversalLiveFixture()
        let adapter = fixture.adapter
        try await adapter.loadChannel(streamA)
        try await adapter.loadChannel(fixture.inputA)
        let session = try XCTUnwrap(adapter.librarySession)
        XCTAssertTrue(session.engine === fixture.decoder)
        XCTAssertEqual(session.state, .playing)
        try await adapter.loadChannel(streamB)
        XCTAssertNil(adapter.librarySession)
        XCTAssertEqual(session.state, .idle)
        XCTAssertEqual(adapter.currentInput, streamB)
        XCTAssertEqual(fixture.decoder.loadedSources, ["stream:a.m3u8", "vod:first", "stream:b.m3u8"])
        XCTAssertEqual(fixture.decoder.headers, [["X-Fixture": "a"], ["X-Fixture": "b"]])
        XCTAssertEqual(fixture.factoryEngines, [ObjectIdentifier(fixture.decoder)])
        XCTAssertEqual(fixture.factoryAuthorizations, ["profile:server:user"])
        adapter.stop()
        await adapter.drainTransport()
    }

    func testSameChannelWithNewAuthorizationReloadsUsingSuppliedGeneration() async throws {
        let fixture = try UniversalLiveFixture()
        let previousInput = fixture.inputA
        try await fixture.adapter.loadChannel(streamA)
        try await fixture.adapter.loadChannel(previousInput)
        let previousSession = try XCTUnwrap(fixture.adapter.librarySession)
        fixture.authorization = "replacement-credential-generation"
        let replacementInput = fixture.inputA
        XCTAssertNotEqual(previousInput, replacementInput)
        try await fixture.adapter.loadChannel(replacementInput)
        XCTAssertEqual(fixture.adapter.currentInput, replacementInput)
        XCTAssertEqual(previousSession.state, .idle)
        XCTAssertFalse(previousSession === fixture.adapter.librarySession)
        XCTAssertEqual(fixture.factoryAuthorizations, ["profile:server:user", "replacement-credential-generation"])
        XCTAssertEqual(fixture.factoryEngines, Array(repeating: ObjectIdentifier(fixture.decoder), count: 2))
        XCTAssertEqual(fixture.decoder.loadedSources, ["stream:a.m3u8", "vod:first", "vod:first"])
        fixture.adapter.stop()
        await fixture.adapter.drainTransport()
    }

    func testStaleAuthorizationReachesFactoryAndFailsBeforeProviderResolution() async throws {
        let fixture = try UniversalLiveFixture()
        let staleInput = fixture.inputA
        fixture.authorization = "replacement-credential-generation"
        var failures: [AppError] = []
        fixture.adapter.onFailure = { failures.append($0) }
        do {
            try await fixture.adapter.loadChannel(staleInput)
            XCTFail("Stale prepared authorization must not tune under new credentials")
        } catch {
            XCTAssertEqual(error as? LibraryChannelError, .authorizationChanged)
        }
        XCTAssertEqual(fixture.factoryAuthorizations, ["profile:server:user"])
        XCTAssertTrue(fixture.factoryEngines.isEmpty)
        XCTAssertTrue(fixture.resolvedItems.isEmpty)
        XCTAssertTrue(fixture.decoder.loadedSources.isEmpty)
        XCTAssertTrue(failures.isEmpty)
        XCTAssertEqual(fixture.adapter.liveSnapshot.phase, .failed)
        fixture.adapter.stop()
        await fixture.adapter.drainTransport()
    }

    func testEmptyAuthorizationIsRejectedBeforeInvokingFactory() async throws {
        let fixture = try UniversalLiveFixture()
        do {
            try await fixture.adapter.loadChannel(.libraryChannel(id: fixture.channelA, authorizationID: ""))
            XCTFail("Empty authorization must fail before provider work")
        } catch {
            XCTAssertEqual(error as? LibraryChannelError, .authorizationChanged)
        }
        XCTAssertTrue(fixture.factoryAuthorizations.isEmpty)
        XCTAssertTrue(fixture.factoryEngines.isEmpty)
        XCTAssertTrue(fixture.resolvedItems.isEmpty)
        XCTAssertTrue(fixture.decoder.loadedSources.isEmpty)
        XCTAssertEqual(fixture.adapter.liveSnapshot.phase, .failed)
        fixture.adapter.stop()
        await fixture.adapter.drainTransport()
    }

    func testLibraryAToBReusesDecoderButOwnsDistinctScheduledSessions() async throws {
        let fixture = try UniversalLiveFixture()
        try await fixture.adapter.loadChannel(fixture.inputA)
        let first = try XCTUnwrap(fixture.adapter.librarySession)
        try await fixture.adapter.loadChannel(fixture.inputB)
        let second = try XCTUnwrap(fixture.adapter.librarySession)
        XCTAssertFalse(first === second)
        XCTAssertEqual(first.state, .idle)
        XCTAssertEqual(second.channelID, fixture.channelB)
        XCTAssertTrue(second.engine === first.engine)
        XCTAssertEqual(fixture.factoryEngines, Array(repeating: ObjectIdentifier(fixture.decoder), count: 2))
        fixture.adapter.stop()
        await fixture.adapter.drainTransport()
    }

    func testRetryingSameStampedLibraryInputPreservesSessionAndDelayedCursor() async throws {
        let fixture = try UniversalLiveFixture()
        fixture.advanceClock(20)
        try await fixture.adapter.loadChannel(fixture.inputA)
        let session = try XCTUnwrap(fixture.adapter.librarySession)
        fixture.adapter.pause()
        fixture.advanceClock(10)
        fixture.adapter.play()
        try await fixture.adapter.loadChannel(fixture.inputA)
        XCTAssertTrue(session === fixture.adapter.librarySession)
        XCTAssertEqual(fixture.factoryEngines.count, 1)
        XCTAssertTrue(session.isDelayed)
        XCTAssertEqual(fixture.decoder.currentTime, 20, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(fixture.adapter.liveSnapshot.behindLiveSeconds), 10, accuracy: 0.001)
        fixture.adapter.stop()
        await fixture.adapter.drainTransport()
    }

    func testTransportCleanupFinishesBeforeNextSourceLoads() async throws {
        let fixture = try UniversalLiveFixture()
        try await fixture.adapter.loadChannel(fixture.inputA)
        let drain = UniversalLiveGate()
        fixture.decoder.drainHook = { await drain.wait() }
        let next = Task { try await fixture.adapter.loadChannel(streamB) }
        await settle { drain.isWaiting }
        XCTAssertEqual(fixture.decoder.loadedSources, ["vod:first"])
        fixture.decoder.drainHook = nil
        drain.open()
        try await next.value
        let completedDrain = try XCTUnwrap(fixture.decoder.events.lastIndex(of: "drained"))
        let nextLoad = try XCTUnwrap(fixture.decoder.events.lastIndex(of: "load:stream:b.m3u8"))
        XCTAssertLessThan(completedDrain, nextLoad)
        fixture.adapter.stop()
        await fixture.adapter.drainTransport()
    }

    func testCancelledLibraryLoadCannotFinishOverReplacementStream() async throws {
        let fixture = try UniversalLiveFixture()
        let load = UniversalLiveGate()
        fixture.decoder.loadHook = { await load.wait() }
        let old = Task {
            try await fixture.adapter.loadChannel(fixture.inputA)
        }
        await settle { load.isWaiting }
        let oldSession = try XCTUnwrap(fixture.adapter.librarySession)
        let oldFailure = fixture.decoder.onFailure
        let oldEnded = fixture.decoder.onEnded
        let next = Task { try await fixture.adapter.loadChannel(streamB) }
        await settle { fixture.adapter.currentInput == streamB }
        XCTAssertEqual(fixture.decoder.loadedSources, ["vod:first"])
        fixture.decoder.loadHook = nil
        load.open()
        await assertCancelled(old)
        try await next.value
        oldFailure?(.notFound)
        oldEnded?()
        XCTAssertEqual(oldSession.state, .idle)
        XCTAssertEqual(fixture.adapter.currentInput, streamB)
        XCTAssertEqual(fixture.decoder.activeSource, "stream:b.m3u8")
        XCTAssertEqual(fixture.adapter.liveSnapshot.phase, .playing)
        XCTAssertEqual(fixture.decoder.loadedSources, ["vod:first", "stream:b.m3u8"])
        fixture.adapter.stop()
        await fixture.adapter.drainTransport()
    }

    func testLateStreamLoadAndCallbacksCannotReplaceLibraryInput() async throws {
        let fixture = try UniversalLiveFixture()
        let load = UniversalLiveGate()
        fixture.decoder.loadHook = { await load.wait() }
        var failures = 0
        var ended = 0
        var progress = 0
        var resets = 0
        fixture.adapter.onFailure = { _ in failures += 1 }
        fixture.adapter.onEnded = { ended += 1 }
        fixture.adapter.onProgress = { progress += 1 }
        fixture.adapter.onLiveSourceReset = { resets += 1 }
        let old = Task { try await fixture.adapter.loadChannel(streamA) }
        await settle { load.isWaiting }
        let lateFailure = fixture.decoder.onFailure
        let lateEnded = fixture.decoder.onEnded
        let lateProgress = fixture.decoder.onProgress
        let lateReset = fixture.decoder.onLiveSourceReset
        let next = Task {
            try await fixture.adapter.loadChannel(fixture.inputB)
        }
        await settle { fixture.adapter.currentInput == fixture.inputB }
        fixture.decoder.loadHook = nil
        load.open()
        await assertCancelled(old)
        try await next.value
        lateFailure?(.notFound)
        lateEnded?()
        lateProgress?()
        lateReset?()
        XCTAssertEqual([failures, ended, progress, resets], [0, 0, 0, 0])
        XCTAssertEqual(fixture.adapter.currentInput, fixture.inputB)
        XCTAssertEqual(fixture.adapter.librarySession?.state, .playing)
        fixture.decoder.onProgress?()
        XCTAssertEqual(progress, 1)
        fixture.adapter.stop()
        await fixture.adapter.drainTransport()
    }

    func testRapidSourceChangesSkipCancelledQueuedLibraryFactory() async throws {
        let fixture = try UniversalLiveFixture()
        let load = UniversalLiveGate()
        fixture.decoder.loadHook = { await load.wait() }
        let first = Task { try await fixture.adapter.loadChannel(streamA) }
        await settle { load.isWaiting }
        let middle = Task {
            try await fixture.adapter.loadChannel(fixture.inputA)
        }
        await settle { fixture.adapter.currentInput == fixture.inputA }
        let last = Task { try await fixture.adapter.loadChannel(streamB) }
        await settle { fixture.adapter.currentInput == streamB }
        fixture.decoder.loadHook = nil
        load.open()
        await assertCancelled(first)
        await assertCancelled(middle)
        try await last.value
        XCTAssertTrue(fixture.factoryEngines.isEmpty)
        XCTAssertEqual(fixture.decoder.loadedSources, ["stream:a.m3u8", "stream:b.m3u8"])
        XCTAssertEqual(fixture.decoder.activeSource, "stream:b.m3u8")
        fixture.adapter.stop()
        await fixture.adapter.drainTransport()
    }

    func testLateForegroundReloadDrainsBeforeNewLibraryLoad() async throws {
        let fixture = try UniversalLiveFixture()
        try await fixture.adapter.loadChannel(streamA)
        let reload = UniversalLiveGate()
        fixture.decoder.reloadHook = { await reload.wait() }
        let foreground = Task { try await fixture.adapter.reloadAfterForeground() }
        await settle { reload.isWaiting }
        let next = Task {
            try await fixture.adapter.loadChannel(fixture.inputB)
        }
        await settle { fixture.adapter.currentInput == fixture.inputB }
        XCTAssertEqual(fixture.decoder.loadedSources, ["stream:a.m3u8"])
        reload.open()
        await assertCancelled(foreground)
        try await next.value
        XCTAssertEqual(fixture.decoder.activeSource, "vod:first")
        XCTAssertEqual(fixture.adapter.librarySession?.state, .playing)
        fixture.adapter.stop()
        await fixture.adapter.drainTransport()
    }

    func testCallerCancellationStopsAndDrainsItsOwnPendingLoad() async throws {
        let fixture = try UniversalLiveFixture()
        let load = UniversalLiveGate()
        fixture.decoder.loadHook = { await load.wait() }
        let tune = Task {
            try await fixture.adapter.loadChannel(fixture.inputA)
        }
        await settle { load.isWaiting }
        tune.cancel()
        await settle { fixture.adapter.currentInput == nil }
        load.open()
        await assertCancelled(tune)
        await fixture.adapter.drainTransport()
        XCTAssertNil(fixture.decoder.activeSource)
        XCTAssertEqual(fixture.decoder.status, .idle)
        XCTAssertNil(fixture.adapter.librarySession)
    }

    func testPauseDuringLibraryLoadSurvivesTuneAndJoin() async throws {
        let fixture = try UniversalLiveFixture()
        let load = UniversalLiveGate()
        fixture.decoder.loadHook = { await load.wait() }
        let tune = Task {
            try await fixture.adapter.loadChannel(fixture.inputA)
        }
        await settle { load.isWaiting }
        fixture.adapter.pause()
        fixture.advanceClock(5)
        fixture.decoder.loadHook = nil
        load.open()
        try await tune.value
        await settle { fixture.decoder.status == .ready }
        XCTAssertTrue(fixture.decoder.isPaused)
        XCTAssertTrue(fixture.adapter.isPaused)
        XCTAssertEqual(fixture.adapter.librarySession?.state, .paused)
        XCTAssertEqual(fixture.adapter.liveSnapshot.phase, .paused)
        fixture.adapter.play()
        XCTAssertFalse(fixture.decoder.isPaused)
        XCTAssertEqual(fixture.adapter.librarySession?.state, .playing)
        fixture.adapter.stop()
        await fixture.adapter.drainTransport()
    }

    func testWatchingIsExplicitAndIndependentOfMutedMultiviewOutput() async throws {
        let fixture = try UniversalLiveFixture()
        fixture.historyToken = UUID()
        try await fixture.adapter.loadChannel(fixture.inputA)
        let session = try XCTUnwrap(fixture.adapter.librarySession)
        session.tick()
        fixture.advancePlayback(seconds: 10)
        XCTAssertEqual(session.secondsWatched, 0)
        fixture.adapter.setWatching(true)
        session.tick()
        fixture.advancePlayback(seconds: 5)
        XCTAssertEqual(session.secondsWatched, 5, accuracy: 0.001)
        fixture.adapter.configureLiveOutput(.init(
            isAudible: false, sharesAudioSession: true, suppressesDisplayMatching: true
        ))
        fixture.advancePlayback(seconds: 5)
        XCTAssertEqual(session.secondsWatched, 10, accuracy: 0.001)
        fixture.adapter.setWatching(false)
        session.tick()
        fixture.advancePlayback(seconds: 10)
        XCTAssertEqual(session.secondsWatched, 10, accuracy: 0.001)
        XCTAssertEqual(fixture.decoder.watchingChanges, [true, false])
        fixture.adapter.stop()
        await fixture.adapter.drainTransport()
        XCTAssertEqual(fixture.ordinaryReports, 0)
        XCTAssertEqual(fixture.completions, 0)
    }

    func testOutputAndCapacityAreForwardedWithoutInferringDecoderLimits() async throws {
        let fixture = try UniversalLiveFixture()
        let policies: [LiveChannelOutputPolicy] = [
            .init(isAudible: false, sharesAudioSession: true, suppressesDisplayMatching: true),
            .init(isAudible: true, sharesAudioSession: true, suppressesDisplayMatching: false)
        ]
        fixture.decoder.supportsConcurrentPlayback = false
        XCTAssertFalse(fixture.adapter.supportsConcurrentPlayback)
        fixture.decoder.supportsConcurrentPlayback = true
        XCTAssertTrue(fixture.adapter.supportsConcurrentPlayback)
        fixture.adapter.configureLiveOutput(policies[0])
        try await fixture.adapter.loadChannel(fixture.inputA)
        fixture.adapter.configureLiveOutput(policies[1])
        try await fixture.adapter.loadChannel(streamA)
        XCTAssertEqual(fixture.decoder.outputPolicies, policies)
        fixture.adapter.stop()
        await fixture.adapter.drainTransport()
        XCTAssertTrue(fixture.decoder.stopPolicies.allSatisfy(\.sharesAudioSession))
        XCTAssertEqual(fixture.decoder.outputPolicies, policies)
    }

    #if canImport(UIKit)
    func testStoppingLibraryPaneLeavesSiblingDecoderAndOutputOwnershipIntact() async throws {
        let first = try UniversalLiveFixture()
        let second = try UniversalLiveFixture()
        let group = LiveChannelOutputGroup()
        let firstID = UUID()
        let secondID = UUID()
        group.register(first.adapter, id: firstID, audible: true)
        group.register(second.adapter, id: secondID, audible: false)
        try await first.adapter.loadChannel(first.inputA)
        try await second.adapter.loadChannel(second.inputB)
        let secondLoads = second.decoder.loadedSources
        let secondStops = second.decoder.stopPolicies.count
        group.unregister(firstID, engine: first.adapter)
        first.adapter.stop()
        await first.adapter.drainTransport()
        XCTAssertEqual(second.decoder.loadedSources, secondLoads)
        XCTAssertEqual(second.decoder.stopPolicies.count, secondStops)
        XCTAssertEqual(second.adapter.liveSnapshot.phase, .playing)
        XCTAssertEqual(first.decoder.stopPolicies.last?.sharesAudioSession, true)
        XCTAssertEqual(first.decoder.stopPolicies.last?.suppressesDisplayMatching, true)
        group.unregister(secondID, engine: second.adapter)
        second.adapter.stop()
        await second.adapter.drainTransport()
        XCTAssertEqual(second.decoder.stopPolicies.last?.sharesAudioSession, false)
    }
    #endif

    func testReadyIsNotAFirstFrameAndLibraryDoesNotExposeVODSeekRange() async throws {
        let fixture = try UniversalLiveFixture()
        fixture.decoder.providesFirstFrame = false
        try await fixture.adapter.loadChannel(fixture.inputA)
        XCTAssertEqual(fixture.adapter.status, .ready)
        XCTAssertFalse(fixture.adapter.liveSnapshot.firstFrameReady)
        XCTAssertNil(fixture.adapter.liveSnapshot.seekableRange)
        fixture.decoder.liveSnapshot.firstFrameReady = true
        XCTAssertTrue(fixture.adapter.liveSnapshot.firstFrameReady)
        let priorSeeks = fixture.decoder.seeks
        await fixture.adapter.seek(to: 80)
        await fixture.adapter.seek(to: 70, kind: .exact)
        XCTAssertEqual(fixture.decoder.seeks, priorSeeks)
        fixture.adapter.pause()
        fixture.advanceClock(12)
        XCTAssertEqual(try XCTUnwrap(fixture.adapter.liveSnapshot.behindLiveSeconds), 12, accuracy: 0.001)
        fixture.adapter.play()
        await fixture.adapter.seekToLiveEdge()
        XCTAssertFalse(try XCTUnwrap(fixture.adapter.librarySession).isDelayed)
        XCTAssertEqual(try XCTUnwrap(fixture.adapter.liveSnapshot.behindLiveSeconds), 0, accuracy: 0.001)
        fixture.adapter.stop()
        await fixture.adapter.drainTransport()
    }

    func testScheduleTransitionKeepsSessionDecoderAndDoesNotRequestRetune() async throws {
        let fixture = try UniversalLiveFixture()
        var resets = 0
        var programmes: [String] = []
        fixture.adapter.onLiveSourceReset = { resets += 1 }
        fixture.adapter.onProgrammeChanged = { [weak fixture] in
            if let itemID = fixture?.adapter.librarySession?.currentSlot?.item.itemID {
                programmes.append(itemID)
            }
        }
        try await fixture.adapter.loadChannel(fixture.inputA)
        let session = try XCTUnwrap(fixture.adapter.librarySession)
        fixture.advanceClock(101)
        session.tick()
        await settle { session.currentSlot?.item.itemID == "second" && session.state == .playing }
        XCTAssertTrue(session === fixture.adapter.librarySession)
        XCTAssertEqual(fixture.factoryEngines.count, 1)
        XCTAssertEqual(fixture.decoder.loadedSources, ["vod:first", "vod:second"])
        XCTAssertEqual(resets, 0)
        XCTAssertEqual(programmes, ["first", "second"])
        fixture.adapter.stop()
        fixture.adapter.onProgrammeChanged = nil
        await fixture.adapter.drainTransport()
    }

    func testOldProgrammeCallbacksCannotPublishIntoNextProgramme() async throws {
        let fixture = try UniversalLiveFixture()
        var callbacks = 0
        fixture.adapter.onTracksChanged = { callbacks += 1 }
        fixture.adapter.onProgress = { callbacks += 1 }
        fixture.adapter.onSubtitleCues = { _ in callbacks += 1 }
        fixture.adapter.onSecondarySubtitleCues = { _ in callbacks += 1 }
        try await fixture.adapter.loadChannel(fixture.inputA)
        let oldTracks = fixture.decoder.onTracksChanged
        let oldProgress = fixture.decoder.onProgress
        let oldCues = fixture.decoder.onSubtitleCues
        let oldSecondaryCues = fixture.decoder.onSecondarySubtitleCues
        let session = try XCTUnwrap(fixture.adapter.librarySession)
        fixture.advanceClock(101)
        session.tick()
        await settle { session.currentSlot?.item.itemID == "second" && session.state == .playing }
        oldTracks?()
        oldProgress?()
        oldCues?([])
        oldSecondaryCues?([])
        XCTAssertEqual(callbacks, 0)
        fixture.decoder.onTracksChanged?()
        fixture.decoder.onProgress?()
        fixture.decoder.onSubtitleCues?([])
        fixture.decoder.onSecondarySubtitleCues?([])
        XCTAssertEqual(callbacks, 4)
        fixture.adapter.stop()
        await fixture.adapter.drainTransport()
    }

    func testProgrammeResetCanStopReentrantlyWithoutStartingDecoder() async throws {
        let fixture = try UniversalLiveFixture()
        fixture.adapter.onProgrammeChanged = { [weak fixture] in fixture?.adapter.stop() }
        do {
            try await fixture.adapter.loadChannel(fixture.inputA)
            XCTFail("Reentrant stop must cancel the tune")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        await fixture.adapter.drainTransport()
        fixture.adapter.onProgrammeChanged = nil
        XCTAssertNil(fixture.adapter.currentInput)
        XCTAssertTrue(fixture.decoder.loadedSources.isEmpty)
        XCTAssertEqual(fixture.decoder.status, .idle)
    }

    func testAuthorizationLossPublishesFatalFailureRatherThanProgrammeGap() async throws {
        let fixture = try UniversalLiveFixture()
        var failures: [AppError] = []
        fixture.adapter.onFailure = { failures.append($0) }
        try await fixture.adapter.loadChannel(fixture.inputA)
        fixture.authorization = nil
        fixture.adapter.librarySession?.tick()
        XCTAssertNil(fixture.adapter.recoverableProgrammeIssue)
        XCTAssertEqual(fixture.adapter.liveSnapshot.phase, .failed)
        XCTAssertEqual(failures, [.unknown(String(localized: LibraryChannelError.authorizationChanged.message))])
        fixture.adapter.stop()
        await fixture.adapter.drainTransport()
    }

    func testMissingAndThrowingFactoriesSurfaceErrorsWithoutLoadingDecoder() async throws {
        let decoder = UniversalLiveDecoder()
        let missing = LibraryLiveChannelEngine(engine: decoder)
        var prematureFailures: [AppError] = []
        missing.onFailure = { prematureFailures.append($0) }
        do {
            try await missing.loadChannel(.libraryChannel(id: UUID(), authorizationID: "authorized"))
            XCTFail("Missing library factory must fail")
        } catch {
            XCTAssertEqual(error as? LiveChannelInputError, .unsupportedSource)
        }
        XCTAssertEqual(missing.liveSnapshot.phase, .failed)
        XCTAssertTrue(prematureFailures.isEmpty)
        XCTAssertTrue(decoder.loadedSources.isEmpty)
        missing.stop()
        await missing.drainTransport()
        let failing = LibraryLiveChannelEngine(engine: decoder) { _, _, _ in
            throw LibraryChannelError.snapshotUnavailable
        }
        failing.onFailure = { prematureFailures.append($0) }
        do {
            try await failing.loadChannel(.libraryChannel(id: UUID(), authorizationID: "authorized"))
            XCTFail("Factory error must reach the caller")
        } catch {
            XCTAssertEqual(error as? LibraryChannelError, .snapshotUnavailable)
        }
        XCTAssertEqual(failing.liveSnapshot.phase, .failed)
        XCTAssertTrue(prematureFailures.isEmpty)
        XCTAssertTrue(decoder.loadedSources.isEmpty)
        failing.stop()
        await failing.drainTransport()
    }

    func testTypedInputFailureCannotBePreemptedByGenericFailureTeardown() async {
        let decoder = UniversalLiveDecoder()
        let adapter = LibraryLiveChannelEngine(engine: decoder)
        var prematureFailures = 0
        adapter.onFailure = { [weak adapter] _ in
            prematureFailures += 1
            adapter?.stop()
        }
        do {
            try await adapter.loadChannel(.libraryChannel(id: UUID(), authorizationID: "authorized"))
            XCTFail("Unsupported typed input must throw its original error")
        } catch {
            XCTAssertEqual(error as? LiveChannelInputError, .unsupportedSource)
        }
        XCTAssertEqual(prematureFailures, 0)
        XCTAssertEqual(adapter.liveSnapshot.phase, .failed)
        adapter.stop()
        await adapter.drainTransport()
    }

    func testUnavailableSessionIsFailedRatherThanFalsePlaying() async throws {
        let fixture = try UniversalLiveFixture()
        fixture.providerAvailable = false
        do {
            try await fixture.adapter.loadChannel(fixture.inputA)
            XCTFail("Unavailable library should fail initial tune")
        } catch {
            XCTAssertEqual(error as? LibraryChannelError, .sourceUnavailable)
        }
        XCTAssertEqual(fixture.adapter.liveSnapshot.phase, .failed)
        XCTAssertFalse(fixture.adapter.liveSnapshot.firstFrameReady)
        XCTAssertFalse(fixture.adapter.preventsDisplaySleep)
        fixture.adapter.stop()
        await fixture.adapter.drainTransport()
    }

    func testScheduledRecoveryDoesNotKeepAnInitialFailureLatched() async throws {
        let fixture = try UniversalLiveFixture()
        fixture.unavailableItems = ["first"]
        var fatalFailures = 0
        fixture.adapter.onFailure = { _ in fatalFailures += 1 }
        do {
            try await fixture.adapter.loadChannel(fixture.inputA)
            XCTFail("Unavailable programme should fail")
        } catch {
            XCTAssertEqual(error as? LibraryChannelError, .mediaChanged)
        }
        let session = try XCTUnwrap(fixture.adapter.librarySession)
        XCTAssertEqual(fixture.adapter.recoverableProgrammeIssue, .mediaChanged)
        XCTAssertEqual(fixture.adapter.liveSnapshot.phase, .failed)
        XCTAssertFalse(fixture.adapter.liveSnapshot.firstFrameReady)
        XCTAssertEqual(fatalFailures, 0)
        fixture.advanceClock(101)
        session.tick()
        await settle { session.state == .playing }
        XCTAssertNil(fixture.adapter.recoverableProgrammeIssue)
        XCTAssertEqual(fixture.adapter.liveSnapshot.phase, .playing)
        XCTAssertEqual(fixture.adapter.status, .ready)
        XCTAssertTrue(fixture.adapter.preventsDisplaySleep)
        XCTAssertEqual(fixture.factoryEngines.count, 1)
        XCTAssertEqual(fixture.decoder.loadedSources, ["vod:second"])
        fixture.adapter.stop()
        await fixture.adapter.drainTransport()
    }

    func testOrdinaryStreamCallbacksRemainConnected() async throws {
        let fixture = try UniversalLiveFixture()
        var failures: [AppError] = []
        var ended = 0
        var progress = 0
        var tracks = 0
        var resets = 0
        fixture.adapter.onFailure = { failures.append($0) }
        fixture.adapter.onEnded = { ended += 1 }
        fixture.adapter.onProgress = { progress += 1 }
        fixture.adapter.onTracksChanged = { tracks += 1 }
        fixture.adapter.onLiveSourceReset = { resets += 1 }
        try await fixture.adapter.loadChannel(streamA)
        fixture.decoder.onProgress?()
        fixture.decoder.onTracksChanged?()
        fixture.decoder.onLiveSourceReset?()
        fixture.decoder.onFailure?(.serverUnreachable)
        fixture.decoder.onEnded?()
        XCTAssertEqual(failures, [.serverUnreachable])
        XCTAssertEqual([ended, progress, tracks, resets], [1, 1, 1, 1])
        fixture.adapter.stop()
        await fixture.adapter.drainTransport()
    }

    func testLegacyLiveLoadPublishesFailureOnceWithOrWithoutDecoderCallback() async throws {
        for emitsCallback in [false, true] {
            let fixture = try UniversalLiveFixture()
            fixture.decoder.emitsFailureCallbacks = emitsCallback
            fixture.decoder.loadError = .decoding
            var failures: [AppError] = []
            fixture.adapter.onFailure = { failures.append($0) }
            await fixture.adapter.loadLive(
                url: URL(string: "https://example.invalid/a.m3u8")!, httpHeaders: [:]
            )
            XCTAssertEqual(failures, [.decoding])
            XCTAssertEqual(fixture.adapter.status, .failed(.decoding))
            XCTAssertEqual(fixture.adapter.liveSnapshot.phase, .failed)
            XCTAssertFalse(fixture.adapter.liveSnapshot.firstFrameReady)
            fixture.adapter.stop()
            await fixture.adapter.drainTransport()
        }
    }

    func testLegacyVODLoadPublishesFailureRatherThanSuccessfulCompletionState() async throws {
        let fixture = try UniversalLiveFixture()
        fixture.decoder.loadError = .notFound
        var failures: [AppError] = []
        fixture.adapter.onFailure = { failures.append($0) }
        let request = PlaybackRequest(
            item: MediaItem(id: "item", title: "Item", kind: .movie),
            streamURL: URL(string: "https://example.invalid/file.mp4")!
        )
        await fixture.adapter.load(request: request, startPosition: 12)
        XCTAssertEqual(failures, [.notFound])
        XCTAssertEqual(fixture.adapter.status, .failed(.notFound))
        XCTAssertEqual(fixture.adapter.liveSnapshot.phase, .failed)
        fixture.adapter.stop()
        await fixture.adapter.drainTransport()
    }

    func testNonthrowingSeeksPublishFailureExactlyOncePerOperation() async throws {
        let fixture = try UniversalLiveFixture()
        fixture.decoder.seekError = .decoding
        var failures: [AppError] = []
        fixture.adapter.onFailure = { failures.append($0) }
        try await fixture.adapter.loadChannel(streamA)
        await fixture.adapter.seek(to: 12)
        XCTAssertEqual(failures, [.decoding])
        XCTAssertEqual(fixture.adapter.status, .failed(.decoding))
        try await fixture.adapter.loadChannel(streamA)
        await fixture.adapter.seek(to: 24, kind: .exact)
        XCTAssertEqual(failures, [.decoding, .decoding])
        XCTAssertEqual(fixture.adapter.liveSnapshot.phase, .failed)
        try await fixture.adapter.loadChannel(streamA)
        await fixture.adapter.seekToLiveEdge()
        XCTAssertEqual(failures, [.decoding, .decoding, .decoding])
        XCTAssertEqual(fixture.adapter.status, .failed(.decoding))
        fixture.adapter.stop()
        await fixture.adapter.drainTransport()
    }

    func testLegacyCancellationRetiresSourceWithoutFailureNotification() async throws {
        let fixture = try UniversalLiveFixture()
        let load = UniversalLiveGate()
        fixture.decoder.loadHook = { await load.wait() }
        var failures: [AppError] = []
        fixture.adapter.onFailure = { failures.append($0) }
        let tune = Task {
            await fixture.adapter.loadLive(
                url: URL(string: "https://example.invalid/a.m3u8")!, httpHeaders: [:]
            )
        }
        await settle { load.isWaiting }
        tune.cancel()
        await settle { fixture.adapter.currentInput == nil }
        load.open()
        await tune.value
        await fixture.adapter.drainTransport()
        XCTAssertTrue(failures.isEmpty)
        XCTAssertEqual(fixture.adapter.status, .idle)
        XCTAssertEqual(fixture.decoder.status, .idle)
    }

    func testDecoderCancellationIsNotPublishedAsLegacyLoadFailure() async throws {
        for emitsCallback in [false, true] {
            let fixture = try UniversalLiveFixture()
            fixture.decoder.loadError = .cancelled
            fixture.decoder.emitsFailureCallbacks = emitsCallback
            var failures: [AppError] = []
            fixture.adapter.onFailure = { failures.append($0) }
            await fixture.adapter.loadLive(
                url: URL(string: "https://example.invalid/a.m3u8")!, httpHeaders: [:]
            )
            await fixture.adapter.drainTransport()
            XCTAssertTrue(failures.isEmpty)
            XCTAssertNil(fixture.adapter.currentInput)
            XCTAssertEqual(fixture.adapter.status, .idle)
            XCTAssertEqual(fixture.decoder.status, .idle)
        }
    }

    func testNonthrowingGoLiveRetainsRecoverableProgrammeGap() async throws {
        let fixture = try UniversalLiveFixture()
        try await fixture.adapter.loadChannel(fixture.inputA)
        let session = try XCTUnwrap(fixture.adapter.librarySession)
        fixture.unavailableItems = ["first"]
        var failures: [AppError] = []
        fixture.adapter.onFailure = { failures.append($0) }
        await fixture.adapter.seekToLiveEdge()
        XCTAssertTrue(session === fixture.adapter.librarySession)
        XCTAssertEqual(fixture.adapter.recoverableProgrammeIssue, .mediaChanged)
        XCTAssertEqual(fixture.adapter.liveSnapshot.phase, .failed)
        XCTAssertFalse(fixture.adapter.liveSnapshot.firstFrameReady)
        XCTAssertTrue(failures.isEmpty)
        fixture.advanceClock(101)
        session.tick()
        await settle { session.state == .playing }
        XCTAssertEqual(fixture.adapter.liveSnapshot.phase, .playing)
        XCTAssertNil(fixture.adapter.recoverableProgrammeIssue)
        fixture.adapter.stop()
        await fixture.adapter.drainTransport()
    }

    #if os(iOS)
    func testPictureInPictureForwardsActualDecoderCapabilitiesAndLayer() {
        let decoder = UniversalLiveDecoder()
        let adapter = LibraryLiveChannelEngine(engine: decoder)
        XCTAssertNil(adapter.pictureInPicturePlayerLayer())
        decoder.presentationLayer = AVPlayerLayer()
        XCTAssertTrue(adapter.pictureInPicturePlayerLayer() === decoder.presentationLayer)
        adapter.setPictureInPictureActive(true)
        XCTAssertTrue(adapter.continuesPlaybackInBackground)
        decoder.externalPlaybackRouteName = "Fixture receiver"
        XCTAssertEqual(adapter.externalPlaybackRouteName, "Fixture receiver")
        var changes = 0
        adapter.onPresentationLayerChanged = { changes += 1 }
        decoder.onPresentationLayerChanged?()
        XCTAssertEqual(changes, 1)
        adapter.setNativeSubtitlesActive(true)
        XCTAssertTrue(decoder.nativeSubtitlesActive)
        adapter.setPictureInPictureActive(false)
        XCTAssertFalse(adapter.continuesPlaybackInBackground)
    }
    #endif
}

@MainActor
private final class UniversalLiveFixture {
    let decoder = UniversalLiveDecoder()
    let channelA: UUID
    let channelB: UUID
    let schedules: [UUID: LibraryChannelSchedule]
    var now = Date(timeIntervalSince1970: 1_700_000_000)
    var uptime: TimeInterval = 0
    var historyToken: UUID?
    var authorization: String? = "profile:server:user"
    var providerAvailable = true
    var unavailableItems: Set<String> = []
    var factoryEngines: [ObjectIdentifier] = []
    var factoryAuthorizations: [String] = []
    var resolvedItems: [String] = []
    var ordinaryReports = 0
    var completions = 0
    var inputA: LiveChannelInput { .libraryChannel(id: channelA, authorizationID: authorization ?? "") }
    var inputB: LiveChannelInput { .libraryChannel(id: channelB, authorizationID: authorization ?? "") }
    lazy var adapter = LibraryLiveChannelEngine(engine: decoder) { [unowned self] id, expectedAuthorization, engine in
        factoryAuthorizations.append(expectedAuthorization)
        guard expectedAuthorization == authorization else { throw LibraryChannelError.authorizationChanged }
        guard let schedule = schedules[id] else { throw LibraryChannelError.snapshotUnavailable }
        factoryEngines.append(ObjectIdentifier(engine))
        let provider = UniversalLiveProvider(state: self)
        return LibraryChannelPlaybackSession(
            channelID: id, engine: engine,
            schedule: { schedule },
            provider: { [weak self] _ in self?.providerAvailable == true ? provider : nil },
            authorization: { [weak self] in self?.authorization == expectedAuthorization ? expectedAuthorization : nil },
            historyAuthorization: { [weak self] in self?.historyToken },
            scrobbler: UniversalLiveScrobbler(),
            onCompleted: { [weak self] _, _, _ in self?.completions += 1 },
            clock: { [unowned self] in self.now },
            uptime: { [unowned self] in self.uptime }
        )
    }

    init() throws {
        let library = LibraryChannelLibrary(accountID: "account", libraryID: "library")
        let epoch = Date(timeIntervalSince1970: 1_700_000_000)
        let items = try ["first", "second"].enumerated().map { index, id in
            var item = MediaItem(id: id, title: id, kind: .episode, runtime: 100)
            item.seriesID = "show"
            item.seasonNumber = 1
            item.episodeNumber = index + 1
            return try LibraryChannelItem(item: item, library: library, serverID: "server", userID: "user")
        }
        let snapshot = try LibraryChannelSnapshot(items: items, createdAt: epoch)
        let revision = LibraryChannelRevision(
            snapshotID: snapshot.id,
            recipe: LibraryChannelRecipe(name: "TV", libraries: [library]),
            epochSeconds: Int64(epoch.timeIntervalSince1970)
        )
        let first = LibraryChannelDefinition(profileID: "profile", revisions: [revision])
        let second = LibraryChannelDefinition(profileID: "profile", revisions: [revision])
        channelA = first.id
        channelB = second.id
        schedules = [
            first.id: try LibraryChannelSchedule(definition: first, snapshots: [snapshot.id: snapshot]),
            second.id: try LibraryChannelSchedule(definition: second, snapshots: [snapshot.id: snapshot])
        ]
    }

    func advanceClock(_ seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
        uptime += seconds
    }

    func advancePlayback(seconds: Int) {
        for _ in 0..<seconds {
            advanceClock(1)
            decoder.currentTime += 1
            decoder.liveSnapshot.position = decoder.currentTime
            adapter.librarySession?.tick()
        }
    }

    func resolve(_ item: LibraryChannelItem) throws -> PlaybackRequest {
        resolvedItems.append(item.itemID)
        guard !unavailableItems.contains(item.itemID) else { throw LibraryChannelError.mediaChanged }
        return PlaybackRequest(
            item: MediaItem(id: item.itemID, title: item.title, kind: item.kind, runtime: Double(item.durationSeconds)),
            streamURL: URL(string: "https://example.invalid/library.mp4")!
        )
    }
}

private actor UniversalLiveProvider: LibraryChannelPlaybackProviding {
    let kind = ProviderKind.jellyfin
    nonisolated let session = UserSession(
        server: MediaServer(id: "server", name: "Server", baseURL: URL(string: "https://example.invalid")!, provider: .jellyfin),
        userID: "user", userName: "User", deviceID: "device", accessToken: "fixture"
    )
    let state: UniversalLiveFixture
    init(state: UniversalLiveFixture) { self.state = state }
    func libraryChannelPlayback(for item: LibraryChannelItem) async throws -> PlaybackRequest {
        try await state.resolve(item)
    }
    func recordLibraryChannelCompletion(itemID: String) async throws {}
    func libraries() async throws -> [MediaLibrary] { [] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem { throw AppError.notFound }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage { throw AppError.notFound }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {
        await MainActor.run { state.ordinaryReports += 1 }
    }
    nonisolated func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}

private struct UniversalLiveScrobbler: TraktScrobbling {
    func scrobble(item: MediaItem, progress: Double, event: PlaybackEvent) async {}
}

@MainActor
private final class UniversalLiveGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false
    var isWaiting: Bool { continuation != nil }
    func wait() async {
        guard !opened else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() {
        opened = true
        let pending = continuation
        continuation = nil
        pending?.resume()
    }
}

@MainActor
private final class UniversalLiveDecoder: LiveChannelEngine {
    var status: VideoEngineStatus = .idle
    var isPaused = false
    var preventsDisplaySleep = true
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 100
    var furthestObservedPosition: TimeInterval = 0
    var audioTracks: [MediaTrack] = []
    var subtitleTracks: [MediaTrack] = []
    var liveSnapshot = LiveChannelEngineSnapshot()
    var supportsConcurrentPlayback = false
    var onProgress: (@MainActor () -> Void)?
    var onFailure: (@MainActor (AppError) -> Void)?
    var onEnded: (@MainActor () -> Void)?
    var onTracksChanged: (@MainActor () -> Void)?
    var onProbedSourceFactsChanged: (@MainActor (EngineProbedSourceFacts) -> Void)?
    var onSubtitleCues: (@MainActor ([SubtitleCue]) -> Void)?
    var onSecondarySubtitleCues: (@MainActor ([SubtitleCue]) -> Void)?
    var onLiveSourceReset: (@MainActor () -> Void)?
    var loadedSources: [String] = []
    var activeSource: String?
    var events: [String] = []
    var headers: [[String: String]] = []
    var seeks: [TimeInterval] = []
    var outputPolicies: [LiveChannelOutputPolicy] = []
    var stopPolicies: [LiveChannelOutputPolicy] = []
    var watchingChanges: [Bool] = []
    var providesFirstFrame = true
    var loadError: AppError?
    var seekError: AppError?
    var emitsFailureCallbacks = true
    var loadHook: (@MainActor () async -> Void)?
    var drainHook: (@MainActor () async -> Void)?
    var reloadHook: (@MainActor () async -> Void)?

    func loadLive(url: URL, httpHeaders: [String: String]) async {
        headers.append(httpHeaders)
        await loadSource("stream:\(url.lastPathComponent)", position: 0)
    }
    func load(request: PlaybackRequest, startPosition: TimeInterval) async {
        await loadSource("vod:\(request.item.id)", position: startPosition)
    }
    private func loadSource(_ source: String, position: TimeInterval) async {
        loadedSources.append(source)
        events.append("load:\(source)")
        status = .loading
        await loadHook?()
        // Deliberately ignores cancellation, to exercise the adapter's drain barrier.
        activeSource = source
        currentTime = position
        status = .ready
        isPaused = false
        liveSnapshot = .init(
            phase: .playing, firstFrameReady: providesFirstFrame, position: position,
            bufferedPosition: position + 10, seekableRange: 0...100, route: .localHLS
        )
        events.append("loaded:\(source)")
        if let loadError { publishFailure(loadError) }
    }
    func play() { isPaused = false; liveSnapshot.phase = .playing }
    func pause() { isPaused = true; liveSnapshot.phase = .paused }
    func reloadAfterForeground() async throws {
        let source = activeSource
        await reloadHook?()
        activeSource = source
        status = .ready
    }
    func seek(to seconds: TimeInterval) async {
        seeks.append(seconds)
        currentTime = seconds
        liveSnapshot.position = seconds
        if let seekError { publishFailure(seekError) }
    }
    func seekToLiveEdge() async {
        events.append("live-edge")
        if let seekError { publishFailure(seekError) }
    }
    private func publishFailure(_ error: AppError) {
        status = .failed(error)
        liveSnapshot.phase = .failed
        if emitsFailureCallbacks { onFailure?(error) }
    }
    func stop() {
        stopPolicies.append(outputPolicies.last ?? .init())
        activeSource = nil
        status = .idle
        isPaused = true
        liveSnapshot = .init()
        events.append("stop")
    }
    func drainTransport() async {
        events.append("drain")
        await drainHook?()
        events.append("drained")
    }
    func setWatching(_ isWatching: Bool) { watchingChanges.append(isWatching) }
    func configureLiveOutput(_ policy: LiveChannelOutputPolicy) { outputPolicies.append(policy) }
    func selectAudioTrack(_ track: MediaTrack?) {}
    func selectSubtitleTrack(_ track: MediaTrack?) {}
    #if canImport(UIKit)
    func makeVideoOutputView() -> UIView { UIView() }
    #endif
    #if os(iOS)
    var presentationLayer: AVPlayerLayer?
    var continuesPlaybackInBackground = false
    var externalPlaybackRouteName: String?
    var onPresentationLayerChanged: (() -> Void)?
    var nativeSubtitlesActive = false
    #endif
}

#if os(iOS)
extension UniversalLiveDecoder: PictureInPicturePresentingEngine {
    func pictureInPicturePlayerLayer() -> AVPlayerLayer? { presentationLayer }
    func setPictureInPictureActive(_ active: Bool) { continuesPlaybackInBackground = active }
    func setNativeSubtitlesActive(_ active: Bool) { nativeSubtitlesActive = active }
}
#endif
#endif
