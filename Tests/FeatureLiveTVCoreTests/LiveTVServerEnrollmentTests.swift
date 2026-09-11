#if DEBUG
import CoreModels
import Foundation
import XCTest
@testable import FeatureLiveTVCore

@MainActor
final class LiveTVServerEnrollmentTests: XCTestCase {
    func testAllAuthorizedBackendsEnrollWithoutURLsOrTuningAndKeepStableIDs() async throws {
        let context = EnrollmentContext()
        for kind in [LiveTVPrototypeSource.plex, .jellyfin, .emby] {
            context.add(kind.rawValue, kind: kind, provider: EnrollmentProvider(
                result: .init(status: .available, channelCount: 3)
            ))
        }
        let coordinator = LiveTVServerEnrollmentCoordinator()
        let added = await context.refresh(coordinator)
        XCTAssertEqual(added.count, 3)
        XCTAssertEqual(Set(context.configuration.servers.map(\.accountID)), Set(["plex", "jellyfin", "emby"]))
        XCTAssertTrue(context.configuration.servers.allSatisfy {
            $0.id == LiveTVServerEnrollmentCoordinator.sourceID(accountID: $0.accountID)
        })
        let second = await context.refresh(coordinator)
        XCTAssertTrue(second.isEmpty)
        XCTAssertEqual(context.configuration.servers.count, 3)
        for provider in context.providers.values {
            let opens = await provider.opens
            XCTAssertEqual(opens, 0)
        }
    }

    func testAbsentDeniedOfflineSubscriptionAndUnsupportedRemainDistinct() async throws {
        let context = EnrollmentContext()
        let outcomes: [ServerLiveTVAvailability.Status] = [
            .notConfigured, .noChannels, .permissionDenied, .serviceUnavailable,
            .subscriptionRequired, .unsupportedAPI
        ]
        for outcome in outcomes {
            context.add(outcome.rawValue, provider: EnrollmentProvider(result: .init(status: outcome)))
        }
        let coordinator = LiveTVServerEnrollmentCoordinator()
        let added = await context.refresh(coordinator)
        XCTAssertTrue(added.isEmpty)
        XCTAssertEqual(coordinator.statuses.compactMap(\.availability?.status), outcomes)
        XCTAssertTrue(context.configuration.servers.isEmpty)
    }

    func testSuppressedRemovedAndDisabledSourcesAreNotReaddedOrProbed() async throws {
        let context = EnrollmentContext()
        let removed = EnrollmentProvider(result: .init(status: .available, channelCount: 3))
        let disabled = EnrollmentProvider(result: .init(status: .available, channelCount: 3))
        context.add("removed", provider: removed)
        context.add("disabled", provider: disabled)
        context.suppressed = ["removed"]
        context.configuration.servers = [.init(
            id: "manually-added", name: "Disabled source", accountID: "disabled", isEnabled: false
        )]
        let added = await context.refresh(LiveTVServerEnrollmentCoordinator())
        XCTAssertTrue(added.isEmpty)
        XCTAssertEqual(context.configuration.servers.map(\.id), ["manually-added"])
        XCTAssertFalse(context.configuration.servers[0].isEnabled)
        let removedChecks = await removed.checks
        let disabledChecks = await disabled.checks
        XCTAssertEqual(removedChecks, 0)
        XCTAssertEqual(disabledChecks, 0)
    }

    func testRemovalDuringDiscoveryWinsOverLateAvailability() async throws {
        let context = EnrollmentContext()
        let provider = EnrollmentProvider()
        context.add("server", provider: provider)
        let coordinator = LiveTVServerEnrollmentCoordinator()
        let task = Task { await context.refresh(coordinator) }
        await provider.waitUntilRequested()
        context.suppressed.insert("server")
        await provider.finish(.init(status: .available, channelCount: 4))
        let added = await task.value
        XCTAssertTrue(added.isEmpty)
        XCTAssertTrue(context.configuration.servers.isEmpty)
    }

