import Foundation

public struct LiveTVNetworkPath: Equatable, Sendable {
    public enum Connection: Equatable, Sendable {
        case unknown, offline, wifi, cellular, wired, other
    }

    public var connection: Connection
    public var isConstrained: Bool

    public init(connection: Connection = .unknown, isConstrained: Bool = false) {
        self.connection = connection
        self.isConstrained = isConstrained
    }
}

public enum LiveTVNetworkBlock: Equatable, Sendable {
    case checkingConnection, offline, wifiRequired, lowDataMode

    public var playbackMessage: LocalizedStringResource {
        switch self {
        case .checkingConnection: "Checking your connection before opening Live TV."
        case .offline: "You're offline. Reconnect to watch Live TV. Saved guide listings are still available."
        case .wifiRequired: "Connect to Wi-Fi or Ethernet, or turn off “Stop without Wi-Fi or Ethernet” in Settings → Live TV."
        case .lowDataMode: "Live TV is paused for Low Data Mode. Use an unrestricted connection to resume."
        }
    }
}

/// Gates playback using observed paths, not individual media requests.
/// Strict request-level cellular enforcement remains unresolved in the playback engine.
public enum LiveTVMobileNetworkPolicy {
    public static func block(
        path: LiveTVNetworkPath,
        wifiOnly: Bool
    ) -> LiveTVNetworkBlock? {
        switch path.connection {
        case .unknown: return .checkingConnection
        case .offline: return .offline
        default: break
        }
        if wifiOnly, path.connection != .wifi, path.connection != .wired {
            return .wifiRequired
        }
        // The live engine cannot promise a lower rendition for every source.
        // Suspend instead of presenting an unenforceable bitrate preference.
        return path.isConstrained ? .lowDataMode : nil
    }
}
