import CoreModels
import Foundation
import XCTest
@testable import FeatureLiveTVCore

@MainActor
final class LiveTVPlaybackPreparationTests: XCTestCase {
    private func channel(
        _ id: String = "one",
        server: Bool = true,
        url: String? = nil,
        headers: [String: String] = [:]
    ) -> LiveTVPrototypeChannel {
        LiveTVPrototypeChannel(
            id: "ui-\(id)", number: 1, name: "Fixture channel", category: "Fixture",
            symbol: "tv", accent: 0, source: server ? .jellyfin : .iptv, tagline: "",
            streamURL: url.flatMap(URL.init(string:)), httpHeaders: headers,
            configuredSourceID: server ? "server-source" : "playlist"
        )
    }

    private func reference(
        _ id: String = "one",
        authorizationID: String = "profile-one|home-one"
    ) -> LiveTVServerChannelReference {
        LiveTVServerChannelReference(
            sourceID: "server-source", accountID: "account",
            authorizationID: authorizationID, channelID: id
        )
    }

    private func lease(
        _ id: String = "one",
        accountID: String = "account",
        closed: XCTestExpectation? = nil,
        onClose: (@MainActor @Sendable () -> Void)? = nil,
        closeEntered: XCTestExpectation? = nil,
        closeGate: PreparationFixtureGate? = nil
    ) throws -> PreparationFixtureLease {
        PreparationFixtureLease(
            source: .authenticatedHTTP(try AuthenticatedHTTPPlaybackLocator(
                provider: .jellyfin, accountID: accountID,
                credentialRevision: CredentialRevision(), itemID: id,
                deliveryMode: .hls,
                resource: AuthenticatedHTTPResource(
                    pathBase: .configuredBaseURL, path: "Videos/\(id)/master.m3u8"
                ),
                playSessionID: "play-\(id)"
            )),
            closed: closed, onClose: onClose, closeEntered: closeEntered, closeGate: closeGate
        )
    }

    private func owner(_ scope: PreparationFixtureScope) -> LiveTVPlaybackPreparation {
        owner(scope, resolver: PreparationFixtureResolver())
    }

    private func owner(
        _ scope: PreparationFixtureScope, resolver: PreparationFixtureResolver?
    ) -> LiveTVPlaybackPreparation {
        LiveTVPlaybackPreparation(
            serverProviderResolver: { scope.resolve($0) },
            authenticatedHTTPResolver: resolver
        )
    }

    private func prepare(
        _ owner: LiveTVPlaybackPreparation,
        channel: LiveTVPrototypeChannel,
        reference: LiveTVServerChannelReference? = nil,
        scope: PreparationFixtureScope,
        accept: @MainActor () -> Bool = { true }
    ) async -> Bool {
        let profile = scope.profileID
        return await owner.prepare(
            channel,
            serverReference: reference,
            isAuthorized: { scope.authorizes(channel, initiatingProfile: profile) },
            accept: accept
        )
    }

    private func seedIPTV(
        _ owner: LiveTVPlaybackPreparation, scope: PreparationFixtureScope
    ) async -> UUID? {
        let accepted = await prepare(
            owner, channel: channel("old", server: false, url: "https://iptv.invalid/old.m3u8"),
            scope: scope
        )
        XCTAssertTrue(accepted)
        return owner.current?.id
    }

    func testStandaloneIPTVPreservesRuntimeURLHeadersWithoutAnyServerAccount() async throws {
        let scope = PreparationFixtureScope()
        let owner = LiveTVPlaybackPreparation()
        let source = channel(
            server: false,
            url: "https://user:fixture-password@iptv.invalid/live?token=fixture-query",
            headers: ["Authorization": "Bearer fixture-header", "User-Agent": "Fixture player"]
        )
        var accepts = 0
        let accepted = await prepare(owner, channel: source, scope: scope) {
            accepts += 1
            XCTAssertNil(owner.current)
            return true
        }
        let current = try XCTUnwrap(owner.current)
        XCTAssertTrue(accepted)
        XCTAssertEqual(accepts, 1)
        XCTAssertEqual(current.resolvedURL, source.streamURL)
        XCTAssertEqual(current.httpHeaders, source.httpHeaders)
        XCTAssertNil(current.authorizationID)
        XCTAssertNil(current.accountID)
        XCTAssertFalse(owner.isPreparing)
        for secret in ["fixture-password", "fixture-query", "fixture-header"] {
            XCTAssertFalse(String(describing: current).contains(secret))
            XCTAssertFalse(String(reflecting: current).contains(secret))
        }
        owner.stop()
        XCTAssertNil(owner.current)
    }

    func testAcceptanceRunsAfterResolutionAndBeforeCurrentReplacement() async throws {
        let candidate = try lease()
        let provider = PreparationFixtureProvider(["one": [.init(lease: candidate)]])
        let scope = PreparationFixtureScope(provider: provider)
        let resolver = PreparationFixtureResolver()
        let owner = owner(scope, resolver: resolver)
        let oldID = await seedIPTV(owner, scope: scope)
        let accepted = await prepare(owner, channel: channel(), reference: reference(), scope: scope) {
            XCTAssertEqual(resolver.calls.count, 1)
            XCTAssertEqual(owner.current?.id, oldID)
            return true
        }
        XCTAssertTrue(accepted)
        XCTAssertEqual(owner.current?.channel.id, "ui-one")
        XCTAssertNotEqual(owner.current?.id, oldID)
        XCTAssertEqual(owner.current?.authorizationID, scope.authorizationID)
        XCTAssertEqual(owner.current?.httpHeaders, [:])
        await owner.close()
        let closes = await candidate.closeCalls
        XCTAssertEqual(closes, 1)
    }

    func testSameAuthorizedChannelReusesLeaseURLAndStableIdentityButCallsAcceptance() async throws {
        let candidate = try lease()
        let provider = PreparationFixtureProvider(["one": [.init(lease: candidate)]])
        let scope = PreparationFixtureScope(provider: provider)
        let resolver = PreparationFixtureResolver()
        let owner = owner(scope, resolver: resolver)
        var accepts = 0
        let first = await prepare(owner, channel: channel(), reference: reference(), scope: scope) {
            accepts += 1
            return true
        }
        let id = owner.current?.id
        let url = owner.current?.resolvedURL
        let second = await prepare(owner, channel: channel(), reference: reference(), scope: scope) {
            accepts += 1
            return true
        }
        let rejected = await prepare(owner, channel: channel(), reference: reference(), scope: scope) {
            accepts += 1
            return false
        }
        XCTAssertTrue(first)
        XCTAssertTrue(second)
        XCTAssertFalse(rejected)
        XCTAssertEqual(accepts, 3)
        XCTAssertEqual(owner.current?.id, id)
        XCTAssertEqual(owner.current?.resolvedURL, url)
        XCTAssertEqual(resolver.calls.count, 1)
        let opens = await provider.opens
        let beforeClose = await candidate.closeCalls
        XCTAssertEqual(opens, ["one"])
        XCTAssertEqual(beforeClose, 0)
        await owner.close()
        let afterClose = await candidate.closeCalls
        XCTAssertEqual(afterClose, 1)
    }

    func testOpenFailurePreservesCurrentAndDoesNotCommitIntent() async throws {
        let provider = PreparationFixtureProvider(["one": [.init(error: .serverUnreachable)]])
        let scope = PreparationFixtureScope(provider: provider)
        let owner = owner(scope)
        let oldID = await seedIPTV(owner, scope: scope)
        var acceptedIntent = false
        let accepted = await prepare(owner, channel: channel(), reference: reference(), scope: scope) {
            acceptedIntent = true
            return true
        }
        XCTAssertFalse(accepted)
        XCTAssertFalse(acceptedIntent)
        XCTAssertEqual(owner.current?.id, oldID)
        XCTAssertEqual(owner.failure, .networkUnavailable)
        XCTAssertFalse(owner.isPreparing)
        await owner.close()
    }

    func testProviderFailuresKeepPreciseSafeCategoriesAndDoNotRetry() async throws {
        for (serverError, expected) in [
            (ServerLiveTVError.permissionDenied, LiveTVPlaybackPreparationError.permissionDenied),
            (.subscriptionRequired, .subscriptionRequired),
            (.guideRequired, .guideRequired),
            (.tunerUnavailable, .tunerUnavailable),
            (.unsupportedPlaybackMode, .unsupportedPlaybackMode),
            (.noCompatibleStream, .noCompatibleStream)
        ] {
            let provider = PreparationFixtureProvider(["one": [.init(serverError: serverError)]])
            let scope = PreparationFixtureScope(provider: provider)
            let owner = owner(scope)
            let oldID = await seedIPTV(owner, scope: scope)
            let accepted = await prepare(owner, channel: channel(), reference: reference(), scope: scope)
            XCTAssertFalse(accepted)
            XCTAssertEqual(owner.failure, expected)
            XCTAssertEqual(owner.current?.id, oldID)
            let opens = await provider.opens
            XCTAssertEqual(opens, ["one"])
            await owner.close()
        }
        let provider = PreparationFixtureProvider(["one": [.init(error: .unauthorized)]])
        let scope = PreparationFixtureScope(provider: provider)
        let owner = owner(scope)
        _ = await prepare(owner, channel: channel(), reference: reference(), scope: scope)
        XCTAssertEqual(owner.failure, .credentialsExpired)
    }

