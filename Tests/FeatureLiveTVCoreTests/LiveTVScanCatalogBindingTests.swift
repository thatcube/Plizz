#if DEBUG
import Foundation
import XCTest
@testable import CoreModels
@testable import FeatureLiveTVCore

@MainActor
final class LiveTVScanCatalogBindingTests: XCTestCase {
    func testNewPresentationRevokesOldScanAndRejectsItsLateHealthWrite() async throws {
        let store = ScanMemoryHealthStore()
        let probe = ScanSuspendedProbe()
        let oldModel = LiveTVPrototypeModel(channels: [scanChannel()])
        let oldCoordinator = LiveTVChannelScanCoordinator(store: store, probe: probe)
        let oldBinding = makeBinding(model: oldModel, coordinator: oldCoordinator)
        oldBinding.updateCatalog(configuration(), channels: [scanChannel()])
        oldBinding.setActive(true)
        XCTAssertTrue(oldCoordinator.start(sourceID: "source"))
        await probe.waitForStart()

        let newModel = LiveTVPrototypeModel(channels: [scanChannel()])
        let newCoordinator = LiveTVChannelScanCoordinator(store: store)
        let newBinding = makeBinding(model: newModel, coordinator: newCoordinator)
        newBinding.updateCatalog(configuration(), channels: [scanChannel()])
        newBinding.setActive(true)
        XCTAssertTrue(oldCoordinator.sourceIDs.isEmpty)
        XCTAssertEqual(newCoordinator.sourceIDs, ["source"])
        await probe.complete()
        await probe.waitForReturn()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(try store.load().isEmpty)
        XCTAssertTrue(oldCoordinator.scanHiddenChannelIDs.isEmpty)

        oldBinding.updateCatalog(configuration(), channels: [scanChannel()])
        oldBinding.setActive(true)
        oldBinding.retry()
        XCTAssertTrue(oldCoordinator.sourceIDs.isEmpty)
        XCTAssertEqual(newCoordinator.sourceIDs, ["source"])
        oldBinding.setActive(false)
        oldBinding.setActive(true)
        XCTAssertEqual(oldCoordinator.sourceIDs, ["source"])
        XCTAssertTrue(newCoordinator.sourceIDs.isEmpty)
    }

    func testDifferentProfilesDoNotRevokeOneAnothersScan() {
        let firstModel = LiveTVPrototypeModel(channels: [scanChannel()])
        let first = makeBinding(
            model: firstModel, coordinator: LiveTVChannelScanCoordinator(store: ScanMemoryHealthStore())
        )
        let secondModel = LiveTVPrototypeModel(channels: [scanChannel()])
        let second = makeBinding(
            model: secondModel, coordinator: LiveTVChannelScanCoordinator(store: ScanMemoryHealthStore()),
            profileID: "another-profile"
        )
        first.updateCatalog(configuration(), channels: [scanChannel()])
        second.updateCatalog(configuration(), channels: [scanChannel()])
        first.setActive(true)
        second.setActive(true)
        XCTAssertEqual(first.coordinator.sourceIDs, ["source"])
        XCTAssertEqual(second.coordinator.sourceIDs, ["source"])
    }

    func testCatalogBindsOnlyWhileActiveAndRefreshInvalidatesImmediately() throws {
        let model = LiveTVPrototypeModel(channels: [scanChannel()])
        let coordinator = LiveTVChannelScanCoordinator(store: ScanMemoryHealthStore())
        let binding = makeBinding(model: model, coordinator: coordinator)
        binding.updateCatalog(configuration(), channels: [scanChannel()])
        XCTAssertTrue(coordinator.sourceIDs.isEmpty)
        binding.setActive(true)
        XCTAssertEqual(coordinator.sourceIDs, ["source"])
        binding.invalidate(["source"])
        XCTAssertTrue(coordinator.sourceIDs.isEmpty)
        binding.updateCatalog(configuration(), channels: [scanChannel()])
        XCTAssertEqual(coordinator.sourceIDs, ["source"])
        binding.deactivate()
        XCTAssertTrue(coordinator.sourceIDs.isEmpty)
    }

