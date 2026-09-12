#if DEBUG
import CoreModels
import Foundation
import XCTest
@testable import FeatureLiveTVCore

@MainActor
final class LiveTVServerProbeTests: XCTestCase {
    func testNoTunerHasUsefulAvailabilityWithoutOpeningPlayback() async throws {
        let provider = ProbeTestProvider(result: .init(status: .notConfigured))
        let context = ProbeTestContext(provider: provider)
        let model = LiveTVServerProbeModel(resolver: context.resolver)
        model.beginCheck(context.choice)
        await model.perform(try XCTUnwrap(model.pendingRequest))
        XCTAssertEqual(model.availability?.status, .notConfigured)
        XCTAssertFalse(model.canAdd)
        let opens = await provider.openCount
        XCTAssertEqual(opens, 0)
    }

    func testGuideOnlyServerRequiresExplicitGuideOnlyAddition() async throws {
        let provider = ProbeTestProvider(result: .init(status: .unsupportedPlaybackMode, channelCount: 12))
        let context = ProbeTestContext(provider: provider)
        let model = LiveTVServerProbeModel(resolver: context.resolver)
        model.beginCheck(context.choice)
        await model.perform(try XCTUnwrap(model.pendingRequest))
        XCTAssertTrue(model.canAdd)
        XCTAssertFalse(try XCTUnwrap(model.availability).supportsPlayback)
        XCTAssertEqual(try model.checkedChoice(), context.choice)
    }

    func testPermissionFailureDoesNotLookLikeAnEmptyServer() async throws {
        let provider = ProbeTestProvider(error: .permissionDenied)
        let context = ProbeTestContext(provider: provider)
        let model = LiveTVServerProbeModel(resolver: context.resolver)
        model.beginCheck(context.choice)
        await model.perform(try XCTUnwrap(model.pendingRequest))
        XCTAssertEqual(model.failure, .permissionDenied)
        XCTAssertNil(model.availability)
        XCTAssertFalse(model.canAdd)
    }

    func testSubscriptionRequiredIsNotPresentedAsAddableOrUnconfigured() async throws {
        let provider = ProbeTestProvider(result: .init(status: .subscriptionRequired))
        let context = ProbeTestContext(provider: provider)
        let model = LiveTVServerProbeModel(resolver: context.resolver)
        model.beginCheck(context.choice)
        await model.perform(try XCTUnwrap(model.pendingRequest))
        XCTAssertEqual(model.availability?.status, .subscriptionRequired)
        XCTAssertFalse(model.canAdd)
    }

    func testProviderKindAndEmptyAuthorizationCannotApproveAnotherIdentity() async throws {
        let provider = ProbeTestProvider(result: .init(status: .available, channelCount: 4))
        let context = ProbeTestContext(provider: provider)
        let model = LiveTVServerProbeModel { id in
            .init(accountID: id, authorizationID: "", kind: .plex, provider: provider)
        }
        model.beginCheck(context.choice)
        await model.perform(try XCTUnwrap(model.pendingRequest))
        XCTAssertEqual(model.failure, .accountUnavailable)
        XCTAssertFalse(model.canAdd)
    }

    func testRevokedAccountCannotPublishLateAvailability() async throws {
        let provider = ProbeTestProvider()
        let context = ProbeTestContext(provider: provider)
        let model = LiveTVServerProbeModel(resolver: context.resolver)
        model.beginCheck(context.choice)
        let request = try XCTUnwrap(model.pendingRequest)
        let task = Task { await model.perform(request) }
        await provider.waitUntilRequested()
        context.authorized = false
        await provider.finish(.init(status: .available, channelCount: 30))
        await task.value
        XCTAssertEqual(model.failure, .accountUnavailable)
        XCTAssertNil(model.availability)
        XCTAssertFalse(model.canAdd)
    }

    func testChangedAuthorizationMustBeRecheckedBeforeSaving() async throws {
        let provider = ProbeTestProvider(result: .init(status: .available, channelCount: 30))
        let context = ProbeTestContext(provider: provider)
        let model = LiveTVServerProbeModel(resolver: context.resolver)
        model.beginCheck(context.choice)
        await model.perform(try XCTUnwrap(model.pendingRequest))
        context.authorizationID = "different-profile-user"
        XCTAssertThrowsError(try model.checkedChoice())
        XCTAssertFalse(model.canAdd)
        XCTAssertEqual(model.failure, .accountUnavailable)
    }

