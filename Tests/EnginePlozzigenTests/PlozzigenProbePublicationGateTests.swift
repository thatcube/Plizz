import XCTest
import AetherEngine
import CoreModels
@testable import EnginePlozzigen

final class PlozzigenProbePublicationGateTests: XCTestCase {
    @MainActor
    func testLocalPlaybackUsesKnownItemRuntimeAsDeclaredDuration() {
        let item = MediaItem(
            id: "episode",
            title: "Episode",
            kind: .episode,
            runtime: 1_440
        )
        let request = PlaybackRequest(
            item: item,
            streamURL: URL(fileURLWithPath: "/tmp/media.mp4")
        )

        XCTAssertEqual(
            PlozzigenVideoEngine.declaredDuration(
                for: request,
                sourceURL: request.streamURL!
            ),
            1_440
        )
    }

    @MainActor
    func testRemotePlaybackDoesNotOverrideContainerDuration() {
        let item = MediaItem(
            id: "episode",
            title: "Episode",
            kind: .episode,
            runtime: 1_440
        )
        let request = PlaybackRequest(
            item: item,
            streamURL: URL(string: "https://example.test/media.mp4")!
        )

        XCTAssertNil(
            PlozzigenVideoEngine.declaredDuration(
                for: request,
                sourceURL: request.streamURL!
            )
        )
    }

    func testNewLoadInvalidatesPriorGeneration() {
        var gate = PlozzigenProbePublicationGate()
        let first = gate.beginLoad()
        let second = gate.beginLoad()

        XCTAssertFalse(gate.accepts(first))
        XCTAssertTrue(gate.accepts(second))
        XCTAssertNil(gate.currentRange)
    }

    func testStopInvalidatesActiveGeneration() {
        var gate = PlozzigenProbePublicationGate()
        let active = gate.beginLoad()

        gate.invalidate()

        XCTAssertFalse(gate.accepts(active))
        XCTAssertFalse(gate.accepts(gate.currentGeneration))
        XCTAssertNil(gate.currentRange)
    }

    func testLateActiveUpdateReplacesPublishedRange() {
        var gate = PlozzigenProbePublicationGate()
        let active = gate.beginLoad()

        XCTAssertTrue(gate.record(.hdr10, generation: active))
        XCTAssertEqual(gate.currentRange, .hdr10)
        XCTAssertTrue(gate.record(.hdr10Plus, generation: active))
        XCTAssertEqual(gate.currentRange, .hdr10Plus)
    }

    func testReloadCanRepublishWithoutChangingGeneration() {
        var gate = PlozzigenProbePublicationGate()
        let active = gate.beginLoad()
        XCTAssertTrue(gate.record(.dolbyVision, generation: active))

        let reloadGeneration = gate.currentGeneration

        XCTAssertEqual(reloadGeneration, active)
        XCTAssertTrue(gate.record(.dolbyVision, generation: reloadGeneration))
        XCTAssertEqual(gate.currentRange, .dolbyVision)
    }

    func testLoadCompletionPublicationDoesNotDependOnTransientAdapterStatus() {
        var gate = PlozzigenProbePublicationGate()
        let active = gate.beginLoad()

        XCTAssertTrue(
            gate.acceptsLoadCompletion(active, engineHasError: false)
        )
        XCTAssertFalse(
            gate.acceptsLoadCompletion(active, engineHasError: true)
        )

        gate.invalidate()
        XCTAssertFalse(
            gate.acceptsLoadCompletion(active, engineHasError: false)
        )
    }

    func testStaleLoadCannotReplaceCurrentRange() {
        var gate = PlozzigenProbePublicationGate()
        let stale = gate.beginLoad()
        let active = gate.beginLoad()
        XCTAssertTrue(gate.record(.hlg, generation: active))

        XCTAssertFalse(gate.record(.dolbyVision, generation: stale))
        XCTAssertEqual(gate.currentRange, .hlg)
    }

    func testLiveLoadOptionsUseStableNativeHLSWithFallbacks() {
        let headers = [
            "Authorization": "Bearer secret",
            "User-Agent": "PlozzTests",
        ]

        let options = PlozzigenVideoEngine.liveLoadOptions(
            httpHeaders: headers
        )

        XCTAssertEqual(options.httpHeaders, headers)
        XCTAssertTrue(options.isLive)
        XCTAssertNil(options.dvrWindowSeconds)
        XCTAssertEqual(options.liveJoinProfile, .standard)
        XCTAssertTrue(options.nativeRemoteHLS)
        XCTAssertTrue(options.nativeRemoteHLSIngestFallback)
        XCTAssertNil(options.declaredDurationSeconds)
        XCTAssertTrue(options.autoplay)
    }

    func testLivePlaybackPhaseMapping() {
        XCTAssertEqual(PlozzigenVideoEngine.livePhase(.idle), .idle)
        XCTAssertEqual(PlozzigenVideoEngine.livePhase(.loading), .loading)
        XCTAssertEqual(PlozzigenVideoEngine.livePhase(.playing), .playing)
        XCTAssertEqual(PlozzigenVideoEngine.livePhase(.paused), .paused)
        XCTAssertEqual(PlozzigenVideoEngine.livePhase(.seeking), .seeking)
        XCTAssertEqual(PlozzigenVideoEngine.livePhase(.rebuffering), .rebuffering)
        XCTAssertEqual(
            PlozzigenVideoEngine.livePhase(.stalled(reconnecting: true)),
            .stalled(reconnecting: true)
        )
        XCTAssertEqual(PlozzigenVideoEngine.livePhase(.ended), .ended)
        XCTAssertEqual(PlozzigenVideoEngine.livePhase(.error("private detail")), .failed)
    }

    func testLiveVideoRouteMapping() {
        XCTAssertEqual(PlozzigenVideoEngine.liveRoute(.none), .none)
        XCTAssertEqual(PlozzigenVideoEngine.liveRoute(.remoteBypass), .nativeHLS)
        XCTAssertEqual(PlozzigenVideoEngine.liveRoute(.loopback), .localHLS)
        XCTAssertEqual(PlozzigenVideoEngine.liveRoute(.software), .software)
        XCTAssertEqual(PlozzigenVideoEngine.liveRoute(.audio), .audio)
    }

    func testNewLiveAttemptFencesPriorCallbacksAndCompletion() {
        var gate = PlozzigenLiveAttemptGate()
        let stale = gate.begin()
        let active = gate.begin()

        XCTAssertFalse(gate.accepts(stale))
        XCTAssertTrue(gate.accepts(active))
    }

    func testStoppingLiveAttemptFencesQueuedCallbacks() {
        var gate = PlozzigenLiveAttemptGate()
        let active = gate.begin()

        gate.invalidate()

        XCTAssertFalse(gate.accepts(active))
        XCTAssertNil(gate.activeGeneration)
    }

    func testLiveAttemptReportsFailureOnlyOnce() {
        var gate = PlozzigenLiveAttemptGate()
        let active = gate.begin()

        XCTAssertTrue(gate.consumeFailure(for: active))
        XCTAssertFalse(gate.consumeFailure(for: active))

        let replacement = gate.begin()
        XCTAssertTrue(gate.consumeFailure(for: replacement))
        XCTAssertFalse(gate.consumeFailure(for: active))
    }
}
