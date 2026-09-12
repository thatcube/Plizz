#if DEBUG
import CoreModels
import CryptoKit
import Foundation
import Observation

public struct LiveTVServerEnrollmentStatus: Identifiable, Equatable, Sendable {
    public let choice: LiveTVServerChoice
    public var id: String { choice.id }
    public internal(set) var phase: LiveTVImportPhase = .idle
    public internal(set) var availability: ServerLiveTVAvailability?
    public internal(set) var failure: LiveTVServerImportError?
    public internal(set) var sourceID: String?
}

/// Login/profile activation/refresh supplies only currently authorized accounts.
/// Configuration is read again at commit time: a user's remove/disable made
/// while discovery is in flight must win over the automatic result.
@MainActor
@Observable
public final class LiveTVServerEnrollmentCoordinator {
    public private(set) var statuses: [LiveTVServerEnrollmentStatus] = []
    @ObservationIgnored private var generation = 0

    public init() {}

    public func invalidate() {
        generation &+= 1
        statuses = []
    }

    @discardableResult
    public func refresh(
        choices: [LiveTVServerChoice],
        resolver: @escaping LiveTVServerProviderResolver,
        configuration: @MainActor () throws -> LiveTVSourcesConfiguration,
        suppressedAccountIDs: @MainActor () throws -> Set<String>,
        apply: @MainActor (LiveTVSourcesConfiguration) throws -> Void
    ) async -> [String] {
        generation &+= 1
        let request = generation
        var seen: Set<String> = []
        let choices = choices.filter {
            [.plex, .jellyfin, .emby].contains($0.kind) && seen.insert($0.id).inserted
        }
        statuses = choices.map { LiveTVServerEnrollmentStatus(choice: $0) }
        var added: [String] = []
        for choice in choices {
            guard request == generation, !Task.isCancelled else { return added }
            let currentConfiguration: LiveTVSourcesConfiguration
            let suppressed: Set<String>
            do {
                currentConfiguration = try configuration()
                suppressed = try suppressedAccountIDs()
            }
            catch {
                update(choice.id) { $0.phase = .failed; $0.failure = .configurationNotSaved }
                continue
            }
            guard !suppressed.contains(choice.id) else { continue }
            let existing = currentConfiguration.servers.first { $0.accountID == choice.id }
            if let existing, !existing.isEnabled { continue }
            guard let context = resolver(choice.id), context.accountID == choice.id,
                  context.kind == choice.kind, !context.authorizationID.isEmpty else {
                update(choice.id) { $0.phase = .failed; $0.failure = .accountUnavailable }
                continue
            }
            update(choice.id) { $0.phase = .loading; $0.sourceID = existing?.id }
            do {
                let availability = try await context.provider.liveTVAvailability()
                try Task.checkCancellation()
                guard request == generation else { return added }
                guard let current = resolver(choice.id), current.accountID == context.accountID,
                      current.kind == context.kind,
                      current.authorizationID == context.authorizationID else {
                    update(choice.id) { $0.phase = .failed; $0.failure = .accountUnavailable }
                    continue
                }
                update(choice.id) {
                    $0.phase = .loaded
                    $0.availability = availability
                }
                guard availability.hasChannels,
                      availability.status == .available
                        || availability.status == .unsupportedPlaybackMode else { continue }
                var latest: LiveTVSourcesConfiguration
                let currentSuppression: Set<String>
                do {
                    latest = try configuration()
                    currentSuppression = try suppressedAccountIDs()
                }
                catch {
                    update(choice.id) { $0.phase = .failed; $0.failure = .configurationNotSaved }
                    continue
                }
                guard !currentSuppression.contains(choice.id) else { continue }
                if let existing = latest.servers.first(where: { $0.accountID == choice.id }) {
                    update(choice.id) { $0.sourceID = existing.id }
                    continue
                }
                let source = LiveTVServerSource(
                    id: Self.sourceID(accountID: choice.id),
                    name: choice.name, accountID: choice.id
                )
                latest.servers.append(source)
                do {
                    try latest.validate()
                    try apply(latest)
                } catch {
                    update(choice.id) {
                        $0.phase = .failed
                        $0.failure = .configurationNotSaved
                    }
                    continue
                }
                added.append(source.id)
                update(choice.id) { $0.sourceID = source.id }
            } catch {
                guard request == generation else { return added }
                if Task.isCancelled || error is CancellationError
                    || (error as? AppError) == .cancelled || (error as? URLError)?.code == .cancelled {
                    update(choice.id) { $0.phase = .idle }
                    return added
                }
                update(choice.id) {
                    $0.phase = .failed
                    $0.failure = LiveTVServerImportError.sanitized(error, fallback: .serviceUnavailable)
                }
            }
        }
        return added
    }

    public static func sourceID(accountID: String) -> String {
        let hash = SHA256.hash(data: Data(accountID.utf8)).map { String(format: "%02x", $0) }.joined()
        return "server-\(hash)"
    }

    private func update(_ accountID: String, _ change: (inout LiveTVServerEnrollmentStatus) -> Void) {
        guard let index = statuses.firstIndex(where: { $0.id == accountID }) else { return }
        change(&statuses[index])
    }
}
#endif
