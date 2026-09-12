#if DEBUG
import CoreModels
import Foundation
import Observation

@MainActor
@Observable
public final class LiveTVServerProbeModel {
    public struct Request: Equatable, Sendable {
        public let id: UUID
        public let choice: LiveTVServerChoice
    }

    public private(set) var choice: LiveTVServerChoice?
    public private(set) var pendingRequest: Request?
    public private(set) var availability: ServerLiveTVAvailability?
    public private(set) var failure: LiveTVServerImportError?
    @ObservationIgnored private let resolver: LiveTVServerProviderResolver?
    @ObservationIgnored private var authorizationID: String?

    public init(resolver: LiveTVServerProviderResolver?) {
        self.resolver = resolver
    }

    public var isChecking: Bool { pendingRequest != nil }

    public var canAdd: Bool {
        guard failure == nil, authorizationID != nil,
              let availability, availability.hasChannels else { return false }
        return availability.status == .available || availability.status == .unsupportedPlaybackMode
    }

    public func beginCheck(_ choice: LiveTVServerChoice) {
        self.choice = choice
        availability = nil
        failure = nil
        authorizationID = nil
        pendingRequest = Request(id: UUID(), choice: choice)
    }

    public func perform(_ request: Request) async {
        defer {
            if Task.isCancelled, pendingRequest == request { cancelCheck() }
        }
        guard pendingRequest == request, !Task.isCancelled else { return }
        guard let context = resolver?(request.choice.id),
              context.accountID == request.choice.id, context.kind == request.choice.kind,
              !context.authorizationID.isEmpty else {
            failure = .accountUnavailable
            pendingRequest = nil
            return
        }
        do {
            let result = try await context.provider.liveTVAvailability()
            guard pendingRequest == request, !Task.isCancelled else { return }
            guard let current = resolver?(request.choice.id),
                  current.accountID == context.accountID,
                  current.kind == context.kind,
                  current.authorizationID == context.authorizationID else {
                failure = .accountUnavailable
                pendingRequest = nil
                return
            }
            authorizationID = context.authorizationID
            availability = result
            pendingRequest = nil
        } catch {
            guard pendingRequest == request, !Task.isCancelled else { return }
            guard let current = resolver?(request.choice.id),
                  current.accountID == context.accountID, current.kind == context.kind,
                  current.authorizationID == context.authorizationID else {
                failure = .accountUnavailable
                pendingRequest = nil
                return
            }
            failure = LiveTVServerImportError.sanitized(error, fallback: .serviceUnavailable)
            pendingRequest = nil
        }
    }

    public func checkedChoice() throws -> LiveTVServerChoice {
        guard canAdd, let choice, let authorizationID,
              let current = resolver?(choice.id),
              current.accountID == choice.id, current.kind == choice.kind,
              current.authorizationID == authorizationID else {
            failure = .accountUnavailable
            throw LiveTVServerImportError.accountUnavailable
        }
        return choice
    }

    public func cancelCheck() {
        pendingRequest = nil
        availability = nil
        authorizationID = nil
    }
}
#endif
