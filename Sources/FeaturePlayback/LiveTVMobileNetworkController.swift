#if canImport(Network)
import CoreModels
import Foundation
import Network
import Observation

@MainActor
public protocol LiveTVNetworkMonitoring: AnyObject {
    func start(_ update: @escaping @MainActor @Sendable (LiveTVNetworkPath) -> Void)
    func stop()
}

@MainActor
public final class LiveTVSystemNetworkMonitor: LiveTVNetworkMonitoring {
    private var monitor: NWPathMonitor?

    public init() {}
    deinit { monitor?.cancel() }

    public func start(_ update: @escaping @MainActor @Sendable (LiveTVNetworkPath) -> Void) {
        stop()
        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { path in
            let connection: LiveTVNetworkPath.Connection
            if path.status != .satisfied {
                connection = .offline
            } else if path.usesInterfaceType(.cellular) {
                connection = .cellular
            } else if path.usesInterfaceType(.wifi) {
                connection = .wifi
            } else if path.usesInterfaceType(.wiredEthernet) {
                connection = .wired
            } else {
                connection = .other
            }
            let snapshot = LiveTVNetworkPath(
                connection: connection, isConstrained: path.isConstrained
            )
            Task { @MainActor in update(snapshot) }
        }
        monitor.start(queue: DispatchQueue(label: "com.plozz.liveTV.network"))
    }

    public func stop() {
        monitor?.cancel()
        monitor = nil
    }
}

/// One monitor per destination, including when its retained player is external.
@MainActor
@Observable
public final class LiveTVMobileNetworkController {
    public private(set) var path = LiveTVNetworkPath()
    public private(set) var wifiOnly: Bool
    public var block: LiveTVNetworkBlock? {
        LiveTVMobileNetworkPolicy.block(path: path, wifiOnly: wifiOnly)
    }
    public var allowsPlayback: Bool { block == nil }
    @ObservationIgnored private let store: any LiveTVViewSettingsStoring
    @ObservationIgnored private let monitor: any LiveTVNetworkMonitoring
    @ObservationIgnored private var settingsObservation: LiveTVSettingsObservation?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var running = false
    @ObservationIgnored public var onPolicyChange: (@MainActor (LiveTVNetworkBlock?) -> Void)?

    public init(
        store: any LiveTVViewSettingsStoring,
        monitor: (any LiveTVNetworkMonitoring)? = nil
    ) {
        self.store = store
        self.monitor = monitor ?? LiveTVSystemNetworkMonitor()
        wifiOnly = store.load().wifiOnly
    }

    public func start() {
        guard !running else { reloadSettings(); return }
        running = true
        generation &+= 1
        let generation = generation
        reloadSettings()
        settingsObservation = LiveTVSettingsObservation { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadSettings() }
        }
        monitor.start { [weak self] path in
            guard let self, self.running, self.generation == generation else { return }
            self.path = path
            self.onPolicyChange?(self.block)
        }
    }

    public func reloadSettings() {
        wifiOnly = store.load().wifiOnly
        onPolicyChange?(block)
    }

    public func stop() {
        running = false
        generation &+= 1
        monitor.stop()
        settingsObservation = nil
        path = LiveTVNetworkPath()
    }
}

private final class LiveTVSettingsObservation {
    private let token: NSObjectProtocol

    init(_ update: @escaping @Sendable (Notification) -> Void) {
        token = NotificationCenter.default.addObserver(
            forName: LiveTVViewSettingsStore.didChange, object: nil, queue: .main,
            using: update
        )
    }

    deinit { NotificationCenter.default.removeObserver(token) }
}
#endif