    func testCancelledCheckCannotPublishItsResult() async throws {
        let provider = ProbeTestProvider()
        let context = ProbeTestContext(provider: provider)
        let model = LiveTVServerProbeModel(resolver: context.resolver)
        model.beginCheck(context.choice)
        let request = try XCTUnwrap(model.pendingRequest)
        let task = Task { await model.perform(request) }
        await provider.waitUntilRequested()
        task.cancel()
        await provider.finish(.init(status: .available, channelCount: 30))
        await task.value
        XCTAssertFalse(model.isChecking)
        XCTAssertNil(model.availability)
        XCTAssertFalse(model.canAdd)
    }

    func testLateOldCheckCannotReplaceNewSelection() async throws {
        let first = ProbeTestProvider()
        let second = ProbeTestProvider(result: .init(status: .noChannels))
        let firstContext = ProbeTestContext(provider: first)
        let secondContext = ProbeTestContext(provider: second, accountID: "second")
        let model = LiveTVServerProbeModel { id in
            id == firstContext.choice.id ? firstContext.resolver(id) : secondContext.resolver(id)
        }
        model.beginCheck(firstContext.choice)
        let firstRequest = try XCTUnwrap(model.pendingRequest)
        let task = Task { await model.perform(firstRequest) }
        await first.waitUntilRequested()
        model.beginCheck(secondContext.choice)
        await model.perform(try XCTUnwrap(model.pendingRequest))
        await first.finish(.init(status: .available, channelCount: 30))
        await task.value
        XCTAssertEqual(model.choice, secondContext.choice)
        XCTAssertEqual(model.availability?.status, .noChannels)
        XCTAssertFalse(model.canAdd)
    }
}

@MainActor
private final class ProbeTestContext {
    let choice: LiveTVServerChoice
    let provider: ProbeTestProvider
    var authorized = true
    var authorizationID = "original-profile-user"

    init(provider: ProbeTestProvider, accountID: String = "account") {
        self.provider = provider
        choice = LiveTVServerChoice(id: accountID, name: "Fixture server", userName: "Fixture user", kind: .jellyfin)
    }

    var resolver: LiveTVServerProviderResolver {
        { [self] id in
            guard authorized, id == choice.id else { return nil }
            return LiveTVAuthorizedServerProvider(
                accountID: id, authorizationID: authorizationID, kind: choice.kind, provider: provider
            )
        }
    }
}

private actor ProbeTestProvider: ServerLiveTVProviding {
    let result: ServerLiveTVAvailability?
    let error: ServerLiveTVError?
    private(set) var openCount = 0
    private var requested = false
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    private var response: CheckedContinuation<ServerLiveTVAvailability, Never>?

    init(result: ServerLiveTVAvailability) { self.result = result; error = nil }
    init(error: ServerLiveTVError) { result = nil; self.error = error }
    init() { result = nil; error = nil }

    func liveTVAvailability() async throws -> ServerLiveTVAvailability {
        if let error { markRequested(); throw error }
        if let result { markRequested(); return result }
        return await withCheckedContinuation {
            response = $0
            markRequested()
        }
    }

    func waitUntilRequested() async {
        if requested { return }
        await withCheckedContinuation { requestWaiters.append($0) }
    }

    func finish(_ result: ServerLiveTVAvailability) {
        guard let response else {
            XCTFail("No delayed probe is waiting for a response")
            return
        }
        self.response = nil
        response.resume(returning: result)
    }

    private func markRequested() {
        requested = true
        requestWaiters.forEach { $0.resume() }
        requestWaiters.removeAll()
    }

    func liveTVChannels() async throws -> [ServerLiveTVChannel] { [] }
    func liveTVGuide(channelIDs: [String], from: Date, to: Date) async throws -> [ServerLiveTVProgramme] { [] }
    func openLiveTVChannel(id: String) async throws -> any LiveTVStreamLease {
        openCount += 1
        throw ServerLiveTVError.unsupportedPlaybackMode
    }
}
#endif
