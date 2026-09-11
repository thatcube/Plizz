#if DEBUG
import CoreModels
import CoreNetworking
import Foundation

struct LiveChannelDiagnostics {
    static let maximumElapsedMilliseconds = 86_400_000

    enum Event: String {
        case load, retry, pause, resume, seek, seekCompleted, suspend, foreground
        case failure, startupTimeout, stallTimeout, ended, stop
        case initializationFailure, sourceReset, retune, retuneExhausted
        case tuneToFirstFrame
    }

    struct Cadence {
        private var lastEmission: TimeInterval?
        private var lastSignature: String?

        mutating func shouldEmit(signature: String, uptime: TimeInterval) -> Bool {
            if let lastEmission {
                let elapsed = uptime - lastEmission
                guard elapsed >= 1,
                      signature != lastSignature || elapsed >= 10 else { return false }
            }
            lastEmission = uptime
            lastSignature = signature
            return true
        }
    }

    // Correlate an attempt without recording channel IDs, names, URLs or tokens.
    private let session = UUID().uuidString
    private var cadence = Cadence()

    mutating func sample(_ snapshot: LiveChannelEngineSnapshot, uptime: TimeInterval, attempt: Int) {
        guard HandoffDiagnostics.isEnabled,
              cadence.shouldEmit(signature: snapshot.diagnosticSignature, uptime: uptime) else { return }
        emit("attempt=\(attempt) event=sample \(snapshot.diagnosticDetail)")
    }

    func event(_ event: Event, attempt: Int, error: AppError? = nil) {
        guard HandoffDiagnostics.isEnabled else { return }
        let code = error.map(HandoffDiagnostics.errorCode) ?? "none"
        emit("attempt=\(attempt) event=\(event.rawValue) error=\(code)")
    }

    func tuneToFirstFrame(
        attempt: Int,
        startedAt: TimeInterval,
        firstFrameAt: TimeInterval
    ) {
        guard HandoffDiagnostics.isEnabled else { return }
        let elapsed = Self.elapsedMilliseconds(
            startedAt: startedAt,
            firstFrameAt: firstFrameAt
        )
        emit("attempt=\(attempt) event=\(Event.tuneToFirstFrame.rawValue) elapsedMs=\(elapsed)")
    }

    static func elapsedMilliseconds(
        startedAt: TimeInterval,
        firstFrameAt: TimeInterval
    ) -> Int {
        guard startedAt.isFinite, firstFrameAt.isFinite else { return 0 }
        let elapsed = max(0, firstFrameAt - startedAt) * 1_000
        return Int(min(elapsed.rounded(), Double(maximumElapsedMilliseconds)))
    }

    private func emit(_ detail: String) {
        let line = "LIVE_TV session=\(session) engine=AetherEngine \(detail)"
        PlozzLog.playback.info(line)
        HandoffDiagnostics.emit(line)
    }
}

private extension LiveChannelEngineSnapshot {
    var diagnosticSignature: String {
        "\(phase.diagnosticCode)/\(route.rawValue)/\(firstFrameReady)"
    }

    var diagnosticDetail: String {
        "phase=\(phase.diagnosticCode) route=\(route.rawValue) firstFrameReady=\(firstFrameReady)"
            + " position=\(number(position)) bufferedPosition=\(number(bufferedPosition))"
            + " behindLive=\(number(behindLiveSeconds))"
            + " seekableStart=\(number(seekableRange?.lowerBound))"
            + " seekableEnd=\(number(seekableRange?.upperBound))"
    }

    func number(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "unknown" }
        return String(format: "%.3f", value)
    }
}
#endif
