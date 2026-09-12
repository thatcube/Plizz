#if DEBUG
import CoreModels
import Foundation
import Observation

@MainActor
@Observable
public final class LiveTVScanCatalogBinding {
    private static var activeBindings: [String: WeakBinding] = [:]
    public let coordinator: LiveTVChannelScanCoordinator
    public private(set) var issue: LiveTVChannelScanError?
    @ObservationIgnored private let profileID: String
    @ObservationIgnored private weak var model: LiveTVPrototypeModel?
    @ObservationIgnored private let authorization:
        @MainActor (LiveTVSourcesConfiguration) throws -> LiveTVSourceAuthorization
    @ObservationIgnored private var configuration = LiveTVSourcesConfiguration.empty
    @ObservationIgnored private var channels: [LiveTVPrototypeChannel] = []
    @ObservationIgnored private var isActive = false
    @ObservationIgnored private var ownsScan = false

    public init(
        profileID: String, model: LiveTVPrototypeModel,
        coordinator: LiveTVChannelScanCoordinator,
        authorization: @escaping @MainActor (LiveTVSourcesConfiguration) throws -> LiveTVSourceAuthorization
    ) {
        self.profileID = profileID
        self.model = model
        self.coordinator = coordinator
        self.authorization = authorization
    }

    isolated deinit { releaseScan() }

    public func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active {
            let previous = Self.activeBindings[profileID]?.value
            previous?.revokeScan()
            Self.activeBindings[profileID] = WeakBinding(self)
            ownsScan = true
            bind()
        } else {
            releaseScan()
        }
    }

    public func updateCatalog(_ configuration: LiveTVSourcesConfiguration, channels: [LiveTVPrototypeChannel]) {
        self.configuration = configuration
        self.channels = channels
        if isActive && ownsScan { bind() }
    }

    public func invalidate(_ sourceIDs: Set<String>) {
        for id in sourceIDs { coordinator.invalidate(sourceID: id) }
        synchronizeVisibility()
    }

    public func deactivate() {
        isActive = false
        releaseScan()
    }

    public func retry() {
        guard isActive && ownsScan else { return }
        bind()
    }

    public func synchronizeVisibility() {
        model?.setScanHiddenChannelIDs(coordinator.scanHiddenChannelIDs)
    }

    private func clearRuntime() {
        coordinator.deactivate()
        model?.setScanHiddenChannelIDs([])
    }

    private func revokeScan() {
        // Keep the active request latched: background catalog updates must not
        // steal ownership back from the newly presented destination.
        ownsScan = false
        clearRuntime()
    }

    private func releaseScan() {
        if Self.activeBindings[profileID]?.value === self {
            Self.activeBindings.removeValue(forKey: profileID)
        }
        revokeScan()
    }

    private final class WeakBinding {
        weak var value: LiveTVScanCatalogBinding?
        init(_ value: LiveTVScanCatalogBinding) { self.value = value }
    }

    private func bind() {
        do {
            let authority = try authorization(configuration)
            guard authority.profileID == profileID else { throw LiveTVChannelScanError.sourceUnavailable }
            let allowed = authority.filtering(configuration)
            let sources = try allowed.playlists.filter(\.isEnabled).map {
                try LiveTVChannelScanSource(source: $0, channels: channels)
            }
            try coordinator.bind(profileID: profileID, sources: sources)
            issue = nil
            synchronizeVisibility()
        } catch {
            issue = (error as? LiveTVChannelScanError) ?? .sourceUnavailable
            clearRuntime()
            HandoffDiagnostics.emit("LIVE_TV event=scanCatalogUnavailable")
        }
    }
}
#endif