    func testConnectingServerAfterStandaloneEntryReusesPreparationWithoutStoppingIPTV() async throws {
        let candidate = try lease()
        let provider = PreparationFixtureProvider(["one": [.init(lease: candidate)]])
        let scope = PreparationFixtureScope(provider: provider)
        let context = LiveTVPlaybackResolverContext(
            serverProviderResolver: { _ in nil }, authenticatedHTTPResolver: nil
        )
        let owner = LiveTVPlaybackPreparation(
            serverProviderResolver: { context.provider(for: $0) }, authenticatedHTTPResolver: context
        )
        let previous = await seedIPTV(owner, scope: scope)
        context.update(
            serverProviderResolver: { scope.resolve($0) },
            authenticatedHTTPResolver: PreparationFixtureResolver()
        )
        XCTAssertEqual(owner.current?.id, previous)
        let accepted = await prepare(owner, channel: channel(), reference: reference(), scope: scope)
        XCTAssertTrue(accepted)
        XCTAssertEqual(owner.current?.serverReference, reference())
        XCTAssertNotEqual(owner.current?.id, previous)
        await owner.close()
    }

    func testResolverReplacementFencesAnAlreadyResolvingServerCandidate() async throws {
        let candidate = try lease()
        let provider = PreparationFixtureProvider(["one": [.init(lease: candidate)]])
        let scope = PreparationFixtureScope(provider: provider)
        let entered = expectation(description: "Old resolver entered")
        let gate = PreparationFixtureGate()
        let context = LiveTVPlaybackResolverContext(
            serverProviderResolver: { scope.resolve($0) },
            authenticatedHTTPResolver: PreparationFixtureResolver(["one": .init(entered: entered, gate: gate)])
        )
        let owner = LiveTVPlaybackPreparation(
            serverProviderResolver: { context.provider(for: $0) }, authenticatedHTTPResolver: context
        )
        let previous = await seedIPTV(owner, scope: scope)
        let operation = Task {
            await prepare(owner, channel: channel(), reference: reference(), scope: scope)
        }
        await fulfillment(of: [entered], timeout: 2)
        context.update(serverProviderResolver: { _ in nil }, authenticatedHTTPResolver: nil)
        await gate.release()
        let accepted = await operation.value
        XCTAssertFalse(accepted)
        XCTAssertEqual(owner.current?.id, previous)
        XCTAssertEqual(owner.failure, .authorizationChanged)
        await owner.close()
        let closes = await candidate.closeCalls
        XCTAssertEqual(closes, 1)
    }

    func testResolverReplacementRejectsOldTransportEvenWhenAccountAuthorityIsUnchanged() async throws {
        let candidate = try lease()
        let provider = PreparationFixtureProvider(["one": [.init(lease: candidate)]])
        let scope = PreparationFixtureScope(provider: provider)
        let entered = expectation(description: "Old transport entered")
        let gate = PreparationFixtureGate()
        let context = LiveTVPlaybackResolverContext(
            serverProviderResolver: { scope.resolve($0) },
            authenticatedHTTPResolver: PreparationFixtureResolver(["one": .init(entered: entered, gate: gate)])
        )
        let owner = LiveTVPlaybackPreparation(
            serverProviderResolver: { context.provider(for: $0) }, authenticatedHTTPResolver: context
        )
        let previous = await seedIPTV(owner, scope: scope)
        let operation = Task {
            await prepare(owner, channel: channel(), reference: reference(), scope: scope)
        }
        await fulfillment(of: [entered], timeout: 2)
        context.update(
            serverProviderResolver: { scope.resolve($0) },
            authenticatedHTTPResolver: PreparationFixtureResolver()
        )
        await gate.release()
        let accepted = await operation.value
        XCTAssertFalse(accepted)
        XCTAssertEqual(owner.current?.id, previous)
        XCTAssertEqual(owner.failure, .authorizationChanged)
        await owner.close()
        let closes = await candidate.closeCalls
        XCTAssertEqual(closes, 1)
    }

    func testLibraryPreparationUsesTypedIdentityWithoutInventingAStreamURL() async throws {
        let lookup = LibraryPreparationFixtureLookup()
        let id = try XCTUnwrap(lookup.channelID)
        let source = LiveTVPrototypeChannel(
            id: "library:\(id)", number: 1, name: "Comedy", category: "Plozz",
            symbol: "tv", accent: 0, source: .plozz, tagline: "",
            configuredSourceID: UUID().uuidString
        )
        let owner = LiveTVPlaybackPreparation(libraryChannelResolver: { _ in lookup.reference })
        let first = await owner.prepare(source, isAuthorized: { true }, accept: { true })
        XCTAssertTrue(first)
        XCTAssertEqual(owner.current?.input, .libraryChannel(id: id, authorizationID: lookup.authorizationID))
        XCTAssertEqual(owner.current?.authorizationID, lookup.authorizationID)
        XCTAssertNil(owner.current?.resolvedURL)
        XCTAssertEqual(owner.current?.httpHeaders, [:])
        let preparedID = owner.current?.id
        let repeated = await owner.prepare(source, isAuthorized: { true }, accept: { true })
        XCTAssertTrue(repeated)
        XCTAssertEqual(owner.current?.id, preparedID)
        lookup.channelID = nil
        owner.validateAuthorization()
        XCTAssertNil(owner.current)
        await owner.close()
    }

    func testLibraryCredentialChangeRevokesPreparedIdentityBeforeRetuning() async throws {
        let lookup = LibraryPreparationFixtureLookup()
        let id = try XCTUnwrap(lookup.channelID)
        let channel = LiveTVPrototypeChannel(
            id: "library:\(id)", number: 1, name: "Comedy", category: "Plozz",
            symbol: "tv", accent: 0, source: .plozz, tagline: "",
            configuredSourceID: UUID().uuidString
        )
        let owner = LiveTVPlaybackPreparation(libraryChannelResolver: { _ in lookup.reference })
        let accepted = await owner.prepare(channel, isAuthorized: { true }, accept: { true })
        XCTAssertTrue(accepted)
        let firstID = try XCTUnwrap(owner.current?.id)

        lookup.authorizationID = "new-generation"
        owner.validateAuthorization()
        XCTAssertNil(owner.current)
        XCTAssertEqual(owner.failure, .authorizationChanged)

        let replacement = await owner.prepare(channel, isAuthorized: { true }, accept: { true })
        XCTAssertTrue(replacement)
        XCTAssertNotEqual(owner.current?.id, firstID)
        XCTAssertEqual(owner.current?.authorizationID, lookup.authorizationID)
        await owner.close()
    }

    func testLibraryCredentialChangeDuringAcceptanceKeepsPreviousChannel() async throws {
        let lookup = LibraryPreparationFixtureLookup()
        let id = try XCTUnwrap(lookup.channelID)
        let channel = LiveTVPrototypeChannel(
            id: "library:\(id)", number: 1, name: "Comedy", category: "Plozz",
            symbol: "tv", accent: 0, source: .plozz, tagline: "",
            configuredSourceID: UUID().uuidString
        )
        let owner = LiveTVPlaybackPreparation(libraryChannelResolver: { _ in lookup.reference })
        let previous = await seedIPTV(owner, scope: PreparationFixtureScope())
        let accepted = await owner.prepare(channel, isAuthorized: { true }) {
            lookup.authorizationID = "new-generation"
            return true
        }
        XCTAssertFalse(accepted)
        XCTAssertEqual(owner.current?.id, previous)
        XCTAssertEqual(owner.failure, .authorizationChanged)
        await owner.close()
    }

