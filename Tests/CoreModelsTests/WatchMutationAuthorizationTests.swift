import Foundation
import XCTest
@testable import CoreModels

@MainActor
final class WatchMutationAuthorizationTests: XCTestCase {
    private let time = Date(timeIntervalSince1970: 1_700_000_000)

    private func mutation(
        canonical: String = "imdb:tt1", offset: Double = 0,
        targets: [String] = ["origin"], trackers: Bool = false, expansion: Bool = false
    ) -> WatchMutation {
        WatchMutation(
            capturedAt: time.addingTimeInterval(offset), canonicalMediaID: canonical, played: true,
            targets: targets.map { WatchMutationTarget(accountID: $0, itemID: "item") },
            trakt: trackers ? TraktScrobbleIntent(
                kind: .movie, title: "Movie", year: 2025, seasonNumber: nil,
                episodeNumber: nil, providerIDs: ["imdb": "tt1"], progress: 100
            ) : nil,
            expansionPending: expansion,
            identities: MediaItemIdentity.identities(for: MediaItem(
                id: "item", title: "Movie", kind: .movie, productionYear: 2025,
                providerIDs: ["imdb": "tt1", "tmdb": "99"]
            )),
            kind: .movie, anchorTitle: "movie", anchorYear: 2025
        )
    }

    private func guarded(_ mutation: WatchMutation, by consent: OutboxConsent) -> WatchMutation {
        mutation.requiringAuthorization { @MainActor in consent.allowed }
    }

    func testRevokedBeforeEnqueueCannotChangeManualPendingOrClock() async {
        let consent = OutboxConsent()
        let applier = AuthorizedOutboxApplier()
        let reconciler = WatchStateReconciler(store: InMemoryWatchMutationStore(), applier: applier)
        let manual = mutation(targets: ["manual"])
        _ = await reconciler.enqueue(manual)
        let before = await reconciler.snapshot()
        let protected = guarded(mutation(offset: 10, targets: ["protected"]), by: consent)
        consent.allowed = false
        let accepted = await reconciler.enqueue(protected)
        XCTAssertFalse(accepted)
        let after = await reconciler.snapshot()
        XCTAssertEqual(after, before)
        await reconciler.drain()
        let events = await applier.events
        XCTAssertEqual(events, ["played:manual"])
    }

    func testRevokedDuringEnqueueValidationIsNeverPersisted() async {
        let gate = OutboxAuthorizationGate()
        let consent = OutboxConsent()
        let store = InMemoryWatchMutationStore()
        let reconciler = WatchStateReconciler(store: store, applier: AuthorizedOutboxApplier())
        let protected = mutation().requiringAuthorization { @MainActor in
            await gate.pause()
            return consent.allowed
        }
        let enqueue = Task { await reconciler.enqueue(protected) }
        await gate.waitUntilPaused()
        consent.allowed = false
        await gate.open()
        let accepted = await enqueue.value
        XCTAssertFalse(accepted)
        XCTAssertEqual(store.load(), .empty)
    }

    func testRevokedWhileExpansionIsSuspendedNeverReachesAnyWrite() async {
        let gate = OutboxAuthorizationGate()
        let consent = OutboxConsent()
        let applier = AuthorizedOutboxApplier()
        await applier.setExpansionGate(gate)
        let rejected = OutboxAuthorizationRejections()
        let reconciler = WatchStateReconciler(
            store: InMemoryWatchMutationStore(), applier: applier,
            onAuthorizationRejection: { rejected.append($0, $1) }
        )
        let accepted = await reconciler.enqueue(guarded(mutation(trackers: true, expansion: true), by: consent))
        guard accepted else { XCTFail("Valid intent must enqueue"); return }
        let drain = Task { await reconciler.drain() }
        await gate.waitUntilPaused()
        consent.allowed = false
        await gate.open()
        await drain.value
        let events = await applier.events
        XCTAssertTrue(events.isEmpty)
        let snapshot = await reconciler.snapshot()
        XCTAssertTrue(snapshot.pending.isEmpty)
        XCTAssertEqual(rejected.errors, [.denied])
    }

