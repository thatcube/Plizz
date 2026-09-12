#if DEBUG
import CoreModels
import Foundation

@MainActor
public final class LiveTVPlaybackSourceAuthority {
    private let profileID: String
    private let approvals: LiveTVSourceApprovalStore
    private let sourceStore: (any LiveTVSourcesStoring)?
    private let context: @MainActor @Sendable () -> LiveTVSourceApprovalContext?
    private var reportedFailure = false

    public init(
        profileID: String,
        approvals: LiveTVSourceApprovalStore,
        sourceStore: (any LiveTVSourcesStoring)?,
        context: @escaping @MainActor @Sendable () -> LiveTVSourceApprovalContext?
    ) {
        self.profileID = profileID
        self.approvals = approvals
        self.sourceStore = sourceStore
        self.context = context
    }

    public var contextIdentity: String? { context()?.identity }

    public func authorization(
        configuration: LiveTVSourcesConfiguration
    ) throws -> LiveTVSourceAuthorization {
        guard let current = context(), current.profileID == profileID else {
            throw LiveTVSourceApprovalError.wrongProfile
        }
        return try approvals.authorization(context: current, configuration: configuration)
    }

    public func allows(
        _ channel: LiveTVPrototypeChannel, configuration: LiveTVSourcesConfiguration
    ) -> Bool {
        guard channel.source != .plozz else { return true }
        do {
            guard context()?.profileID == profileID else {
                throw LiveTVSourceApprovalError.wrongProfile
            }
            let latest = try sourceStore?.load() ?? configuration
            let allowed: Bool
            if channel.source == .iptv {
                allowed = try authorization(configuration: latest).allowsPlaylist(channel.configuredSourceID)
            } else if let recorded = configuration.servers.first(where: {
                $0.id == channel.configuredSourceID && $0.isEnabled
            }) {
                allowed = latest.servers.contains {
                    $0.id == recorded.id && $0.accountID == recorded.accountID && $0.isEnabled
                }
            } else {
                allowed = false
            }
            reportedFailure = false
            return allowed
        } catch {
            if !reportedFailure {
                HandoffDiagnostics.emit("LIVE_TV event=sourceApprovalUnavailable")
                reportedFailure = true
            }
            return false
        }
    }
}
#endif