    func testLibraryPreparationRejectsMissingAuthorizationStamp() async throws {
        let lookup = LibraryPreparationFixtureLookup()
        lookup.authorizationID = ""
        let id = try XCTUnwrap(lookup.channelID)
        let channel = LiveTVPrototypeChannel(
            id: "library:\(id)", number: 1, name: "Comedy", category: "Plozz",
            symbol: "tv", accent: 0, source: .plozz, tagline: "",
            configuredSourceID: UUID().uuidString
        )
        let owner = LiveTVPlaybackPreparation(libraryChannelResolver: { _ in lookup.reference })
        let previous = await seedIPTV(owner, scope: PreparationFixtureScope())
        let accepted = await owner.prepare(channel, isAuthorized: { true }, accept: { true })
        XCTAssertFalse(accepted)
        XCTAssertEqual(owner.current?.id, previous)
        XCTAssertEqual(owner.failure, .authorizationChanged)
        await owner.close()
    }

    func testUnavailableLibraryScheduleKeepsTheCurrentNetworkChannel() async throws {
        let owner = LiveTVPlaybackPreparation(libraryChannelResolver: { _ in
            throw LibraryChannelError.snapshotUnavailable
        })
        let previous = await seedIPTV(owner, scope: PreparationFixtureScope())
        let source = LiveTVPrototypeChannel(
            id: "library:\(UUID())", number: 1, name: "Comedy", category: "Plozz",
            symbol: "tv", accent: 0, source: .plozz, tagline: "",
            configuredSourceID: UUID().uuidString
        )
        let accepted = await owner.prepare(source, isAuthorized: { true }, accept: { true })
        XCTAssertFalse(accepted)
        XCTAssertEqual(owner.current?.id, previous)
        XCTAssertEqual(owner.failure, .libraryUnavailable(.snapshotUnavailable))
        await owner.close()
    }

    func testFailedResolutionClosesCandidateAndNeverExposesSensitiveErrorText() async throws {
        let candidate = try lease()
        let provider = PreparationFixtureProvider(["one": [.init(lease: candidate)]])
        let scope = PreparationFixtureScope(provider: provider)
        let resolver = PreparationFixtureResolver([
            "one": .init(sensitiveFailure: "https://private.invalid/?token=never-display-this")
        ])
        let owner = owner(scope, resolver: resolver)
        let oldID = await seedIPTV(owner, scope: scope)
        let accepted = await prepare(owner, channel: channel(), reference: reference(), scope: scope)
        XCTAssertFalse(accepted)
        XCTAssertEqual(owner.current?.id, oldID)
        XCTAssertEqual(owner.failure, .resolutionFailed)
        XCTAssertFalse(String(localized: owner.failure!.userDescription).contains("never-display"))
        let closes = await candidate.closeCalls
        XCTAssertEqual(closes, 1)
        await owner.close()
    }

    func testRejectedResolvedCandidateClosesWithoutChangingCurrent() async throws {
        let candidate = try lease()
        let provider = PreparationFixtureProvider(["one": [.init(lease: candidate)]])
        let scope = PreparationFixtureScope(provider: provider)
        let owner = owner(scope)
        let oldID = await seedIPTV(owner, scope: scope)
        let accepted = await prepare(
            owner, channel: channel(), reference: reference(), scope: scope, accept: { false }
        )
        XCTAssertFalse(accepted)
        XCTAssertEqual(owner.current?.id, oldID)
        XCTAssertNil(owner.failure)
        let closes = await candidate.closeCalls
        XCTAssertEqual(closes, 1)
        await owner.close()
    }

    func testStopImmediatelyClearsCurrentAndRejectsLateSuccessfulOpen() async throws {
        let opening = expectation(description: "Open entered")
        let gate = PreparationFixtureGate()
        let candidate = try lease()
        let provider = PreparationFixtureProvider([
            "one": [.init(lease: candidate, entered: opening, gate: gate)]
        ])
        let scope = PreparationFixtureScope(provider: provider)
        let resolver = PreparationFixtureResolver()
        let owner = owner(scope, resolver: resolver)
        _ = await seedIPTV(owner, scope: scope)
        let task = Task {
            await prepare(owner, channel: channel(), reference: reference(), scope: scope) {
                XCTFail("Stopped preparation must not accept")
                return true
            }
        }
        await fulfillment(of: [opening], timeout: 2)
        XCTAssertTrue(owner.isPreparing)
        owner.stop()
        XCTAssertNil(owner.current)
        XCTAssertFalse(owner.isPreparing)
        await gate.release()
        let accepted = await task.value
        XCTAssertFalse(accepted)
        XCTAssertNil(owner.current)
        XCTAssertNil(owner.failure)
        XCTAssertTrue(resolver.calls.isEmpty)
        let closes = await candidate.closeCalls
        XCTAssertEqual(closes, 1)
        await owner.close()
    }

    func testCancelledOpenReturningLeaseRollsBackAndKeepsCurrent() async throws {
        let opening = expectation(description: "Open entered")
        let gate = PreparationFixtureGate()
        let candidate = try lease()
        let provider = PreparationFixtureProvider([
            "one": [.init(lease: candidate, entered: opening, gate: gate)]
        ])
        let scope = PreparationFixtureScope(provider: provider)
        let owner = owner(scope)
        let oldID = await seedIPTV(owner, scope: scope)
        let task = Task {
            await prepare(owner, channel: channel(), reference: reference(), scope: scope)
        }
        await fulfillment(of: [opening], timeout: 2)
        task.cancel()
        await gate.release()
        let accepted = await task.value
        XCTAssertFalse(accepted)
        XCTAssertEqual(owner.current?.id, oldID)
        XCTAssertNil(owner.failure)
        let closes = await candidate.closeCalls
        XCTAssertEqual(closes, 1)
        await owner.close()
    }

    func testStopClosesAlreadyOpenedCandidateWithoutWaitingForURLResolver() async throws {
        let resolving = expectation(description: "Resolver entered")
        let closed = expectation(description: "Candidate closed while resolver is suspended")
        let gate = PreparationFixtureGate()
        let candidate = try lease(closed: closed)
        let provider = PreparationFixtureProvider(["one": [.init(lease: candidate)]])
        let scope = PreparationFixtureScope(provider: provider)
        let resolver = PreparationFixtureResolver(["one": .init(entered: resolving, gate: gate)])
        let owner = owner(scope, resolver: resolver)
        let task = Task {
            await prepare(owner, channel: channel(), reference: reference(), scope: scope)
        }
        await fulfillment(of: [resolving], timeout: 2)
        owner.stop()
        await fulfillment(of: [closed], timeout: 2)
        XCTAssertNil(owner.current)
        await gate.release()
        let accepted = await task.value
        XCTAssertFalse(accepted)
        let closes = await candidate.closeCalls
        XCTAssertEqual(closes, 1)
        await owner.close()
    }

    func testCancellationReleasesOpenedCandidateWhileResolverRemainsSuspended() async throws {
        let resolving = expectation(description: "Resolver entered")
        let closed = expectation(description: "Cancelled candidate closes immediately")
        let gate = PreparationFixtureGate()
        let candidate = try lease(closed: closed)
        let provider = PreparationFixtureProvider(["one": [.init(lease: candidate)]])
        let scope = PreparationFixtureScope(provider: provider)
        let resolver = PreparationFixtureResolver(["one": .init(entered: resolving, gate: gate)])
        let owner = owner(scope, resolver: resolver)
        let oldID = await seedIPTV(owner, scope: scope)
        let task = Task {
            await prepare(owner, channel: channel(), reference: reference(), scope: scope)
        }
        await fulfillment(of: [resolving], timeout: 2)
        task.cancel()
        await fulfillment(of: [closed], timeout: 2)
        XCTAssertEqual(owner.current?.id, oldID)
        XCTAssertFalse(owner.isPreparing)
        await gate.release()
        let accepted = await task.value
        XCTAssertFalse(accepted)
        XCTAssertNil(owner.failure)
        let closes = await candidate.closeCalls
        XCTAssertEqual(closes, 1)
        await owner.close()
    }

    func testReplacementCommitsBeforeReleasingPreviousLease() async throws {
        let oldClosed = expectation(description: "Previous lease closes after commit")
        let scope = PreparationFixtureScope()
        let owner = owner(scope)
        let first = try lease("one", closed: oldClosed, onClose: { [weak owner] in
            XCTAssertEqual(owner?.current?.channel.id, "ui-two")
        })
        let second = try lease("two")
        scope.provider = PreparationFixtureProvider([
            "one": [.init(lease: first)], "two": [.init(lease: second)]
        ])
        _ = await prepare(owner, channel: channel("one"), reference: reference("one"), scope: scope)
        let accepted = await prepare(
            owner, channel: channel("two"), reference: reference("two"), scope: scope
        )
        XCTAssertTrue(accepted)
        await fulfillment(of: [oldClosed], timeout: 2)
        let firstCloses = await first.closeCalls
        let secondCloses = await second.closeCalls
        XCTAssertEqual(firstCloses, 1)
        XCTAssertEqual(secondCloses, 0)
        await owner.close()
    }