    func testRevocationAfterOriginStopsResumeOtherTargetsAndTrackers() async {
        let consent = OutboxConsent()
        let applier = AuthorizedOutboxApplier()
        await applier.setAfterWrite { event in
            if event == "played:origin" { await MainActor.run { consent.allowed = false } }
        }
        let rejected = OutboxAuthorizationRejections()
        let reconciler = WatchStateReconciler(
            store: InMemoryWatchMutationStore(), applier: applier,
            onAuthorizationRejection: { rejected.append($0, $1) }
        )
        var intent = mutation(targets: ["origin", "other"], trackers: true)
        intent.clearResume = true
        _ = await reconciler.enqueue(guarded(intent, by: consent))
        await reconciler.drain()
        let events = await applier.events
        XCTAssertEqual(events, ["played:origin"])
        XCTAssertEqual(rejected.errors, [.denied])
        let snapshot = await reconciler.snapshot()
        XCTAssertTrue(snapshot.pending.isEmpty)
        XCTAssertTrue(snapshot.appliedTrakt.isEmpty)
    }

    func testRevocationAfterTraktPreservesConfirmedWriteButStopsRemainingMirrors() async {
        let consent = OutboxConsent()
        let applier = AuthorizedOutboxApplier()
        await applier.setAfterWrite { event in
            if event == "trakt" { await MainActor.run { consent.allowed = false } }
        }
        let rejected = OutboxAuthorizationRejections()
        let reconciler = WatchStateReconciler(
            store: InMemoryWatchMutationStore(), applier: applier,
            onAuthorizationRejection: { rejected.append($0, $1) }
        )
        _ = await reconciler.enqueue(guarded(mutation(trackers: true), by: consent))
        await reconciler.drain()
        let events = await applier.events
        XCTAssertEqual(events, ["played:origin", "trakt"])
        let snapshot = await reconciler.snapshot()
        XCTAssertEqual(snapshot.appliedTrakt.count, 1)
        XCTAssertTrue(snapshot.appliedSimkl.isEmpty)
        XCTAssertEqual(rejected.errors, [.denied])
    }

    func testPendingRetryRevalidatesInsteadOfUsingEnqueueTimeConsent() async {
        let consent = OutboxConsent()
        let applier = AuthorizedOutboxApplier()
        await applier.setFailWrites(true)
        let reconciler = WatchStateReconciler(store: InMemoryWatchMutationStore(), applier: applier)
        _ = await reconciler.enqueue(guarded(mutation(), by: consent))
        await reconciler.drain()
        let pending = await reconciler.pendingCount
        XCTAssertEqual(pending, 1)
        consent.allowed = false
        await applier.setFailWrites(false)
        await reconciler.drain()
        let events = await applier.events
        XCTAssertTrue(events.isEmpty)
        let remaining = await reconciler.pendingCount
        XCTAssertEqual(remaining, 0)
    }

