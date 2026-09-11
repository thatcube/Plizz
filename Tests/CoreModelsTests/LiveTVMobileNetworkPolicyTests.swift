import CoreModels
import XCTest

final class LiveTVMobileNetworkPolicyTests: XCTestCase {
    func testUnknownAndOfflineAreNeverMistakenForWifi() {
        for wifiOnly in [false, true] {
            XCTAssertEqual(
                LiveTVMobileNetworkPolicy.block(path: .init(), wifiOnly: wifiOnly),
                .checkingConnection
            )
            XCTAssertEqual(
                LiveTVMobileNetworkPolicy.block(path: .init(connection: .offline), wifiOnly: wifiOnly),
                .offline
            )
        }
    }

    func testCellularAllowedUnlessWifiOnlyChosen() {
        XCTAssertNil(LiveTVMobileNetworkPolicy.block(
            path: .init(connection: .cellular), wifiOnly: false
        ))
        XCTAssertEqual(LiveTVMobileNetworkPolicy.block(
            path: .init(connection: .cellular), wifiOnly: true
        ), .wifiRequired)
        XCTAssertNil(LiveTVMobileNetworkPolicy.block(
            path: .init(connection: .wifi), wifiOnly: true
        ))
    }

    func testConstrainedNetworkPausesInsteadOfClaimingAnUnsupportedBitrate() {
        for connection in [LiveTVNetworkPath.Connection.wifi, .cellular, .wired] {
            XCTAssertEqual(LiveTVMobileNetworkPolicy.block(
                path: .init(connection: connection, isConstrained: true), wifiOnly: false
            ), .lowDataMode)
        }
    }

    func testStopPreferenceAllowsWiredButRejectsOtherConnections() {
        XCTAssertNil(LiveTVMobileNetworkPolicy.block(
            path: .init(connection: .wired), wifiOnly: true
        ))
        XCTAssertEqual(LiveTVMobileNetworkPolicy.block(
            path: .init(connection: .other), wifiOnly: true
        ), .wifiRequired)
        XCTAssertNil(LiveTVMobileNetworkPolicy.block(
            path: .init(connection: .other), wifiOnly: false
        ))
    }
}