    func testNewWatchPreparationWinsOverLatePreviewPreparation() async throws {
        let opening = expectation(description: "Older preview open entered")
        let gate = PreparationFixtureGate()
        let older = try lease("one")
        let newer = try lease("two")
        let provider = PreparationFixtureProvider([
            "one": [.init(lease: older, entered: opening, gate: gate)],
            "two": [.init(lease: newer)]
        ])
        let scope = PreparationFixtureScope(provider: provider)
        let owner = owner(scope)
        let preview = Task {
            await prepare(owner, channel: channel("one"), reference: reference("one"), scope: scope) {
                XCTFail("Superseded preview cannot commit")
                return true
            }
        }
        await fulfillment(of: [opening], timeout: 2)
        let watched = await prepare(owner, channel: channel("two"), reference: reference("two"), scope: scope)
        let committedID = owner.current?.id
        await gate.release()
        let previewed = await preview.value
        XCTAssertTrue(watched)
        XCTAssertFalse(previewed)
        XCTAssertEqual(owner.current?.id, committedID)
        XCTAssertEqual(owner.current?.channel.id, "ui-two")
        XCTAssertNil(owner.failure)
        let oldCloses = await older.closeCalls
        let newCloses = await newer.closeCalls
        XCTAssertEqual(oldCloses, 1)
        XCTAssertEqual(newCloses, 0)
        await owner.close()
    }

    func testLateFailureCannotOverwriteNewerSuccessfulPreparation() async throws {
        let opening = expectation(description: "Older open entered")
        let gate = PreparationFixtureGate()
        let provider = PreparationFixtureProvider([
            "one": [.init(error: .serverUnreachable, entered: opening, gate: gate)]
        ])
        let scope = PreparationFixtureScope(provider: provider)
        let owner = owner(scope)
        let older = Task {
            await prepare(owner, channel: channel(), reference: reference(), scope: scope)
        }
        await fulfillment(of: [opening], timeout: 2)
        let currentID = await seedIPTV(owner, scope: scope)
        await gate.release()
        let accepted = await older.value
        XCTAssertFalse(accepted)
        XCTAssertEqual(owner.current?.id, currentID)
        XCTAssertNil(owner.failure)
        XCTAssertFalse(owner.isPreparing)
        await owner.close()
    }

    func testAlreadyCancelledCallDoesNotSupersedeCurrentOrAccept() async throws {
        let scope = PreparationFixtureScope()
        let owner = LiveTVPlaybackPreparation()
        let currentID = await seedIPTV(owner, scope: scope)
        let gate = PreparationFixtureGate()
        let task = Task {
            await gate.wait()
            return await prepare(
                owner, channel: channel(server: false, url: "https://iptv.invalid/new"),
                scope: scope
            ) {
                XCTFail("An already-cancelled task cannot commit")
                return true
            }
        }
        task.cancel()
        await gate.release()
        let accepted = await task.value
        XCTAssertFalse(accepted)
        XCTAssertEqual(owner.current?.id, currentID)
        XCTAssertFalse(owner.isPreparing)
        await owner.close()
    }

    func testRevokedAccountAfterOpenRejectsBeforeAuthenticatedResolution() async throws {
        let opening = expectation(description: "Open entered")
        let gate = PreparationFixtureGate()
        let candidate = try lease()
        let provider = PreparationFixtureProvider([
            "one": [.init(lease: candidate, entered: opening, gate: gate)]
        ])
        let scope = PreparationFixtureScope(provider: provider)
        let resolver = PreparationFixtureResolver()
        let owner = owner(scope, resolver: resolver)
        let task = Task {
            await prepare(owner, channel: channel(), reference: reference(), scope: scope)
        }
        await fulfillment(of: [opening], timeout: 2)
        scope.accountEnabled = false
        await gate.release()
        let accepted = await task.value
        XCTAssertFalse(accepted)
        XCTAssertEqual(owner.failure, .accountUnavailable)
        XCTAssertTrue(resolver.calls.isEmpty)
        let closes = await candidate.closeCalls
        XCTAssertEqual(closes, 1)
        await owner.close()
    }

    func testHomeUserChangeDuringResolutionIsRejectedAndCandidateClosed() async throws {
        let resolving = expectation(description: "Resolver entered")
        let gate = PreparationFixtureGate()
        let candidate = try lease()
        let provider = PreparationFixtureProvider(["one": [.init(lease: candidate)]])
        let scope = PreparationFixtureScope(provider: provider)
        let resolver = PreparationFixtureResolver(["one": .init(entered: resolving, gate: gate)])
        let owner = owner(scope, resolver: resolver)
        let oldID = await seedIPTV(owner, scope: scope)
        let task = Task {
            await prepare(owner, channel: channel(), reference: reference(), scope: scope)
        }
        await fulfillment(of: [resolving], timeout: 2)
        scope.homeUserID = "home-two"
        await gate.release()
        let accepted = await task.value
        XCTAssertFalse(accepted)
        XCTAssertEqual(owner.current?.id, oldID, "IPTV remains authorized during a server Home-user change")
        XCTAssertEqual(owner.failure, .authorizationChanged)
        let closes = await candidate.closeCalls
        XCTAssertEqual(closes, 1)
        await owner.close()
    }

    func testSourceRemovalDuringOpenDoesNotAuthorizeThroughAccountMembershipAlone() async throws {
        let opening = expectation(description: "Open entered")
        let gate = PreparationFixtureGate()
        let candidate = try lease()
        let provider = PreparationFixtureProvider([
            "one": [.init(lease: candidate, entered: opening, gate: gate)]
        ])
        let scope = PreparationFixtureScope(provider: provider)
        let owner = owner(scope)
        let oldID = await seedIPTV(owner, scope: scope)
        let task = Task {
            await prepare(owner, channel: channel(), reference: reference(), scope: scope)
        }
        await fulfillment(of: [opening], timeout: 2)
        scope.enabledSources.remove("server-source")
        await gate.release()
        let accepted = await task.value
        XCTAssertFalse(accepted)
        XCTAssertEqual(owner.current?.id, oldID)
        XCTAssertEqual(owner.failure, .sourceUnavailable)
        let closes = await candidate.closeCalls
        XCTAssertEqual(closes, 1)
        await owner.close()
    }

    func testStaleCatalogAuthorizationIsRejectedBeforeOpening() async throws {
        let provider = PreparationFixtureProvider([:])
        let scope = PreparationFixtureScope(provider: provider)
        scope.homeUserID = "home-two"
        let owner = owner(scope)
        let accepted = await prepare(owner, channel: channel(), reference: reference(), scope: scope)
        XCTAssertFalse(accepted)
        XCTAssertEqual(owner.failure, .authorizationChanged)
        let opens = await provider.opens
        XCTAssertTrue(opens.isEmpty)
    }

    func testSameChannelWithNewAuthorizationCannotReuseOldLease() async throws {
        let first = try lease()
        let second = try lease()
        let provider = PreparationFixtureProvider(["one": [.init(lease: first), .init(lease: second)]])
        let scope = PreparationFixtureScope(provider: provider)
        let owner = owner(scope)
        let initial = await prepare(owner, channel: channel(), reference: reference(), scope: scope)
        let oldID = owner.current?.id
        scope.homeUserID = "home-two"
        let replacement = await prepare(
            owner, channel: channel(),
            reference: reference(authorizationID: scope.authorizationID), scope: scope
        )
        XCTAssertTrue(initial)
        XCTAssertTrue(replacement)
        XCTAssertNotEqual(owner.current?.id, oldID)
        XCTAssertEqual(owner.current?.authorizationID, scope.authorizationID)
        await owner.close()
        let opens = await provider.opens
        let firstCloses = await first.closeCalls
        let secondCloses = await second.closeCalls
        XCTAssertEqual(opens, ["one", "one"])
        XCTAssertEqual(firstCloses, 1)
        XCTAssertEqual(secondCloses, 1)
    }

    func testProfileChangeSynchronouslyRevokesCurrentAndReporting() async throws {
        let closed = expectation(description: "Revoked current closes")
        let candidate = try lease(closed: closed)
        let provider = PreparationFixtureProvider(["one": [.init(lease: candidate)]])
        let scope = PreparationFixtureScope(provider: provider)
        let owner = owner(scope)
        _ = await prepare(owner, channel: channel(), reference: reference(), scope: scope)
        await owner.report(.init(state: .started))
        scope.profileID = "profile-two"
        XCTAssertFalse(owner.validateAuthorization())
        XCTAssertNil(owner.current)
        await owner.report(.init(state: .playing))
        await fulfillment(of: [closed], timeout: 2)
        let reports = await candidate.reports
        XCTAssertEqual(reports.map(\.state), [.started])
        await owner.close()
    }