    func testRestoredRequirementHasNoRuntimeCapabilityAndCannotDispatch() async throws {
        let consent = OutboxConsent()
        let original = guarded(mutation(trackers: true), by: consent)
        let state = WatchOutboxState(pending: [original], clock: [original.coalesceKey: original.capturedAt])
        let restored = try JSONDecoder().decode(WatchOutboxState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(restored, state)
        XCTAssertNotNil(restored.pending.first?.authorization)
        let rejected = OutboxAuthorizationRejections()
        let applier = AuthorizedOutboxApplier()
        let reconciler = WatchStateReconciler(
            store: InMemoryWatchMutationStore(restored), applier: applier,
            onAuthorizationRejection: { rejected.append($0, $1) }
        )
        await reconciler.drain()
        let events = await applier.events
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(rejected.errors, [.capabilityUnavailable])
        let snapshot = await reconciler.snapshot()
        XCTAssertEqual(snapshot, .empty)
        let retagged = restored.pending[0].requiringAuthorization { true }
        let accepted = await reconciler.enqueue(retagged)
        XCTAssertFalse(accepted, "Retagging cannot erase the original unavailable requirement")
    }

    func testRemovingNullingOrChangingPersistedRequirementCannotDowngradeIt() throws {
        let consent = OutboxConsent()
        let protected = guarded(mutation(), by: consent)
        let data = try JSONEncoder().encode(protected)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for alteration in ["missing", "null", "changed"] {
            var object = original
            switch alteration {
            case "missing": object.removeValue(forKey: "authorization")
            case "null": object["authorization"] = NSNull()
            default: object["authorization"] = ["version": 1, "id": UUID().uuidString]
            }
            XCTAssertThrowsError(try JSONDecoder().decode(
                WatchMutation.self, from: JSONSerialization.data(withJSONObject: object)
            ))
        }
        struct LegacyIdentity: Decodable { let id: UUID }
        XCTAssertThrowsError(try JSONDecoder().decode(LegacyIdentity.self, from: data))
        let ordinary = try JSONEncoder().encode(mutation())
        XCTAssertNoThrow(try JSONDecoder().decode(LegacyIdentity.self, from: ordinary))
    }

    func testValidCompletionRunsOnceAndRetiresTheCapabilityAndClock() async {
        let consent = OutboxConsent()
        let applier = AuthorizedOutboxApplier()
        let reconciler = WatchStateReconciler(store: InMemoryWatchMutationStore(), applier: applier)
        let protected = guarded(mutation(targets: ["origin", "other"], trackers: true), by: consent)
        _ = await reconciler.enqueue(protected)
        await reconciler.drain()
        await reconciler.drain()
        let events = await applier.events
        XCTAssertEqual(events, ["played:origin", "played:other", "trakt", "simkl", "anilist", "mal"])
        let snapshot = await reconciler.snapshot()
        XCTAssertTrue(snapshot.pending.isEmpty)
        XCTAssertNil(snapshot.clock[protected.coalesceKey])
        let acceptedAgain = await reconciler.enqueue(protected)
        XCTAssertFalse(acceptedAgain)
    }

    func testGuardedEvidenceNeverAbsorbsManualTargetsOrTrackerIntent() async {
        let consent = OutboxConsent()
        let applier = AuthorizedOutboxApplier()
        let reconciler = WatchStateReconciler(store: InMemoryWatchMutationStore(), applier: applier)
        var manual = mutation(targets: ["manual"])
        manual.played = false
        _ = await reconciler.enqueue(manual)
        let protected = guarded(mutation(canonical: "tmdb:99", offset: 10, targets: ["protected"], trackers: true), by: consent)
        _ = await reconciler.enqueue(protected)
        let queued = await reconciler.snapshot()
        XCTAssertEqual(queued.pending.count, 2)
        XCTAssertEqual(queued.pending.first, manual)
        consent.allowed = false
        await reconciler.drain()
        let events = await applier.events
        XCTAssertEqual(events, ["played:manual"])
        let after = await reconciler.snapshot()
        XCTAssertEqual(after.clock[manual.coalesceKey], manual.capturedAt)
        XCTAssertNil(after.clock[protected.coalesceKey])
    }

    func testNewerManualEvidenceSupersedesGuardedIntentWithoutInheritingIt() async {
        let consent = OutboxConsent()
        let applier = AuthorizedOutboxApplier()
        let reconciler = WatchStateReconciler(store: InMemoryWatchMutationStore(), applier: applier)
        let protected = guarded(mutation(targets: ["protected"], trackers: true), by: consent)
        _ = await reconciler.enqueue(protected)
        var manual = mutation(canonical: "tmdb:99", offset: 10, targets: ["manual"])
        manual.played = false
        _ = await reconciler.enqueue(manual)
        let queued = await reconciler.snapshot()
        XCTAssertEqual(queued.pending, [manual])
        XCTAssertNil(queued.clock[protected.coalesceKey])
        await reconciler.drain()
        let events = await applier.events
        XCTAssertEqual(events, ["played:manual"])
    }

    func testOrdinaryCoalescingAndClockStayUnchanged() async {
        let applier = AuthorizedOutboxApplier()
        let reconciler = WatchStateReconciler(store: InMemoryWatchMutationStore(), applier: applier)
        let first = mutation(targets: ["first"])
        let second = mutation(offset: 10, targets: ["second"])
        _ = await reconciler.enqueue(first)
        _ = await reconciler.enqueue(second)
        let snapshot = await reconciler.snapshot()
        XCTAssertEqual(snapshot.pending.count, 1)
        XCTAssertEqual(snapshot.pending.first?.id, first.id)
        XCTAssertEqual(snapshot.pending.first?.targets.map(\.accountID), ["second", "first"])
        XCTAssertNil(snapshot.pending.first?.authorization)
        let stale = await reconciler.enqueue(first)
        XCTAssertFalse(stale)
        await reconciler.drain()
        let events = await applier.events
        XCTAssertEqual(events, ["played:second", "played:first"])
    }

    func testUnsupportedApplierFailsClosedOnlyForGuardedIntents() async {
        let consent = OutboxConsent()
        let recorder = AuthorizedOutboxApplier()
        let reconciler = WatchStateReconciler(
            store: InMemoryWatchMutationStore(), applier: UnmarkedOutboxApplier(recorder: recorder)
        )
        let rejected = await reconciler.enqueue(guarded(mutation(), by: consent))
        XCTAssertFalse(rejected)
        let accepted = await reconciler.enqueue(mutation())
        XCTAssertTrue(accepted)
        await reconciler.drain()
        let events = await recorder.events
        XCTAssertEqual(events, ["played:origin"])
    }

    func testFailedGuardedPersistenceDoesNotAcceptOrDeliver() async {
        let consent = OutboxConsent()
        let applier = AuthorizedOutboxApplier()
        let reconciler = WatchStateReconciler(store: AuthorizationFailingStore(), applier: applier)
        let accepted = await reconciler.enqueue(guarded(mutation(), by: consent))
        XCTAssertFalse(accepted)
        await reconciler.drain()
        let snapshot = await reconciler.snapshot()
        XCTAssertEqual(snapshot, .empty)
        let events = await applier.events
        XCTAssertTrue(events.isEmpty)
    }

    func testManualSupersessionDuringExpansionDoesNotInheritOrLoseWork() async {
        let gate = OutboxAuthorizationGate()
        let consent = OutboxConsent()
        let applier = AuthorizedOutboxApplier()
        await applier.setExpansionGate(gate)
        let reconciler = WatchStateReconciler(store: InMemoryWatchMutationStore(), applier: applier)
        let protected = guarded(mutation(targets: ["protected"], trackers: true, expansion: true), by: consent)
        guard await reconciler.enqueue(protected) else { XCTFail("Valid intent must enqueue"); return }
        let drain = Task { await reconciler.drain() }
        await gate.waitUntilPaused()
        var manual = mutation(canonical: "tmdb:99", offset: 10, targets: ["manual"])
        manual.played = false
        _ = await reconciler.enqueue(manual)
        await gate.open()
        await drain.value
        let events = await applier.events
        XCTAssertEqual(events, ["played:manual"])
        let snapshot = await reconciler.snapshot()
        XCTAssertTrue(snapshot.pending.isEmpty)
        XCTAssertTrue(snapshot.appliedTrakt.isEmpty)
    }

    func testCompletedCapabilityReleasesItsValidatorEvenIfCallerRetainsMutation() async {
        var payload: OutboxAuthorizationPayload? = OutboxAuthorizationPayload()
        weak var weakPayload = payload
        let protected = capturing(payload!, in: mutation())
        payload = nil
        XCTAssertNotNil(weakPayload)
        let reconciler = WatchStateReconciler(store: InMemoryWatchMutationStore(), applier: AuthorizedOutboxApplier())
        _ = await reconciler.enqueue(protected)
        await reconciler.drain()
        XCTAssertNil(weakPayload)
        XCTAssertNotNil(protected.authorization)
    }

    func testWeakOwnerTagDoesNotRetainApplicationOwnerAndFailsClosedWhenItDisappears() async {
        var owner: OutboxConsent? = OutboxConsent()
        weak var weakOwner = owner
        let protected = mutation().requiringAuthorization(owner: owner!) { @MainActor owner in owner.allowed }
        owner = nil
        XCTAssertNil(weakOwner)
        let applier = AuthorizedOutboxApplier()
        let reconciler = WatchStateReconciler(store: InMemoryWatchMutationStore(), applier: applier)
        let accepted = await reconciler.enqueue(protected)
        XCTAssertFalse(accepted)
        await reconciler.drain()
        let events = await applier.events
        XCTAssertTrue(events.isEmpty)
    }

    private func capturing(_ payload: OutboxAuthorizationPayload, in mutation: WatchMutation) -> WatchMutation {
        mutation.requiringAuthorization { payload.allowed }
    }
}

private final class OutboxAuthorizationPayload: Sendable {
    let allowed = true
}

@MainActor
private final class OutboxConsent { var allowed = true }

private actor OutboxAuthorizationGate {
    private var paused = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var arrival: CheckedContinuation<Void, Never>?
    func pause() async {
        paused = true
        arrival?.resume()
        arrival = nil
        await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilPaused() async {
        if paused { return }
        await withCheckedContinuation { arrival = $0 }
    }
    func open() { continuation?.resume(); continuation = nil }
}

private actor AuthorizedOutboxApplier: WatchMutationAuthorizationEnforcing {
    private(set) var events: [String] = []
    private var failWrites = false
    private var expansionGate: OutboxAuthorizationGate?
    private var afterWrite: (@Sendable (String) async -> Void)?
    func setFailWrites(_ value: Bool) { failWrites = value }
    func setExpansionGate(_ gate: OutboxAuthorizationGate) { expansionGate = gate }
    func setAfterWrite(_ hook: @escaping @Sendable (String) async -> Void) { afterWrite = hook }
    private func write(_ event: String) async throws {
        try await WatchMutationDeliveryAuthorization.check()
        if failWrites { throw AppError.serverUnreachable }
        events.append(event)
        await afterWrite?(event)
    }
    func setPlayed(_ played: Bool, on target: WatchMutationTarget) async throws {
        try await write("played:\(target.accountID)")
    }
    func setResumePosition(_ seconds: TimeInterval, on target: WatchMutationTarget, capturedAt: Date) async throws {
        try await write("resume:\(target.accountID)")
    }
    func scrobbleTrakt(_ intent: TraktScrobbleIntent) async throws { try await write("trakt") }
    func scrobbleSimkl(_ intent: TraktScrobbleIntent) async throws { try await write("simkl") }
    func scrobbleAniList(_ intent: TraktScrobbleIntent) async throws { try await write("anilist") }
    func scrobbleMAL(_ intent: TraktScrobbleIntent) async throws { try await write("mal") }
    func expandTargets(for mutation: WatchMutation) async -> WatchTargetExpansion {
        await expansionGate?.pause()
        return WatchTargetExpansion(targets: [WatchMutationTarget(accountID: "expanded", itemID: "item")])
    }
}

private struct UnmarkedOutboxApplier: WatchMutationApplying {
    let recorder: AuthorizedOutboxApplier
    func setPlayed(_ played: Bool, on target: WatchMutationTarget) async throws {
        try await recorder.setPlayed(played, on: target)
    }
    func setResumePosition(_ seconds: TimeInterval, on target: WatchMutationTarget, capturedAt: Date) async throws {
        try await recorder.setResumePosition(seconds, on: target, capturedAt: capturedAt)
    }
    func scrobbleTrakt(_ intent: TraktScrobbleIntent) async throws {
        try await recorder.scrobbleTrakt(intent)
    }
}

private final class OutboxAuthorizationRejections: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [WatchMutationAuthorizationError] = []
    var errors: [WatchMutationAuthorizationError] { lock.withLock { values } }
    func append(_ id: UUID, _ error: WatchMutationAuthorizationError) { lock.withLock { values.append(error) } }
}

private struct AuthorizationFailingStore: WatchMutationStoring {
    func load() -> WatchOutboxState { .empty }
    func save(_ state: WatchOutboxState) throws { throw AppError.serverUnreachable }
}
