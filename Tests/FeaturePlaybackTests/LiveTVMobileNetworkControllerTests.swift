#if canImport(Network)
import CoreModels
import XCTest
@testable import FeaturePlayback

@MainActor
final class LiveTVMobileNetworkControllerTests: XCTestCase {
    func testOneMonitorHandlesWifiCellularAndLowDataModeTransitions() {
        let monitor = NetworkMonitorSpy()
        let store = NetworkSettingsSpy()
        let controller = LiveTVMobileNetworkController(store: store, monitor: monitor)
        var blocks: [LiveTVNetworkBlock?] = []
        controller.onPolicyChange = { blocks.append($0) }
        controller.start()
        controller.start()
        XCTAssertEqual(monitor.starts, 1)
        XCTAssertEqual(controller.block, .checkingConnection)
        monitor.send(.init(connection: .wifi))
        XCTAssertTrue(controller.allowsPlayback)
        monitor.send(.init(connection: .cellular))
        XCTAssertTrue(controller.allowsPlayback)
        store.settings.wifiOnly = true
        controller.reloadSettings()
        XCTAssertEqual(controller.block, .wifiRequired)
        monitor.send(.init(connection: .wifi, isConstrained: true))
        XCTAssertEqual(controller.block, .lowDataMode)
        monitor.send(.init(connection: .wifi))
        XCTAssertNil(controller.block)
        XCTAssertTrue(blocks.contains(.wifiRequired))
        controller.stop()
    }

    func testStoppedMonitorCannotReauthorizeFromALatePathUpdate() {
        let monitor = NetworkMonitorSpy()
        let controller = LiveTVMobileNetworkController(store: NetworkSettingsSpy(), monitor: monitor)
        controller.start()
        let oldUpdate = monitor.update
        controller.stop()
        oldUpdate?(.init(connection: .wifi))
        XCTAssertEqual(controller.block, .checkingConnection)
        controller.start()
        oldUpdate?(.init(connection: .wifi))
        XCTAssertEqual(controller.block, .checkingConnection)
        monitor.send(.init(connection: .cellular))
        XCTAssertNil(controller.block)
        controller.stop()
    }

    func testProfileSettingsNotificationStopsExistingStreamWithoutReopeningSettings() async {
        let suite = "LiveTVMobileNetworkControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = LiveTVViewSettingsStore(defaults: defaults, namespace: "first")
        let second = LiveTVViewSettingsStore(defaults: defaults, namespace: "second")
        let monitor = NetworkMonitorSpy()
        let controller = LiveTVMobileNetworkController(store: first, monitor: monitor)
        controller.start()
        defer { controller.stop() }
        monitor.send(.init(connection: .cellular))
        second.save(.init(wifiOnly: true))
        XCTAssertNil(controller.block)
        first.save(.init(wifiOnly: true))
        XCTAssertEqual(controller.block, .wifiRequired)
        first.save(.init(wifiOnly: false))
        XCTAssertNil(controller.block)
    }
}

@MainActor
private final class NetworkMonitorSpy: LiveTVNetworkMonitoring {
    var starts = 0
    var update: (@MainActor @Sendable (LiveTVNetworkPath) -> Void)?
    func start(_ update: @escaping @MainActor @Sendable (LiveTVNetworkPath) -> Void) {
        starts += 1
        self.update = update
    }
    func stop() { update = nil }
    func send(_ path: LiveTVNetworkPath) { update?(path) }
}

private final class NetworkSettingsSpy: LiveTVViewSettingsStoring, @unchecked Sendable {
    var settings = LiveTVViewSettings()
    func load() -> LiveTVViewSettings { settings }
    func save(_ settings: LiveTVViewSettings) { self.settings = settings }
}
#endif
