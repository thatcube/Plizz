#if DEBUG && canImport(SwiftUI) && canImport(UIKit)
import CoreModels
import FeatureLiveTVCore
import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import FeatureLiveTV

@MainActor
final class LiveTVChannelScanViewTests: XCTestCase {
    func testSourceImportOfferAndResultsDoNotStartScanningOnAppearance() async throws {
        let probe = ScanViewProbe()
        let coordinator = LiveTVChannelScanCoordinator(store: ScanViewHealthStore(), probe: probe)
        try coordinator.bind(profileID: "profile", sources: [source()])
        var dismissed = false
        let page = UIHostingController(rootView: NavigationStack {
            VStack {
                LiveTVScanSourceSection(coordinator: coordinator, sourceID: "source")
                LiveTVScanImportOffer(coordinator: coordinator, sourceID: "source") { dismissed = true }
            }
        })
        page.loadViewIfNeeded()
        page.view.frame = CGRect(x: 0, y: 0, width: 1_024, height: 768)
        page.view.layoutIfNeeded()
        let results = UIHostingController(rootView: NavigationStack {
            LiveTVScanResultsView(coordinator: coordinator, sourceID: "source", showHiddenOnly: true)
        })
        results.loadViewIfNeeded()
        results.view.layoutIfNeeded()
        let sources = UIHostingController(rootView: NavigationStack {
            LiveTVScanSourcesView(coordinator: coordinator, sourceNames: ["source": "My channels"])
        })
        sources.loadViewIfNeeded()
        sources.view.layoutIfNeeded()
        let calls = await probe.calls
        XCTAssertEqual(calls, 0)
        XCTAssertFalse(dismissed)
        XCTAssertFalse(coordinator.isScanning)
    }

    func testClosingResultsDoesNotCancelAnExplicitScan() async throws {
        let probe = ScanViewProbe()
        let coordinator = LiveTVChannelScanCoordinator(store: ScanViewHealthStore(), probe: probe)
        try coordinator.bind(profileID: "profile", sources: [source()])
        var page: UIHostingController<LiveTVScanResultsView>? = UIHostingController(
            rootView: LiveTVScanResultsView(coordinator: coordinator, sourceID: "source")
        )
        page?.loadViewIfNeeded()
        XCTAssertTrue(coordinator.start(sourceID: "source"))
        await probe.waitForStart()
        page = nil
        XCTAssertTrue(coordinator.isScanning)
        await probe.complete()
        await coordinator.waitUntilFinished()
        XCTAssertEqual(coordinator.progress?.completed, 1)
    }

    private func source() throws -> LiveTVChannelScanSource {
        let url = URL(string: "https://fixture.test/live.m3u8")!
        let channel = LiveTVPrototypeChannel(
            id: "channel", number: 1, name: "Channel", category: "News",
            symbol: "tv", accent: 0, source: .iptv, tagline: "",
            streamURL: url, playlistSourceID: "source"
        )
        return try LiveTVChannelScanSource(id: "source", generation: "revision", targets: [
            LiveTVChannelScanTarget(channel: channel, policy: LiveTVScanOriginPolicy(streamURL: url))
        ])
    }
}

private actor ScanViewProbe: LiveTVChannelProbing {
    private(set) var calls = 0
    private var continuation: CheckedContinuation<Void, Never>?

    func probe(_ target: LiveTVChannelScanTarget) async throws -> LiveTVChannelProbeResult {
        calls += 1
        await withCheckedContinuation { continuation = $0 }
        return LiveTVChannelProbeResult(status: .reachable, reason: .mediaObserved)
    }

    func waitForStart() async { while continuation == nil { await Task.yield() } }
    func complete() { continuation?.resume(); continuation = nil }
}

private final class ScanViewHealthStore: LiveTVChannelHealthStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [LiveTVChannelHealthRecord] = []
    func load() throws -> [LiveTVChannelHealthRecord] { lock.withLock { records } }
    func save(_ records: [LiveTVChannelHealthRecord]) throws { lock.withLock { self.records = records } }
}
#endif