    func testIndependentOwnersDoNotCloseEachOthersLeases() async throws {
        let first = try lease("one")
        let second = try lease("two")
        let provider = PreparationFixtureProvider([
            "one": [.init(lease: first)], "two": [.init(lease: second)]
        ])
        let scope = PreparationFixtureScope(provider: provider)
        let firstOwner = owner(scope)
        let secondOwner = owner(scope)
        _ = await prepare(firstOwner, channel: channel("one"), reference: reference("one"), scope: scope)
        _ = await prepare(secondOwner, channel: channel("two"), reference: reference("two"), scope: scope)
        await firstOwner.close()
        await firstOwner.close()
        await secondOwner.report(.init(state: .playing, positionSeconds: 8))
        XCTAssertNil(firstOwner.current)
        XCTAssertEqual(secondOwner.current?.channel.id, "ui-two")
        let firstCloses = await first.closeCalls
        let secondCloses = await second.closeCalls
        let reports = await second.reports
        XCTAssertEqual(firstCloses, 1)
        XCTAssertEqual(secondCloses, 0)
        XCTAssertEqual(reports.last?.positionSeconds, 8)
        await secondOwner.close()
    }

    func testCloseWaitsForLateOpenRollbackWhileClearingStateImmediately() async throws {
        let opening = expectation(description: "Open entered")
        let closing = expectation(description: "Close entered")
        let gate = PreparationFixtureGate()
        let candidate = try lease()
        let provider = PreparationFixtureProvider([
            "one": [.init(lease: candidate, entered: opening, gate: gate)]
        ])
        let scope = PreparationFixtureScope(provider: provider)
        let owner = owner(scope)
        _ = await seedIPTV(owner, scope: scope)
        let preparation = Task {
            await prepare(owner, channel: channel(), reference: reference(), scope: scope)
        }
        await fulfillment(of: [opening], timeout: 2)
        var drained = false
        let drain = Task {
            closing.fulfill()
            await owner.close()
            drained = true
        }
        await fulfillment(of: [closing], timeout: 2)
        XCTAssertNil(owner.current)
        XCTAssertFalse(owner.isPreparing)
        XCTAssertFalse(drained)
        await gate.release()
        _ = await preparation.value
        await drain.value
        XCTAssertTrue(drained)
        let closes = await candidate.closeCalls
        XCTAssertEqual(closes, 1)
    }

    func testAuthenticatedLocatorForDifferentAccountIsRejectedWithoutResolving() async throws {
        let candidate = try lease(accountID: "another-account")
        let provider = PreparationFixtureProvider(["one": [.init(lease: candidate)]])
        let scope = PreparationFixtureScope(provider: provider)
        let resolver = PreparationFixtureResolver()
        let owner = owner(scope, resolver: resolver)
        let accepted = await prepare(owner, channel: channel(), reference: reference(), scope: scope)
        XCTAssertFalse(accepted)
        XCTAssertEqual(owner.failure, .authorizationChanged)
        XCTAssertTrue(resolver.calls.isEmpty)
        let closes = await candidate.closeCalls
        XCTAssertEqual(closes, 1)
    }

    func testMissingAuthenticatedResolverClosesLeaseInsteadOfCastingToURL() async throws {
        let candidate = try lease()
        let provider = PreparationFixtureProvider(["one": [.init(lease: candidate)]])
        let scope = PreparationFixtureScope(provider: provider)
        let owner = owner(scope, resolver: nil)
        let accepted = await prepare(owner, channel: channel(), reference: reference(), scope: scope)
        XCTAssertFalse(accepted)
        XCTAssertEqual(owner.failure, .resolverUnavailable)
        let closes = await candidate.closeCalls
        XCTAssertEqual(closes, 1)
    }

    func testNetworkFilePlaybackSourceIsExplicitlyUnsupportedAndReleased() async throws {
        let source = PlaybackSource.networkFile(try NetworkFileLocator(
            accountID: "account", sourceID: "share", credentialRevision: CredentialRevision(),
            relativePath: "channel.ts",
            representation: RemoteFileRepresentation(
                size: 100, identity: RemoteFileIdentity(kind: .snapshot, value: "fixture"),
                consistency: .stronglyBound
            )
        ))
        let candidate = PreparationFixtureLease(source: source)
        let provider = PreparationFixtureProvider(["one": [.init(lease: candidate)]])
        let scope = PreparationFixtureScope(provider: provider)
        let owner = owner(scope)
        let accepted = await prepare(owner, channel: channel(), reference: reference(), scope: scope)
        XCTAssertFalse(accepted)
        XCTAssertEqual(owner.failure, .unsupportedPlaybackMode)
        let closes = await candidate.closeCalls
        XCTAssertEqual(closes, 1)
    }

    func testAcceptanceCannotResurrectAnOwnerStoppedByThatCallback() async throws {
        let candidate = try lease()
        let provider = PreparationFixtureProvider(["one": [.init(lease: candidate)]])
        let scope = PreparationFixtureScope(provider: provider)
        let owner = owner(scope)
        let accepted = await prepare(owner, channel: channel(), reference: reference(), scope: scope) {
            owner.stop()
            return true
        }
        XCTAssertFalse(accepted)
        XCTAssertNil(owner.current)
        XCTAssertFalse(owner.isPreparing)
        let closes = await candidate.closeCalls
        XCTAssertEqual(closes, 1)
    }

    func testChangedIPTVURLWithSameChannelIDCreatesNewPreparedIdentity() async throws {
        let scope = PreparationFixtureScope()
        let owner = LiveTVPlaybackPreparation()
        _ = await prepare(
            owner, channel: channel(server: false, url: "https://iptv.invalid/old"), scope: scope
        )
        let previousID = owner.current?.id
        let accepted = await prepare(
            owner, channel: channel(server: false, url: "https://iptv.invalid/new"), scope: scope
        )
        XCTAssertTrue(accepted)
        XCTAssertNotEqual(owner.current?.id, previousID)
        XCTAssertEqual(owner.current?.resolvedURL?.path, "/new")
        owner.stop()
    }

    func testMalformedIPTVHeadersNeverReachAcceptance() async throws {
        for value in [
            "fixture\r\nAuthorization: injected",
            "fixture\rAuthorization: injected",
            "fixture\nAuthorization: injected",
            "fixture\0injected"
        ] {
            let scope = PreparationFixtureScope()
            let owner = LiveTVPlaybackPreparation()
            let source = channel(
                server: false, url: "https://iptv.invalid/live",
                headers: ["User-Agent": value]
            )
            XCTAssertEqual(source.httpHeaders["User-Agent"], value,
                           "The model preserves input; preparation must enforce the HTTP boundary")
            let accepted = await prepare(owner, channel: source, scope: scope) {
                XCTFail("Invalid headers cannot become player input")
                return true
            }
            XCTAssertFalse(accepted)
            XCTAssertEqual(owner.failure, .invalidResponse)
            XCTAssertNil(owner.current)
        }
    }

    func testValidIPTVHeadersPreserveUnicodeAndHorizontalWhitespace() async throws {
        let scope = PreparationFixtureScope()
        let owner = LiveTVPlaybackPreparation()
        let headers = ["User-Agent": "Fixture/1.0 café", "X-Channel-Name": "Culture \t Live"]
        let accepted = await prepare(
            owner,
            channel: channel(
                server: false, url: "https://iptv.invalid/live",
                headers: headers
            ),
            scope: scope
        )
        XCTAssertTrue(accepted)
        XCTAssertEqual(owner.current?.httpHeaders, headers)
        owner.stop()
    }

    func testPublicHTTPServerLeaseDoesNotRequireAuthenticatedResolver() async throws {
        let url = URL(string: "https://cdn.invalid/channel.m3u8")!
        let candidate = PreparationFixtureLease(source: .publicURL(try SecretFreeURLSource(url: url)))
        let provider = PreparationFixtureProvider(["one": [.init(lease: candidate)]])
        let scope = PreparationFixtureScope(provider: provider)
        let owner = owner(scope, resolver: nil)
        let accepted = await prepare(owner, channel: channel(), reference: reference(), scope: scope)
        XCTAssertTrue(accepted)
        XCTAssertEqual(owner.current?.resolvedURL, url)
        await owner.close()
        let closes = await candidate.closeCalls
        XCTAssertEqual(closes, 1)
    }

