#if DEBUG
import CoreModels
import CoreNetworking
import XCTest
@testable import FeaturePlayback

final class LiveChannelDiagnosticsTests: XCTestCase {
    func testDiagnosticCadenceCoalescesChangesAndAddsHeartbeat() {
        var cadence = LiveChannelDiagnostics.Cadence()
        XCTAssertTrue(cadence.shouldEmit(signature: "playing", uptime: 0))
        XCTAssertFalse(cadence.shouldEmit(signature: "rebuffering", uptime: 0.25))
        XCTAssertFalse(cadence.shouldEmit(signature: "playing", uptime: 0.5))
        XCTAssertTrue(cadence.shouldEmit(signature: "rebuffering", uptime: 1))
        XCTAssertFalse(cadence.shouldEmit(signature: "rebuffering", uptime: 10))
        XCTAssertTrue(cadence.shouldEmit(signature: "rebuffering", uptime: 11))
    }

    func testDiagnosticChurnIsLimitedToOneSnapshotPerSecond() {
        var cadence = LiveChannelDiagnostics.Cadence()
        let emitted = (0..<400).filter { tick in
            cadence.shouldEmit(signature: String(tick), uptime: Double(tick) / 4)
        }
        XCTAssertEqual(emitted.count, 100)
    }

    func testErrorsNeverIncludeRawDetailsOrCredentials() {
        let wasEnabled = HandoffDiagnostics.isEnabled
        HandoffDiagnostics.setEnabled(true)
        defer { HandoffDiagnostics.setEnabled(wasEnabled) }
        LiveChannelDiagnostics().event(
            .failure, attempt: 1,
            error: .unknown("https://example.invalid/live?token=fixture-secret")
        )
        let line = PlozzLog.recentEntries(limit: 1).first?.message ?? ""
        XCTAssertTrue(line.contains("LIVE_TV session="))
        XCTAssertTrue(line.contains("engine=AetherEngine"))
        XCTAssertTrue(line.contains("error=unknown"))
        XCTAssertFalse(line.contains("https://"))
        XCTAssertFalse(line.contains("fixture-secret"))
        XCTAssertFalse(line.contains("token="))
    }

    func testSnapshotsIdentifyActualRouteAndEnginePhase() {
        let wasEnabled = HandoffDiagnostics.isEnabled
        HandoffDiagnostics.setEnabled(true)
        defer { HandoffDiagnostics.setEnabled(wasEnabled) }
        var diagnostics = LiveChannelDiagnostics()
        diagnostics.sample(
            .init(phase: .stalled(reconnecting: true), firstFrameReady: true,
                  position: 102, bufferedPosition: 104, seekableRange: 90...110,
                  behindLiveSeconds: 8, route: .localHLS),
            uptime: 0, attempt: 2
        )
        let line = PlozzLog.recentEntries(limit: 1).first?.message ?? ""
        XCTAssertTrue(line.contains("engine=AetherEngine"))
        XCTAssertTrue(line.contains("phase=reconnecting"))
        XCTAssertTrue(line.contains("route=localHLS"))
        XCTAssertTrue(line.contains("firstFrameReady=true"))
        XCTAssertTrue(line.contains("behindLive=8.000"))
    }

    func testTuneToFirstFrameUsesBoundedMonotonicMilliseconds() {
        XCTAssertEqual(
            LiveChannelDiagnostics.elapsedMilliseconds(
                startedAt: 10,
                firstFrameAt: 10.1246
            ),
            125
        )
        XCTAssertEqual(
            LiveChannelDiagnostics.elapsedMilliseconds(
                startedAt: 10,
                firstFrameAt: 9
            ),
            0
        )
        XCTAssertEqual(
            LiveChannelDiagnostics.elapsedMilliseconds(
                startedAt: 0,
                firstFrameAt: .greatestFiniteMagnitude
            ),
            LiveChannelDiagnostics.maximumElapsedMilliseconds
        )
        XCTAssertEqual(
            LiveChannelDiagnostics.elapsedMilliseconds(
                startedAt: .nan,
                firstFrameAt: 10
            ),
            0
        )
    }

    func testTuneToFirstFrameEventContainsOnlyAttemptAndElapsedTime() {
        let wasEnabled = HandoffDiagnostics.isEnabled
        HandoffDiagnostics.setEnabled(true)
        defer { HandoffDiagnostics.setEnabled(wasEnabled) }
        LiveChannelDiagnostics().tuneToFirstFrame(
            attempt: 2,
            startedAt: 100,
            firstFrameAt: 101.25
        )
        let line = PlozzLog.recentEntries(limit: 1).first?.message ?? ""
        XCTAssertTrue(line.contains("event=tuneToFirstFrame"))
        XCTAssertTrue(line.contains("attempt=2"))
        XCTAssertTrue(line.contains("elapsedMs=1250"))
        XCTAssertFalse(line.contains("http"))
        XCTAssertFalse(line.contains("header"))
        XCTAssertFalse(line.contains("token"))
    }

    func testRetuneBudgetIsBoundedAndSpaced() {
        var budget = LiveChannelRetuneBudget()
        XCTAssertEqual(budget.delayBeforeNextAttempt(uptime: 100), 0)
        for time in [100.0, 120, 140] {
            XCTAssertFalse(budget.isExhausted)
            budget.recordAttempt(uptime: time)
            XCTAssertEqual(budget.delayBeforeNextAttempt(uptime: time + 5), 15)
            XCTAssertEqual(budget.delayBeforeNextAttempt(uptime: time + 20), 0)
        }
        XCTAssertTrue(budget.isExhausted)
        XCTAssertEqual(budget.attempts, 3)
    }
}
#endif