    func testManualAdditionDuringDiscoveryPreservesUserNameAndDisabledChoice() async throws {
        let context = EnrollmentContext()
        let provider = EnrollmentProvider()
        context.add("server", provider: provider)
        let coordinator = LiveTVServerEnrollmentCoordinator()
        let task = Task { await context.refresh(coordinator) }
        await provider.waitUntilRequested()
        let manual = LiveTVServerSource(
            id: "manual-id", name: "My chosen name", accountID: "server", isEnabled: false
        )
        context.configuration.servers = [manual]
        await provider.finish(.init(status: .available, channelCount: 4))
        let added = await task.value
        XCTAssertTrue(added.isEmpty)
        XCTAssertEqual(context.configuration.servers, [manual])
    }

    func testAccountUserChangeAndGenerationInvalidationCannotPublishLateSource() async throws {
        for invalidate in [false, true] {
            let context = EnrollmentContext()
            let provider = EnrollmentProvider()
            context.add("server", provider: provider)
            let coordinator = LiveTVServerEnrollmentCoordinator()
            let task = Task { await context.refresh(coordinator) }
            await provider.waitUntilRequested()
            if invalidate { coordinator.invalidate() }
            else { context.authorization = "different-home-user" }
            await provider.finish(.init(status: .available, channelCount: 4))
            let added = await task.value
            XCTAssertTrue(added.isEmpty)
            XCTAssertTrue(context.configuration.servers.isEmpty)
            if invalidate { XCTAssertTrue(coordinator.statuses.isEmpty) }
            else { XCTAssertEqual(coordinator.statuses.first?.failure, .accountUnavailable) }
        }
    }

    func testCancellationCannotPublishAndExistingUnavailableSourceIsRetained() async throws {
        let context = EnrollmentContext()
        let provider = EnrollmentProvider()
        context.add("server", provider: provider)
        let saved = LiveTVServerSource(id: "saved", name: "Saved", accountID: "server")
        context.configuration.servers = [saved]
        let coordinator = LiveTVServerEnrollmentCoordinator()
        let task = Task { await context.refresh(coordinator) }
        await provider.waitUntilRequested()
        task.cancel()
        await provider.finish(.init(status: .available, channelCount: 4))
        let added = await task.value
        XCTAssertTrue(added.isEmpty)
        XCTAssertEqual(context.configuration.servers, [saved])
        XCTAssertEqual(coordinator.statuses.first?.phase, .idle)
    }

    func testAccountNotInCurrentResolverDoesNotProbeHouseholdFallback() async throws {
        let context = EnrollmentContext()
        let provider = EnrollmentProvider(result: .init(status: .available, channelCount: 4))
        context.add("server", provider: provider)
        context.isAuthorized = false
        let coordinator = LiveTVServerEnrollmentCoordinator()
        _ = await context.refresh(coordinator)
        let checks = await provider.checks
        XCTAssertEqual(checks, 0)
        XCTAssertEqual(coordinator.statuses.first?.failure, .accountUnavailable)
        XCTAssertTrue(context.configuration.servers.isEmpty)
    }

    func testFailedConfigurationWriteIsNotReportedAsServerOfflineOrSuccessfulEnrollment() async throws {
        let context = EnrollmentContext()
        context.add("server", provider: EnrollmentProvider(result: .init(status: .available, channelCount: 4)))
        context.failSave = true
        let coordinator = LiveTVServerEnrollmentCoordinator()
        let added = await context.refresh(coordinator)
        XCTAssertTrue(added.isEmpty)
        XCTAssertTrue(context.configuration.servers.isEmpty)
        XCTAssertEqual(coordinator.statuses.first?.availability?.status, .available)
        XCTAssertEqual(coordinator.statuses.first?.failure, .configurationNotSaved)
        XCTAssertEqual(coordinator.statuses.first?.phase, .failed)
    }

    func testUnreadableRemovalSuppressionFailsClosedBeforeDiscovery() async throws {
        let context = EnrollmentContext()
        let provider = EnrollmentProvider(result: .init(status: .available, channelCount: 4))
        context.add("server", provider: provider)
        context.failSuppressionRead = true
        let coordinator = LiveTVServerEnrollmentCoordinator()
        let added = await context.refresh(coordinator)
        XCTAssertTrue(added.isEmpty)
        XCTAssertTrue(context.configuration.servers.isEmpty)
        XCTAssertEqual(coordinator.statuses.first?.failure, .configurationNotSaved)
        let checks = await provider.checks
        XCTAssertEqual(checks, 0)
    }