    func testCurrentFailurePreservesDifferentTargetDuringOpenAndResolution() async throws {
        for suspendResolution in [false, true] {
            let pending = expectation(description: "Replacement suspended")
            let failedClosed = expectation(description: "Failed current released")
            let gate = PreparationFixtureGate()
            let first = try lease("one", closed: failedClosed)
            let second = try lease("two")
            let provider = PreparationFixtureProvider([
                "one": [.init(lease: first)],
                "two": [.init(
                    lease: second, entered: suspendResolution ? nil : pending,
                    gate: suspendResolution ? nil : gate
                )]
            ])
            let scope = PreparationFixtureScope(provider: provider)
            let resolver = PreparationFixtureResolver(
                suspendResolution ? ["two": .init(entered: pending, gate: gate)] : [:]
            )
            let owner = owner(scope, resolver: resolver)
            _ = await prepare(owner, channel: channel("one"), reference: reference("one"), scope: scope)
            let firstID = try XCTUnwrap(owner.current?.id)
            let replacement = Task {
                await prepare(owner, channel: channel("two"), reference: reference("two"), scope: scope)
            }
            await fulfillment(of: [pending], timeout: 2)

            let disposition = owner.failCurrent(id: firstID, reason: .networkUnavailable)
            XCTAssertEqual(disposition, .awaitingReplacement(channelID: "ui-two"))
            XCTAssertNil(owner.current)
            XCTAssertTrue(owner.isPreparing)
            XCTAssertEqual(owner.preparingChannelID, "ui-two")
            XCTAssertNil(owner.failure, "The old player failure must not overwrite target preparation state")
            await fulfillment(of: [failedClosed], timeout: 2)
            let secondClosesBeforeResolution = await second.closeCalls
            XCTAssertEqual(secondClosesBeforeResolution, 0)

            await gate.release()
            let accepted = await replacement.value
            XCTAssertTrue(accepted, "Current failure must not invalidate the replacement generation")
            XCTAssertEqual(owner.current?.channel.id, "ui-two")
            XCTAssertNil(owner.failure)
            await owner.close()
            let firstCloses = await first.closeCalls
            let secondCloses = await second.closeCalls
            XCTAssertEqual(firstCloses, 1)
            XCTAssertEqual(secondCloses, 1)
        }
    }

    func testCurrentFailureWithoutReplacementReturnsStoppedAndCannotBeReused() async throws {
        let first = try lease()
        let second = try lease()
        let provider = PreparationFixtureProvider(["one": [.init(lease: first), .init(lease: second)]])
        let scope = PreparationFixtureScope(provider: provider)
        let resolver = PreparationFixtureResolver()
        let owner = owner(scope, resolver: resolver)
        _ = await prepare(owner, channel: channel(), reference: reference(), scope: scope)
        let firstID = try XCTUnwrap(owner.current?.id)
        XCTAssertEqual(owner.failCurrent(id: firstID), .stopped)
        XCTAssertNil(owner.current)
        XCTAssertFalse(owner.isPreparing)
        XCTAssertEqual(owner.failure, .playbackFailed)
        XCTAssertEqual(owner.failCurrent(id: firstID), .ignored)

        let accepted = await prepare(owner, channel: channel(), reference: reference(), scope: scope)
        XCTAssertTrue(accepted)
        XCTAssertNotEqual(owner.current?.id, firstID)
        XCTAssertNil(owner.failure)
        XCTAssertEqual(resolver.calls.count, 2)
        XCTAssertEqual(owner.failCurrent(id: firstID), .ignored)
        XCTAssertNotNil(owner.current)
        await owner.close()
        let opens = await provider.opens
        let firstCloses = await first.closeCalls
        let secondCloses = await second.closeCalls
        XCTAssertEqual(opens, ["one", "one"])
        XCTAssertEqual(firstCloses, 1)
        XCTAssertEqual(secondCloses, 1)
    }

    func testLatePlayerFailureAndProgressCannotTargetAReplacementLease() async throws {
        let first = try lease("one")
        let second = try lease("two")
        let provider = PreparationFixtureProvider([
            "one": [.init(lease: first)], "two": [.init(lease: second)]
        ])
        let scope = PreparationFixtureScope(provider: provider)
        let owner = owner(scope)
        _ = await prepare(owner, channel: channel("one"), reference: reference("one"), scope: scope)
        let firstID = try XCTUnwrap(owner.current?.id)
        _ = await prepare(owner, channel: channel("two"), reference: reference("two"), scope: scope)
        let secondID = try XCTUnwrap(owner.current?.id)
        XCTAssertEqual(owner.failCurrent(id: firstID), .ignored)
        await owner.report(.init(state: .started), for: firstID)
        await owner.report(.init(state: .paused), for: firstID)
        await owner.report(.init(state: .started), for: secondID)
        XCTAssertEqual(owner.current?.id, secondID)
        XCTAssertNil(owner.failure)
        let secondReports = await second.reports
        XCTAssertEqual(secondReports.map(\.state), [.started])
        await owner.close()
    }

    func testFailureCleanupDoesNotRetainDestroyedOwnerWhileCloseIsSuspended() async throws {
        let closeEntered = expectation(description: "Failed lease close entered")
        let closed = expectation(description: "Failed lease close completed")
        let gate = PreparationFixtureGate()
        let candidate = try lease(closed: closed, closeEntered: closeEntered, closeGate: gate)
        let provider = PreparationFixtureProvider(["one": [.init(lease: candidate)]])
        let scope = PreparationFixtureScope(provider: provider)
        var preparation: LiveTVPlaybackPreparation? = owner(scope)
        _ = await prepare(preparation!, channel: channel(), reference: reference(), scope: scope)
        let id = try XCTUnwrap(preparation?.current?.id)
        XCTAssertEqual(preparation?.failCurrent(id: id), .stopped)
        await fulfillment(of: [closeEntered], timeout: 2)

        weak var weakOwner = preparation
        preparation = nil
        XCTAssertNil(weakOwner, "Background cleanup must not retain the presentation owner")
        await gate.release()
        await fulfillment(of: [closed], timeout: 2)
        let closes = await candidate.closeCalls
        XCTAssertEqual(closes, 1)
    }

    func testProfileBoundResolverReturningNilRevokesCurrentWithoutFallback() async throws {
        let candidate = try lease()
        let provider = PreparationFixtureProvider(["one": [.init(lease: candidate)]])
        let scope = PreparationFixtureScope(provider: provider)
        let profile = scope.profileID
        let owner = LiveTVPlaybackPreparation(
            serverProviderResolver: {
                scope.profileID == profile ? scope.resolve($0) : nil
            },
            authenticatedHTTPResolver: PreparationFixtureResolver()
        )
        let accepted = await owner.prepare(
            channel(), serverReference: reference(), isAuthorized: { true }, accept: { true }
        )
        XCTAssertTrue(accepted)
        scope.profileID = "profile-two"
        XCTAssertFalse(owner.validateAuthorization())
        XCTAssertNil(owner.current)
        XCTAssertEqual(owner.failure, .accountUnavailable)
        await owner.close()
        let closes = await candidate.closeCalls
        XCTAssertEqual(closes, 1)
    }

    func testConsentedStopWaitsForOwnedCleanupBeforeManualRetry() async throws {
        let closing = expectation(description: "Owned cleanup entered")
        let gate = PreparationFixtureGate()
        let first = try lease("one", closeEntered: closing, closeGate: gate)
        let second = try lease("two")
        let provider = PreparationFixtureProvider([
            "one": [.init(lease: first)], "two": [.init(lease: second)]
        ])
        let scope = PreparationFixtureScope(provider: provider)
        let owner = owner(scope)
        _ = await prepare(owner, channel: channel("one"), reference: reference("one"), scope: scope)
        let currentID = try XCTUnwrap(owner.current?.id)
        XCTAssertEqual(owner.current?.accountID, "account")
        var returned = false
        let stop = Task {
            let canRetry = await owner.stopAndWait(currentID: currentID, accountID: "account")
            returned = true
            return canRetry
        }
        await fulfillment(of: [closing], timeout: 2)
        XCTAssertNil(owner.current)
        XCTAssertFalse(returned)
        let beforeCleanup = await provider.opens
        XCTAssertEqual(beforeCleanup, ["one"], "Stopping never opens or automatically retries a target")
        await gate.release()
        let canRetry = await stop.value
        XCTAssertTrue(canRetry)
        let accepted = await prepare(
            owner, channel: channel("two"), reference: reference("two"), scope: scope
        )
        XCTAssertTrue(accepted)
        await owner.close()
        let firstCloses = await first.closeCalls
        let opens = await provider.opens
        XCTAssertEqual(firstCloses, 1)
        XCTAssertEqual(opens, ["one", "two"])
    }

