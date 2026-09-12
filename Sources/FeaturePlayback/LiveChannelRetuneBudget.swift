#if DEBUG
import Foundation

struct LiveChannelRetuneBudget {
    private(set) var attempts = 0
    private var lastAttempt: TimeInterval?

    var isExhausted: Bool { attempts >= 3 }

    func delayBeforeNextAttempt(uptime: TimeInterval) -> TimeInterval {
        guard let lastAttempt else { return 0 }
        return max(0, lastAttempt + 20 - uptime)
    }

    mutating func recordAttempt(uptime: TimeInterval) {
        attempts += 1
        lastAttempt = uptime
    }
}
#endif
