#if DEBUG
import CoreModels
import Foundation
import Observation

public struct LiveTVLibraryChannelReference: Equatable, Sendable {
    public let channelID: UUID
    public let authorizationID: String

    public init(channelID: UUID, authorizationID: String) {
        self.channelID = channelID
        self.authorizationID = authorizationID
    }
}

/// Runtime-only player input. Resolved URLs and headers may contain credentials.
public struct LiveTVPreparedStream: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let channel: LiveTVPrototypeChannel
    public let input: LiveChannelInput
    public let authorizationID: String?
    public let serverReference: LiveTVServerChannelReference?

    public var resolvedURL: URL? {
        guard case .stream(let url, _) = input else { return nil }
        return url
    }

    public var httpHeaders: [String: String] {
        guard case .stream(_, let headers) = input else { return [:] }
        return headers
    }

    /// The account whose tuner lease this stream owns; nil for IPTV and library channels.
    public var accountID: String? { serverReference?.accountID }
}

extension LiveTVPreparedStream: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "LiveTVPreparedStream(\(id.uuidString))" }
    public var debugDescription: String { description }
}

public enum LiveTVPlaybackFailureDisposition: Equatable, Sendable {
    case ignored
    case awaitingReplacement(channelID: String)
    case stopped
}

public enum LiveTVPlaybackPreparationError: Error, Equatable, Sendable {
    case sourceUnavailable
    case accountUnavailable
    case authorizationChanged
    case credentialsExpired
    case permissionDenied
    case subscriptionRequired
    case guideRequired
    case tunerUnavailable
    case unsupportedPlaybackMode
    case noCompatibleStream
    case resolverUnavailable
    case resolutionFailed
    case networkUnavailable
    case rateLimited
    case channelUnavailable
    case invalidResponse
    case preparationFailed
    case playbackFailed
    case libraryUnavailable(LibraryChannelError)

    public var userDescription: LocalizedStringResource {
        switch self {
        case .sourceUnavailable:
            "This channel's source isn't available to the current profile."
        case .accountUnavailable:
            "This server account isn't available to the current profile."
        case .authorizationChanged:
            "The active profile or server user changed. Choose the channel again."
        case .credentialsExpired:
            "Your server session has expired. Sign in again to watch this channel."
        case .permissionDenied:
            "This server account doesn't have permission to watch Live TV."
        case .subscriptionRequired:
            "This server requires an active subscription for Live TV."
        case .guideRequired:
            "Configure this channel's guide on the server before watching."
        case .tunerUnavailable:
            "No tuner is currently available. Keep watching or try again later."
        case .unsupportedPlaybackMode:
            "This channel's playback mode isn't supported."
        case .noCompatibleStream:
            "The server couldn't provide a compatible stream for this channel."
        case .resolverUnavailable:
            "Authenticated server playback isn't available here."
        case .resolutionFailed:
            "The authenticated stream couldn't be resolved. Check your server account and try again."
        case .networkUnavailable:
            "The stream couldn't be reached. Check your network and server."
        case .rateLimited:
            "The server is asking us to slow down. Try again in a moment."
        case .channelUnavailable:
            "This channel is no longer available."
        case .invalidResponse:
            "The server returned an invalid stream response."
        case .preparationFailed:
            "This channel couldn't be prepared. Try again."
        case .playbackFailed:
            "This channel stopped playing. Try again or choose another channel."
        case .libraryUnavailable(let error):
            error.message
        }
    }