    func testConsentedStopRejectsWrongAccountStaleIdentityAndStandaloneIPTV() async throws {
        let candidate = try lease()
        let provider = PreparationFixtureProvider(["one": [.init(lease: candidate)]])
        let scope = PreparationFixtureScope(provider: provider)
        let owner = owner(scope)
        _ = await prepare(owner, channel: channel(), reference: reference(), scope: scope)
        let id = try XCTUnwrap(owner.current?.id)
        let wrongAccount = await owner.stopAndWait(currentID: id, accountID: "another-account")
        let stale = await owner.stopAndWait(currentID: UUID(), accountID: "account")
        XCTAssertFalse(wrongAccount)
        XCTAssertFalse(stale)
        XCTAssertEqual(owner.current?.id, id)
        let closes = await candidate.closeCalls
        XCTAssertEqual(closes, 0)
        await owner.close()

        let seededIPTV = await seedIPTV(owner, scope: scope)
        let iptvID = try XCTUnwrap(seededIPTV)
        let iptvStop = await owner.stopAndWait(currentID: iptvID, accountID: "account")
        XCTAssertFalse(iptvStop)
        XCTAssertEqual(owner.current?.id, iptvID)
        XCTAssertNil(owner.current?.accountID)
        await owner.close()
    }

    func testNewPreparationDuringConsentedCleanupSuppressesTheOlderRetry() async throws {
        let closing = expectation(description: "Current cleanup entered")
        let gate = PreparationFixtureGate()
        let first = try lease("one", closeEntered: closing, closeGate: gate)
        let second = try lease("two")
        let provider = PreparationFixtureProvider([
            "one": [.init(lease: first)], "two": [.init(lease: second)]
        ])
        let scope = PreparationFixtureScope(provider: provider)
        let owner = owner(scope)
        _ = await prepare(owner, channel: channel("one"), reference: reference("one"), scope: scope)
        let id = try XCTUnwrap(owner.current?.id)
        let stop = Task { await owner.stopAndWait(currentID: id, accountID: "account") }
        await fulfillment(of: [closing], timeout: 2)
        let accepted = await prepare(
            owner, channel: channel("two"), reference: reference("two"), scope: scope
        )
        XCTAssertTrue(accepted)
        let replacementID = owner.current?.id
        await gate.release()
        let canRetry = await stop.value
        XCTAssertFalse(canRetry, "An older consent must not reopen its target over a newer user action")
        XCTAssertEqual(owner.current?.id, replacementID)
        let secondCloses = await second.closeCalls
        XCTAssertEqual(secondCloses, 0)
        await owner.close()
    }

    func testCancelledConsentedStopStillDrainsButDoesNotAuthorizeRetry() async throws {
        let closing = expectation(description: "Current cleanup entered")
        let gate = PreparationFixtureGate()
        let candidate = try lease(closeEntered: closing, closeGate: gate)
        let provider = PreparationFixtureProvider(["one": [.init(lease: candidate)]])
        let scope = PreparationFixtureScope(provider: provider)
        let owner = owner(scope)
        _ = await prepare(owner, channel: channel(), reference: reference(), scope: scope)
        let id = try XCTUnwrap(owner.current?.id)
        let stop = Task { await owner.stopAndWait(currentID: id, accountID: "account") }
        await fulfillment(of: [closing], timeout: 2)
        stop.cancel()
        await gate.release()
        let canRetry = await stop.value
        XCTAssertFalse(canRetry)
        XCTAssertNil(owner.current)
        let closes = await candidate.closeCalls
        let opens = await provider.opens
        XCTAssertEqual(closes, 1)
        XCTAssertEqual(opens, ["one"])
        await owner.close()
    }

    func testAuthorizationChangeDuringConsentedCleanupSuppressesRetry() async throws {
        for changesProfile in [false, true] {
            let closing = expectation(description: "Current cleanup entered")
            let gate = PreparationFixtureGate()
            let candidate = try lease(closeEntered: closing, closeGate: gate)
            let provider = PreparationFixtureProvider(["one": [.init(lease: candidate)]])
            let scope = PreparationFixtureScope(provider: provider)
            let owner = owner(scope)
            _ = await prepare(owner, channel: channel(), reference: reference(), scope: scope)
            let id = try XCTUnwrap(owner.current?.id)
            let stop = Task { await owner.stopAndWait(currentID: id, accountID: "account") }
            await fulfillment(of: [closing], timeout: 2)
            if changesProfile { scope.profileID = "profile-two" }
            else { scope.homeUserID = "home-two" }
            await gate.release()
            let canRetry = await stop.value
            XCTAssertFalse(canRetry)
            XCTAssertNil(owner.current)
            let closes = await candidate.closeCalls
            XCTAssertEqual(closes, 1)
            await owner.close()
        }
    }

    func testOldConfirmationCannotInterruptAnAlreadyPreparingTarget() async throws {
        let opening = expectation(description: "Newer target open entered")
        let gate = PreparationFixtureGate()
        let first = try lease("one")
        let second = try lease("two")
        let provider = PreparationFixtureProvider([
            "one": [.init(lease: first)],
            "two": [.init(lease: second, entered: opening, gate: gate)]
        ])
        let scope = PreparationFixtureScope(provider: provider)
        let owner = owner(scope)
        _ = await prepare(owner, channel: channel("one"), reference: reference("one"), scope: scope)
        let firstID = try XCTUnwrap(owner.current?.id)
        let replacement = Task {
            await prepare(owner, channel: channel("two"), reference: reference("two"), scope: scope)
        }
        await fulfillment(of: [opening], timeout: 2)
        let canRetry = await owner.stopAndWait(currentID: firstID, accountID: "account")
        XCTAssertFalse(canRetry)
        XCTAssertEqual(owner.current?.id, firstID)
        XCTAssertTrue(owner.isPreparing)
        let firstCloses = await first.closeCalls
        XCTAssertEqual(firstCloses, 0)
        await gate.release()
        let accepted = await replacement.value
        XCTAssertTrue(accepted)
        XCTAssertEqual(owner.current?.channel.id, "ui-two")
        await owner.close()
    }

    private func multiview(
        _ scope: PreparationFixtureScope, primary: LiveTVPlaybackPreparation
    ) -> LiveTVMultiviewCoordinator {
        let profile = scope.profileID
        let authorizationID = scope.authorizationID
        return LiveTVMultiviewCoordinator(
            primary: primary, makePreparation: { self.owner(scope) },
            reference: {
                LiveTVServerChannelReference(
                    sourceID: "server-source", accountID: "account",
                    authorizationID: authorizationID, channelID: String($0.dropFirst(3))
                )
            },
            authorizes: { channel, _ in scope.authorizes(channel, initiatingProfile: profile) },
            recordWatched: { _ in }
        )
    }

    func testMultiviewExitKeepsSelectedLeaseAndGatesAdmissionUntilRetiredCleanup() async throws {
        let closing = expectation(description: "First pane closing")
        let closeGate = PreparationFixtureGate()
        let first = try lease("one", closeEntered: closing, closeGate: closeGate)
        let second = try lease("two")
        let provider = PreparationFixtureProvider([
            "one": [.init(lease: first)], "two": [.init(lease: second)]
        ])
        let scope = PreparationFixtureScope(provider: provider)
        let primary = owner(scope)
        _ = await prepare(primary, channel: channel(), reference: reference(), scope: scope)
        let coordinator = multiview(scope, primary: primary)
        coordinator.begin()
        await coordinator.add(channel("two"))?.value
        let survivor = coordinator.panes[1]
        coordinator.selectAudio(survivor.id)
        XCTAssertTrue(coordinator.exit() === survivor.preparation)
        await fulfillment(of: [closing], timeout: 2)
        let selectedCloses = await second.closeCalls
        XCTAssertEqual(selectedCloses, 0)
        XCTAssertTrue(coordinator.begin())
        XCTAssertFalse(coordinator.canAdd)
        XCTAssertNil(coordinator.add(channel("three")))
        let opens = await provider.opens
        XCTAssertEqual(opens, ["one", "two"])
        await closeGate.release()
        await coordinator.close()
        let firstCloses = await first.closeCalls
        let secondCloses = await second.closeCalls
        XCTAssertEqual(firstCloses, 1)
        XCTAssertEqual(secondCloses, 1)
    }