    func testUnreadableSourceConfigurationFailsClosedBeforeDiscovery() async throws {
        let context = EnrollmentContext()
        let provider = EnrollmentProvider(result: .init(status: .available, channelCount: 4))
        context.add("server", provider: provider)
        context.failConfigurationRead = true
        let coordinator = LiveTVServerEnrollmentCoordinator()
        let added = await context.refresh(coordinator)
        XCTAssertTrue(added.isEmpty)
        XCTAssertTrue(context.configuration.servers.isEmpty)
        XCTAssertEqual(coordinator.statuses.first?.failure, .configurationNotSaved)
        XCTAssertEqual(context.saveCount, 0)
        let checks = await provider.checks
        XCTAssertEqual(checks, 0)
    }

    func testConfigurationReadFailureAfterDiscoveryCannotOverwriteFromEarlierSnapshot() async throws {
        let context = EnrollmentContext()
        let provider = EnrollmentProvider()
        context.add("server", provider: provider)
        let coordinator = LiveTVServerEnrollmentCoordinator()
        let task = Task { await context.refresh(coordinator) }
        await provider.waitUntilRequested()
        let concurrent = LiveTVServerSource(id: "other-source", name: "Concurrent edit", accountID: "other")
        context.configuration.servers = [concurrent]
        context.failConfigurationRead = true
        await provider.finish(.init(status: .available, channelCount: 4))
        let added = await task.value
        XCTAssertTrue(added.isEmpty)
        XCTAssertEqual(context.configuration.servers, [concurrent])
        XCTAssertEqual(coordinator.statuses.first?.failure, .configurationNotSaved)
        XCTAssertEqual(context.saveCount, 0)
    }
}

@MainActor
private final class EnrollmentContext {
    var configuration = LiveTVSourcesConfiguration.empty
    var suppressed: Set<String> = []
    var choices: [LiveTVServerChoice] = []
    var providers: [String: EnrollmentProvider] = [:]
    var authorization = "profile-user-revision"
    var isAuthorized = true
    var failSave = false
    var failSuppressionRead = false
    var failConfigurationRead = false
    var saveCount = 0

    func add(_ id: String, kind: LiveTVPrototypeSource = .jellyfin, provider: EnrollmentProvider) {
        choices.append(.init(id: id, name: "Fixture \(id)", userName: "User", kind: kind))
        providers[id] = provider
    }

    func refresh(_ coordinator: LiveTVServerEnrollmentCoordinator) async -> [String] {
        await coordinator.refresh(
            choices: choices,
            resolver: { [self] id in
                guard isAuthorized, let provider = providers[id],
                      let choice = choices.first(where: { $0.id == id }) else { return nil }
                return .init(
                    accountID: id, authorizationID: authorization, kind: choice.kind, provider: provider
                )
            },
            configuration: {
                if self.failConfigurationRead { throw AppError.invalidResponse }
                return self.configuration
            },
            suppressedAccountIDs: {
                if self.failSuppressionRead { throw AppError.invalidResponse }
                return self.suppressed
            },
            apply: {
                if self.failSave { throw AppError.invalidResponse }
                self.saveCount += 1
                self.configuration = $0
            }
        )
    }
}

private actor EnrollmentProvider: ServerLiveTVProviding {
    private let result: ServerLiveTVAvailability?
    private(set) var checks = 0
    private(set) var opens = 0
    private var pending: CheckedContinuation<ServerLiveTVAvailability, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(result: ServerLiveTVAvailability? = nil) { self.result = result }

    func liveTVAvailability() async throws -> ServerLiveTVAvailability {
        checks += 1
        if let result { return result }
        return await withCheckedContinuation {
            pending = $0
            waiters.forEach { $0.resume() }
            waiters = []
        }
    }

    func waitUntilRequested() async {
        if checks > 0 { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func finish(_ result: ServerLiveTVAvailability) {
        pending?.resume(returning: result)
        pending = nil
    }

    func liveTVChannels() async throws -> [ServerLiveTVChannel] { [] }
    func liveTVGuide(channelIDs: [String], from: Date, to: Date) async throws -> [ServerLiveTVProgramme] { [] }
    func openLiveTVChannel(id: String) async throws -> any LiveTVStreamLease {
        opens += 1
        throw ServerLiveTVError.tunerUnavailable
    }
}
#endif
