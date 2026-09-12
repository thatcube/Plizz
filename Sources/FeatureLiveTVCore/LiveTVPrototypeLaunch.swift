#if DEBUG
import Foundation

public enum LiveTVPrototypeLaunch {
    private static let preference = "debug.liveTVPrototype.remember"

    public static func isEnabled(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        defaults: UserDefaults = .standard
    ) -> Bool {
        if arguments.contains("--live-tv-prototype-off") {
            defaults.removeObject(forKey: preference)
            return false
        }
        if arguments.contains("--live-tv-prototype-remember") {
            defaults.set(true, forKey: preference)
        }
        return arguments.contains("--live-tv-prototype")
            || defaults.bool(forKey: preference)
    }
}
#endif