    func testMultiviewRemovedPendingPaneClosesLateLeaseWithoutDisturbingPrimary() async throws {
        let opening = expectation(description: "Second pane opening")
        let gate = PreparationFixtureGate()
        let first = try lease("one")
        let second = try lease("two")
        let provider = PreparationFixtureProvider([
            "one": [.init(lease: first)], "two": [.init(lease: second, entered: opening, gate: gate)]
        ])
        let scope = PreparationFixtureScope(provider: provider)
        let primary = owner(scope)
        _ = await prepare(primary, channel: channel(), reference: reference(), scope: scope)
        let preparedID = primary.current?.id
        let coordinator = multiview(scope, primary: primary)
        coordinator.begin()
        let pending = coordinator.add(channel("two"))
        await fulfillment(of: [opening], timeout: 2)
        coordinator.remove(coordinator.panes[1].id)
        await gate.release()
        await pending?.value
        XCTAssertEqual(coordinator.panes.count, 1)
        XCTAssertEqual(primary.current?.id, preparedID)
        let beforeClose = await first.closeCalls
        XCTAssertEqual(beforeClose, 0)
        await coordinator.close()
        let firstCloses = await first.closeCalls
        let secondCloses = await second.closeCalls
        XCTAssertEqual(firstCloses, 1)
        XCTAssertEqual(secondCloses, 1)
    }

    func testMultiviewSourceRevocationStopsBothOwnersAndRemovesRequestedMetadata() async throws {
        let first = try lease("one")
        let second = try lease("two")
        let provider = PreparationFixtureProvider([
            "one": [.init(lease: first)], "two": [.init(lease: second)]
        ])
        let scope = PreparationFixtureScope(provider: provider)
        let primary = owner(scope)
        _ = await prepare(primary, channel: channel(), reference: reference(), scope: scope)
        let coordinator = multiview(scope, primary: primary)
        coordinator.begin()
        await coordinator.add(channel("two"))?.value
        scope.enabledSources.remove("server-source")
        coordinator.validateAuthorization()
        XCTAssertTrue(coordinator.panes.allSatisfy { $0.channel == nil })
        XCTAssertTrue(coordinator.panes.allSatisfy { $0.preparation.current == nil })
        await coordinator.close()
        let firstCloses = await first.closeCalls
        let secondCloses = await second.closeCalls
        XCTAssertEqual(firstCloses, 1)
        XCTAssertEqual(secondCloses, 1)
    }

    func testMultiviewFailedPaneDoesNotReleaseOrReopenSibling() async throws {
        let first = try lease("one")
        let second = try lease("two")
        let provider = PreparationFixtureProvider([
            "one": [.init(lease: first)], "two": [.init(lease: second)]
        ])
        let scope = PreparationFixtureScope(provider: provider)
        let primary = owner(scope)
        _ = await prepare(primary, channel: channel(), reference: reference(), scope: scope)
        let preparedID = primary.current?.id
        let coordinator = multiview(scope, primary: primary)
        coordinator.begin()
        await coordinator.add(channel("two"))?.value
        let secondPane = coordinator.panes[1]
        coordinator.playbackFailed(secondPane.id, preparedID: try XCTUnwrap(secondPane.preparation.current?.id))
        await secondPane.preparation.close()
        XCTAssertEqual(primary.current?.id, preparedID)
        let firstClosesBeforeExit = await first.closeCalls
        let secondCloses = await second.closeCalls
        let opens = await provider.opens
        XCTAssertEqual(firstClosesBeforeExit, 0)
        XCTAssertEqual(secondCloses, 1)
        XCTAssertEqual(opens, ["one", "two"])
        await coordinator.close()
    }

    func testDeinitializingOwnerReleasesItsCurrentLease() async throws {
        let closed = expectation(description: "Destroyed owner releases lease")
        let candidate = try lease(closed: closed)
        let provider = PreparationFixtureProvider(["one": [.init(lease: candidate)]])
        let scope = PreparationFixtureScope(provider: provider)
        var preparation: LiveTVPlaybackPreparation? = owner(scope)
        _ = await prepare(
            preparation!, channel: channel(), reference: reference(), scope: scope
        )
        weak var weakOwner = preparation
        preparation = nil
        XCTAssertNil(weakOwner)
        await fulfillment(of: [closed], timeout: 2)
        let closes = await candidate.closeCalls
        XCTAssertEqual(closes, 1)
    }
}

@MainActor
private final class PreparationFixtureScope {
    var profileID = "profile-one"
    var homeUserID = "home-one"
    var accountEnabled = true
    var enabledSources: Set<String> = ["playlist", "server-source"]
    var provider: (any ServerLiveTVProviding)?
    var authorizationID: String { "\(profileID)|\(homeUserID)" }

    init(provider: (any ServerLiveTVProviding)? = nil) {
        self.provider = provider
    }

    func resolve(_ accountID: String) -> LiveTVAuthorizedServerProvider? {
        guard accountEnabled, accountID == "account", let provider else { return nil }
        return LiveTVAuthorizedServerProvider(
            accountID: accountID, authorizationID: authorizationID,
            kind: .jellyfin, provider: provider
        )
    }

    func authorizes(_ channel: LiveTVPrototypeChannel, initiatingProfile: String) -> Bool {
        profileID == initiatingProfile && enabledSources.contains(channel.configuredSourceID ?? "")
    }
}

@MainActor
private final class LibraryPreparationFixtureLookup {
    var channelID: UUID? = UUID()
    var authorizationID = "original-generation"
    var reference: LiveTVLibraryChannelReference? {
        channelID.map { LiveTVLibraryChannelReference(channelID: $0, authorizationID: authorizationID) }
    }
}

private actor PreparationFixtureGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor PreparationFixtureLease: LiveTVStreamLease {
    nonisolated let playbackSource: PlaybackSource
    private let closed: XCTestExpectation?
    private let onClose: (@MainActor @Sendable () -> Void)?
    private let closeEntered: XCTestExpectation?
    private let closeGate: PreparationFixtureGate?
    private(set) var closeCalls = 0
    private(set) var reports: [LiveTVPlaybackUpdate] = []

    init(
        source: PlaybackSource, closed: XCTestExpectation? = nil,
        onClose: (@MainActor @Sendable () -> Void)? = nil,
        closeEntered: XCTestExpectation? = nil,
        closeGate: PreparationFixtureGate? = nil
    ) {
        playbackSource = source
        self.closed = closed
        self.onClose = onClose
        self.closeEntered = closeEntered
        self.closeGate = closeGate
    }

    func report(_ update: LiveTVPlaybackUpdate) {
        reports.append(update)
    }

    func close() async {
        closeCalls += 1
        closeEntered?.fulfill()
        await closeGate?.wait()
        await onClose?()
        closed?.fulfill()
    }
}

private actor PreparationFixtureProvider: ServerLiveTVProviding {
    struct Reply: Sendable {
        var lease: PreparationFixtureLease?
        var error: AppError?
        var serverError: ServerLiveTVError?
        var entered: XCTestExpectation?
        var gate: PreparationFixtureGate?
    }
    private var replies: [String: [Reply]]
    private(set) var opens: [String] = []

    init(_ replies: [String: [Reply]]) { self.replies = replies }

    func liveTVAvailability() -> ServerLiveTVAvailability {
        ServerLiveTVAvailability(status: .available, channelCount: replies.count)
    }

    func liveTVChannels() -> [ServerLiveTVChannel] { [] }

    func liveTVGuide(channelIDs: [String], from: Date, to: Date) -> [ServerLiveTVProgramme] { [] }

    func openLiveTVChannel(id: String) async throws -> any LiveTVStreamLease {
        opens.append(id)
        guard var matches = replies[id], let reply = matches.first else {
            XCTFail("Unstubbed channel open")
            throw AppError.notFound
        }
        if matches.count > 1 {
            matches.removeFirst()
            replies[id] = matches
        }
        reply.entered?.fulfill()
        await reply.gate?.wait()
        if let error = reply.error { throw error }
        if let error = reply.serverError { throw error }
        guard let lease = reply.lease else { throw AppError.invalidResponse }
        return lease
    }
}

@MainActor
private final class PreparationFixtureResolver: AuthenticatedHTTPResourceResolving {
    struct Reply {
        var error: AppError?
        var sensitiveFailure: String?
        var entered: XCTestExpectation?
        var gate: PreparationFixtureGate?
    }
    private let replies: [String: Reply]
    private(set) var calls: [AuthenticatedHTTPPlaybackLocator] = []

    init(_ replies: [String: Reply] = [:]) { self.replies = replies }

    func resolve(_ locator: AuthenticatedHTTPPlaybackLocator) async throws -> URL {
        calls.append(locator)
        let reply = replies[locator.itemID]
        reply?.entered?.fulfill()
        await reply?.gate?.wait()
        if let error = reply?.error { throw error }
        if let sensitiveFailure = reply?.sensitiveFailure {
            throw PreparationSensitiveFixtureError(text: sensitiveFailure)
        }
        return URL(string: "https://server.invalid/\(locator.itemID)/master.m3u8?api_key=fixture-resolved-secret")!
    }
}

private struct PreparationSensitiveFixtureError: Error {
    let text: String
}