    fileprivate static func sanitized(_ error: any Error, resolving: Bool) -> Self? {
        if error is CancellationError { return nil }
        if let error = error as? Self { return error }
        if let error = error as? LibraryChannelError { return .libraryUnavailable(error) }
        if let error = error as? ServerLiveTVError {
            switch error {
            case .permissionDenied: return .permissionDenied
            case .subscriptionRequired: return .subscriptionRequired
            case .guideRequired: return .guideRequired
            case .tunerUnavailable: return .tunerUnavailable
            case .unsupportedAPI, .unsupportedPlaybackMode: return .unsupportedPlaybackMode
            case .noCompatibleStream: return .noCompatibleStream
            case .invalidChannel: return .channelUnavailable
            case .invalidGuideWindow: return .invalidResponse
            }
        }
        if let error = error as? AppError {
            switch error {
            case .cancelled: return nil
            case .unauthorized, .invalidCredentials: return .credentialsExpired
            case .serverUnreachable: return .networkUnavailable
            case .rateLimited: return .rateLimited
            case .conflict: return .tunerUnavailable
            case .notFound: return .channelUnavailable
            case .invalidResponse, .decoding: return .invalidResponse
            default: return resolving ? .resolutionFailed : .preparationFailed
            }
        }
        if let error = error as? URLError {
            switch error.code {
            case .cancelled: return nil
            case .badURL, .unsupportedURL: return .unsupportedPlaybackMode
            default: return .networkUnavailable
            }
        }
        return resolving ? .resolutionFailed : .preparationFailed
    }
}

/// Own one player preparation, independently of preview/fullscreen presentation.
/// No resolution result becomes current until its synchronous acceptance succeeds.
@MainActor
@Observable
public final class LiveTVPlaybackPreparation {
    public private(set) var current: LiveTVPreparedStream?
    public private(set) var preparingChannelID: String?
    public private(set) var failure: LiveTVPlaybackPreparationError?
    public var isPreparing: Bool { preparingChannelID != nil }

    @ObservationIgnored private var serverProviderResolver: LiveTVServerProviderResolver
    @ObservationIgnored private var authenticatedHTTPResolver: (any AuthenticatedHTTPResourceResolving)?
    @ObservationIgnored private let libraryChannelResolver: @MainActor @Sendable (
        LiveTVPrototypeChannel
    ) throws -> LiveTVLibraryChannelReference?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var currentBinding: Binding?
    @ObservationIgnored private var preparingBinding: Binding?
    @ObservationIgnored private var currentLease: PreparedLiveTVLeaseOwner?
    @ObservationIgnored private var pendingLeases: [UUID: PreparedLiveTVLeaseOwner] = [:]
    @ObservationIgnored private var cleanups: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var operations: [UUID: LiveTVPreparationCompletion] = [:]

    public init(
        serverProviderResolver: @escaping LiveTVServerProviderResolver = { _ in nil },
        authenticatedHTTPResolver: (any AuthenticatedHTTPResourceResolving)? = nil,
        libraryChannelResolver: @escaping @MainActor @Sendable (
            LiveTVPrototypeChannel
        ) throws -> LiveTVLibraryChannelReference? = { _ in nil }
    ) {
        self.serverProviderResolver = serverProviderResolver
        self.authenticatedHTTPResolver = authenticatedHTTPResolver
        self.libraryChannelResolver = libraryChannelResolver
    }

    deinit {
        let leases = Array(pendingLeases.values) + (currentLease.map { [$0] } ?? [])
        Task.detached {
            await withTaskGroup(of: Void.self) { group in
                for lease in leases { group.addTask { await lease.close() } }
            }
        }
    }

    /// Rebinding an owner is an authority boundary, not a credential fallback.
    public func setResolvers(
        serverProviderResolver: @escaping LiveTVServerProviderResolver,
        authenticatedHTTPResolver: (any AuthenticatedHTTPResourceResolving)?
    ) {
        stop()
        self.serverProviderResolver = serverProviderResolver
        self.authenticatedHTTPResolver = authenticatedHTTPResolver
    }