    func testScanRestorationAndDeactivationDoNotChangeManualHides() async throws {
        let channels = [scanChannel(id: "missing"), scanChannel(id: "manual")]
        let model = LiveTVPrototypeModel(channels: channels)
        model.hideChannel(channels[1])
        let transport = ScanFixtureTransport(responses: [
            "/master.m3u8": [.init(statusCode: 404)]
        ])
        let coordinator = LiveTVChannelScanCoordinator(
            store: ScanMemoryHealthStore(),
            probe: LiveTVChannelProbe(transport: transport, limits: .init(retryDelay: .zero))
        )
        let binding = makeBinding(model: model, coordinator: coordinator)
        binding.updateCatalog(configuration(), channels: channels)
        binding.setActive(true)
        XCTAssertTrue(coordinator.start(sourceID: "source"))
        await coordinator.waitUntilFinished()
        binding.synchronizeVisibility()
        XCTAssertTrue(model.visibleChannels.isEmpty)
        XCTAssertEqual(model.hiddenChannelIDs, ["manual"])
        coordinator.restore(channelID: "missing")
        binding.synchronizeVisibility()
        XCTAssertEqual(model.visibleChannels.map(\.id), ["missing"])
        binding.deactivate()
        XCTAssertEqual(model.hiddenChannelIDs, ["manual"])
        XCTAssertEqual(model.visibleChannels.map(\.id), ["missing"])
    }

    func testWrongProfileCannotBindOrStartRequests() {
        let model = LiveTVPrototypeModel(channels: [scanChannel()])
        let coordinator = LiveTVChannelScanCoordinator(store: ScanMemoryHealthStore())
        let binding = LiveTVScanCatalogBinding(
            profileID: "profile", model: model, coordinator: coordinator,
            authorization: { _ in
                LiveTVSourceAuthorization(profileID: "other", identity: "other", allowedPlaylistIDs: ["source"])
            }
        )
        binding.updateCatalog(configuration(), channels: [scanChannel()])
        binding.setActive(true)
        XCTAssertEqual(binding.issue, .sourceUnavailable)
        XCTAssertTrue(coordinator.sourceIDs.isEmpty)
        XCTAssertEqual(model.visibleChannels.map(\.id), ["channel"])
    }

    func testUnreadableHealthLeavesBrowsingAvailable() {
        let model = LiveTVPrototypeModel(channels: [scanChannel()])
        let coordinator = LiveTVChannelScanCoordinator(store: ScanUnreadableHealthStore())
        let binding = makeBinding(model: model, coordinator: coordinator)
        binding.updateCatalog(configuration(), channels: [scanChannel()])
        binding.setActive(true)
        XCTAssertEqual(binding.issue, .healthLoadFailed)
        XCTAssertFalse(coordinator.canScan(sourceID: "source"))
        XCTAssertEqual(model.visibleChannels.map(\.id), ["channel"])
    }

    private func makeBinding(
        model: LiveTVPrototypeModel, coordinator: LiveTVChannelScanCoordinator,
        profileID: String = "profile"
    ) -> LiveTVScanCatalogBinding {
        LiveTVScanCatalogBinding(
            profileID: profileID, model: model, coordinator: coordinator,
            authorization: { _ in
                LiveTVSourceAuthorization(profileID: profileID, identity: "allowed", allowedPlaylistIDs: ["source"])
            }
        )
    }

    private func configuration() -> LiveTVSourcesConfiguration {
        LiveTVSourcesConfiguration(playlists: [
            LiveTVPlaylistSource(
                id: "source", name: "Fixture", playlistURL: URL(string: "https://fixture.test/channels.m3u")!
            )
        ])
    }
}
#endif