    /// `isAuthorized` must consult live source/profile membership, not a captured
    /// Boolean or merely the filtered/visible guide rows. It is rechecked after
    /// every awaited open/resolve. Capture the initiating profile identity too.
    /// The closure is retained while current: capture the needed models weakly
    /// and profile identity by value, not the owning view or this owner.
    ///
    /// `accept` commits preview/watch intent synchronously after resolution. A
    /// rejection never changes the current stream. There are no automatic retries.
    @discardableResult
    public func prepare(
        _ channel: LiveTVPrototypeChannel,
        serverReference: LiveTVServerChannelReference? = nil,
        isAuthorized: @escaping @MainActor @Sendable () -> Bool,
        accept: @MainActor () -> Bool
    ) async -> Bool {
        guard !Task.isCancelled else { return false }
        cancelPreparation()
        let requestID = generation
        let completion = LiveTVPreparationCompletion()
        operations[requestID] = completion
        defer {
            operations.removeValue(forKey: requestID)
            completion.finish()
        }
        return await withTaskCancellationHandler {
            await prepareCandidate(
                channel, serverReference: serverReference, requestID: requestID,
                isAuthorized: isAuthorized, accept: accept
            )
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                self?.cancelPreparation(ifCurrent: requestID)
            }
        }
    }

    private func prepareCandidate(
        _ channel: LiveTVPrototypeChannel,
        serverReference: LiveTVServerChannelReference?,
        requestID: UUID,
        isAuthorized: @escaping @MainActor @Sendable () -> Bool,
        accept: @MainActor () -> Bool
    ) async -> Bool {
        guard generation == requestID, !Task.isCancelled else { return false }
        preparingChannelID = channel.id
        failure = nil
        discardUnauthorizedCurrent()
        var candidate: PreparedLiveTVLeaseOwner?
        var resolving = false

        do {
            let binding = try makeBinding(
                channel: channel, reference: serverReference, isAuthorized: isAuthorized
            )
            try requireCurrent(requestID, binding: binding)
            preparingBinding = binding
            if let existing = current, canReuse(existing, binding: binding) {
                guard accept() else {
                    finishPreparation(requestID)
                    discardUnauthorizedCurrent()
                    return false
                }
                try requireCurrent(requestID, binding: binding)
                currentBinding = binding
                current = LiveTVPreparedStream(
                    id: existing.id, channel: channel, input: existing.input, authorizationID: existing.authorizationID,
                    serverReference: serverReference
                )
                finishPreparation(requestID)
                return true
            }

            let input: LiveChannelInput
            if let library = binding.library {
                input = .libraryChannel(id: library.channelID, authorizationID: library.authorizationID)
            } else if let reference = serverReference, let context = binding.context {
                let url: URL
                let opened = try await context.provider.openLiveTVChannel(id: reference.channelID)
                let owned = PreparedLiveTVLeaseOwner(opened)
                candidate = owned
                try requireCurrent(requestID, binding: binding)
                pendingLeases[requestID] = owned
                switch owned.playbackSource {
                case .authenticatedHTTP(let locator):
                    guard locator.accountID == reference.accountID,
                          locator.itemID == reference.channelID,
                          Self.source(for: locator.provider) == context.kind else {
                        throw LiveTVPlaybackPreparationError.authorizationChanged
                    }
                    guard let resolver = authenticatedHTTPResolver else {
                        throw LiveTVPlaybackPreparationError.resolverUnavailable
                    }
                    resolving = true
                    url = try await resolver.resolve(locator)
                    try requireCurrent(requestID, binding: binding)
                case .publicURL(let source):
                    url = source.url
                case .networkFile, .dlnaResource:
                    throw LiveTVPlaybackPreparationError.unsupportedPlaybackMode
                }
                input = .stream(url: url, httpHeaders: [:])
            } else {
                guard let streamURL = channel.streamURL else {
                    throw LiveTVPlaybackPreparationError.channelUnavailable
                }
                input = .stream(url: streamURL, httpHeaders: channel.httpHeaders)
            }
            if case .stream(let url, let headers) = input {
                try Self.validate(url: url, headers: headers)
            }
            try requireCurrent(requestID, binding: binding)
            guard accept() else {
                finishPreparation(requestID)
                pendingLeases.removeValue(forKey: requestID)
                if let candidate { await release(candidate).value }
                discardUnauthorizedCurrent()
                return false
            }
            try requireCurrent(requestID, binding: binding)
            let previous = currentLease
            pendingLeases.removeValue(forKey: requestID)
            currentLease = candidate
            currentBinding = binding
            current = LiveTVPreparedStream(
                id: requestID, channel: channel, input: input, authorizationID: binding.authorizationID,
                serverReference: serverReference
            )
            finishPreparation(requestID)
            if let previous { release(previous) }
            return true
        } catch {
            pendingLeases.removeValue(forKey: requestID)
            if generation == requestID {
                finishPreparation(requestID)
                failure = Task.isCancelled ? nil
                    : LiveTVPlaybackPreparationError.sanitized(error, resolving: resolving)
            }
            discardUnauthorizedCurrent()
            if let candidate { await release(candidate).value }
            discardUnauthorizedCurrent()
            return false
        }
    }

    /// Cancel an uncommitted handoff without stopping the current stream.
    public func cancelPendingPreparation() {
        cancelPreparation()
    }

    /// Clears observable player input immediately. Even a non-cooperative open
    /// returning later is fenced by generation and its returned lease is closed.
    public func stop() {
        cancelPreparation()
        retireCurrent()
        failure = nil
    }

    /// Handle a terminal player failure by prepared identity, never channel ID:
    /// an older player can report failure after the same channel was reopened.
    /// Unlike `stop`, this does not change the preparation generation or release
    /// another pending candidate. The caller returns to the guide only for
    /// `.stopped`; `.awaitingReplacement` preserves the user's in-flight zap.
    @discardableResult
    public func failCurrent(
        id: UUID,
        reason: LiveTVPlaybackPreparationError = .playbackFailed
    ) -> LiveTVPlaybackFailureDisposition {
        guard current?.id == id else { return .ignored }
        retireCurrent()
        if let target = preparingChannelID {
            return .awaitingReplacement(channelID: target)
        }
        failure = reason
        return .stopped
    }

    /// Drains the operations/leases owned at this call's stop boundary. A new
    /// explicit prepare started afterwards remains independent of this drain.
    public func close() async {
        let work = stopForDrain()
        await drain(work)
    }

    /// Explicit, consented one-tuner recovery. The caller must match the current
    /// prepared ID and target account, then separately call `prepare` only when
    /// this returns true. No channel is automatically opened or retried.
    ///
    /// Waits for owned cleanup attempts, not a guarantee that the remote server
    /// released its tuner. A newer action, cancellation, or authorization change
    /// prevents an older confirmation from opening its target afterwards.
    @discardableResult
    public func stopAndWait(currentID: UUID, accountID: String) async -> Bool {
        guard !Task.isCancelled, !isPreparing,
              current?.id == currentID, current?.accountID == accountID,
              currentLease != nil, let binding = currentBinding else { return false }
        let acceptedGeneration = generation
        guard authorizationFailure(binding) == nil,
              generation == acceptedGeneration, current?.id == currentID else {
            discardUnauthorizedCurrent()
            return false
        }
        let work = stopForDrain()
        await drain(work)
        guard !Task.isCancelled, generation == work.generation,
              current == nil, !isPreparing,
              authorizationFailure(binding) == nil else { return false }
        return generation == work.generation && !Task.isCancelled
    }

    /// Call on source/profile/account changes as well as stopping on background.
    /// Cancelling an unauthorized candidate does not discard an authorized current
    /// stream belonging to a different source.
    @discardableResult
    public func validateAuthorization() -> Bool {
        let pendingError = preparingBinding.flatMap { authorizationFailure($0) }
        if let pendingError {
            cancelPreparation()
            failure = pendingError
        }
        let currentError = discardUnauthorizedCurrent()
        if let currentError, !isPreparing, pendingError == nil { failure = currentError }
        return pendingError == nil && currentError == nil
    }

    public func report(_ update: LiveTVPlaybackUpdate) async {
        guard let id = current?.id else { return }
        await report(update, for: id)
    }

    public func report(_ update: LiveTVPlaybackUpdate, for preparedID: UUID) async {
        validateAuthorization()
        guard let currentLease, current?.id == preparedID else { return }
        await currentLease.report(update)
        validateAuthorization()
    }

    private struct Binding: Sendable {
        let channel: LiveTVPrototypeChannel
        let reference: LiveTVServerChannelReference?
        let context: LiveTVAuthorizedServerProvider?
        let library: LiveTVLibraryChannelReference?
        let isAuthorized: @MainActor @Sendable () -> Bool

        var authorizationID: String? { context?.authorizationID ?? library?.authorizationID }
    }

    private struct StoppedWork {
        let generation: UUID
        let operations: [LiveTVPreparationCompletion]
        let cleanups: [Task<Void, Never>]
    }

    private func stopForDrain() -> StoppedWork {
        let pending = Array(operations.values)
        stop()
        return StoppedWork(
            generation: generation, operations: pending, cleanups: Array(cleanups.values)
        )
    }

    private func drain(_ work: StoppedWork) async {
        for operation in work.operations { await operation.wait() }
        for cleanup in work.cleanups { await cleanup.value }
    }

    private func makeBinding(
        channel: LiveTVPrototypeChannel,
        reference: LiveTVServerChannelReference?,
        isAuthorized: @escaping @MainActor @Sendable () -> Bool
    ) throws -> Binding {
        guard isAuthorized() else { throw LiveTVPlaybackPreparationError.sourceUnavailable }
        if let reference {
            guard channel.configuredSourceID == reference.sourceID,
                  !reference.sourceID.isEmpty, !reference.accountID.isEmpty,
                  !reference.channelID.isEmpty else {
                throw LiveTVPlaybackPreparationError.sourceUnavailable
            }
            guard let context = serverProviderResolver(reference.accountID),
                  context.accountID == reference.accountID else {
                throw LiveTVPlaybackPreparationError.accountUnavailable
            }
            guard context.kind == channel.source,
                  [.jellyfin, .emby, .plex].contains(context.kind),
                  !context.authorizationID.isEmpty,
                  reference.authorizationID == context.authorizationID else {
                throw LiveTVPlaybackPreparationError.authorizationChanged
            }
            return Binding(
                channel: channel, reference: reference, context: context,
                library: nil, isAuthorized: isAuthorized
            )
        }
        guard channel.source == .iptv || channel.source == .plozz else {
            throw LiveTVPlaybackPreparationError.accountUnavailable
        }
        let library: LiveTVLibraryChannelReference?
        if channel.source == .plozz {
            guard let resolved = try libraryChannelResolver(channel) else {
                throw LiveTVPlaybackPreparationError.sourceUnavailable
            }
            guard !resolved.authorizationID.isEmpty else {
                throw LiveTVPlaybackPreparationError.authorizationChanged
            }
            library = resolved
        } else {
            library = nil
        }
        return Binding(
            channel: channel, reference: nil, context: nil,
            library: library, isAuthorized: isAuthorized
        )
    }

    private func authorizationFailure(_ binding: Binding) -> LiveTVPlaybackPreparationError? {
        guard binding.isAuthorized() else { return .sourceUnavailable }
        if let library = binding.library {
            do {
                guard let current = try libraryChannelResolver(binding.channel) else { return .sourceUnavailable }
                guard current == library else { return .authorizationChanged }
            } catch {
                return LiveTVPlaybackPreparationError.sanitized(error, resolving: false)
            }
        }
        guard let expected = binding.context, let reference = binding.reference else { return nil }
        guard let live = serverProviderResolver(reference.accountID),
              live.accountID == expected.accountID else { return .accountUnavailable }
        guard live.kind == expected.kind,
              live.authorizationID == expected.authorizationID,
              reference.authorizationID == live.authorizationID else { return .authorizationChanged }
        return nil
    }

    private func requireCurrent(_ requestID: UUID, binding: Binding) throws {
        guard generation == requestID else { throw CancellationError() }
        try Task.checkCancellation()
        discardUnauthorizedCurrent()
        if let error = authorizationFailure(binding) { throw error }
        // Injected MainActor callbacks can themselves invalidate this owner.
        guard generation == requestID else { throw CancellationError() }
        try Task.checkCancellation()
    }

    private func canReuse(_ existing: LiveTVPreparedStream, binding: Binding) -> Bool {
        guard currentBinding != nil,
              existing.channel.id == binding.channel.id,
              existing.channel.source == binding.channel.source,
              existing.channel.configuredSourceID == binding.channel.configuredSourceID,
              existing.serverReference == binding.reference,
              existing.authorizationID == binding.authorizationID else { return false }
        if binding.reference == nil {
            if let library = binding.library {
                return existing.input == .libraryChannel(
                    id: library.channelID, authorizationID: library.authorizationID
                )
            }
            return existing.channel.streamURL == binding.channel.streamURL
                && existing.httpHeaders == binding.channel.httpHeaders
        }
        return currentLease != nil
    }

    private func finishPreparation(_ requestID: UUID) {
        guard generation == requestID else { return }
        preparingChannelID = nil
        preparingBinding = nil
    }

    private func cancelPreparation() {
        generation = UUID()
        preparingChannelID = nil
        preparingBinding = nil
        let abandoned = Array(pendingLeases.values)
        pendingLeases.removeAll()
        for lease in abandoned { release(lease) }
    }

    private func cancelPreparation(ifCurrent requestID: UUID) {
        guard generation == requestID, isPreparing else { return }
        cancelPreparation()
        failure = nil
    }

    private func retireCurrent() {
        let previous = currentLease
        current = nil
        currentBinding = nil
        currentLease = nil
        if let previous { release(previous) }
    }

    @discardableResult
    private func discardUnauthorizedCurrent() -> LiveTVPlaybackPreparationError? {
        guard let stream = current, let binding = currentBinding,
              let error = authorizationFailure(binding),
              current?.id == stream.id else { return nil }
        retireCurrent()
        return error
    }

    @discardableResult
    private func release(_ lease: PreparedLiveTVLeaseOwner) -> Task<Void, Never> {
        if let pending = cleanups[lease.id] { return pending }
        let id = lease.id
        let task = Task<Void, Never>.detached { [weak self] in
            await lease.close()
            await self?.finishedCleanup(id)
        }
        cleanups[id] = task
        return task
    }

    private func finishedCleanup(_ id: UUID) {
        cleanups.removeValue(forKey: id)
    }

    private static func source(for provider: ProviderKind) -> LiveTVPrototypeSource? {
        switch provider {
        case .jellyfin: .jellyfin
        case .emby: .emby
        case .plex: .plex
        default: nil
        }
    }

    private static func validate(url: URL, headers: [String: String]) throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.host?.isEmpty == false, components.fragment == nil else {
            throw LiveTVPlaybackPreparationError.unsupportedPlaybackMode
        }
        let tokenCharacters = CharacterSet(
            charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
        )
        // CRLF is one Swift Character; HTTP control-byte checks must not use graphemes.
        guard headers.allSatisfy({ name, value in
            !name.isEmpty && name.unicodeScalars.allSatisfy(tokenCharacters.contains)
                && !value.utf8.contains(where: { $0 == 0 || $0 == 10 || $0 == 13 })
        }) else { throw LiveTVPlaybackPreparationError.invalidResponse }
    }
}

@MainActor
private final class LiveTVPreparationCompletion {
    private var finished = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !finished else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func finish() {
        finished = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor PreparedLiveTVLeaseOwner {
    nonisolated let id = UUID()
    nonisolated let playbackSource: PlaybackSource
    private let lease: any LiveTVStreamLease
    private var lastReport: Task<Void, Never>?
    private var cleanup: Task<Void, Never>?

    init(_ lease: any LiveTVStreamLease) {
        self.lease = lease
        self.playbackSource = lease.playbackSource
    }

    func report(_ update: LiveTVPlaybackUpdate) async {
        guard cleanup == nil else { return }
        let previous = lastReport
        let lease = lease
        let task = Task.detached {
            await previous?.value
            await lease.report(update)
        }
        lastReport = task
        await task.value
    }

    func close() async {
        if let cleanup {
            await cleanup.value
            return
        }
        let previous = lastReport
        let lease = lease
        let task = Task.detached {
            await previous?.value
            await lease.close()
        }
        cleanup = task
        await task.value
    }
}
#endif
