#if DEBUG
import CoreModels
import CoreSecureStore
import FeatureLiveTVCore
import Foundation
import Observation

/// One shared composition adapter for both shells. No new CKSyncEngine, credential
/// transport or automatic opt-in. Register its capture/apply methods on the
/// `.liveTVStateV1` channel of the existing CloudConfigSyncService.
@MainActor
@Observable
public final class LiveTVPortableSyncBridge {
    public enum Status: Equatable, Sendable {
        case localOnly, ready, unavailable
        case pendingLibraryInputs, pendingLibraryReview
        case pendingSetup(Int)
        case pendingSchedules(Int)
        case pendingChannelMatches(Int)
    }

    public private(set) var statuses: [String: Status] = [:]
    @ObservationIgnored private let profiles: ProfilesModel
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let sourceStore: @MainActor (String) -> any LiveTVSourcesStoring
    @ObservationIgnored private let definitions: (@MainActor (String) -> any LibraryChannelDefinitionStoring)?
    @ObservationIgnored private let snapshots: (any LibraryChannelSnapshotStoring)?
    @ObservationIgnored private let guideCache: @MainActor (String) -> LiveTVIndexedCache?
    @ObservationIgnored private let captureIdentityHints: @MainActor (String) async throws -> [String: LiveTVPortableChannelIdentityHint]?
    @ObservationIgnored private let applyIdentityHints: @MainActor (String, [String: LiveTVPortableChannelIdentityHint?]) async throws -> Bool
    @ObservationIgnored private var operationInProgress = false
    @ObservationIgnored private var operationWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var operationAuthority: [String: ProfileAuthority] = [:]

    private struct ProfileAuthority: Equatable {
        let namespace: String?
        let consentRevision: String
    }

    public init(
        profiles: ProfilesModel, directory: URL, defaults: UserDefaults = .standard,
        sourceStore: (@MainActor (String) -> any LiveTVSourcesStoring)? = nil,
        definitions: (@MainActor (String) -> any LibraryChannelDefinitionStoring)? = nil,
        snapshots: (any LibraryChannelSnapshotStoring)? = nil,
        guideCache: @escaping @MainActor (String) -> LiveTVIndexedCache? = { _ in nil },
        captureIdentityHints: @escaping @MainActor (String) async throws -> [String: LiveTVPortableChannelIdentityHint]? = { _ in nil },
        applyIdentityHints: @escaping @MainActor (String, [String: LiveTVPortableChannelIdentityHint?]) async throws -> Bool = { _, _ in false }
    ) {
        self.profiles = profiles
        self.directory = directory
        self.defaults = defaults
        self.sourceStore = sourceStore ?? { profileID in
            LiveTVSourceStorage.approvalAwareStore(
                profileID: profileID,
                namespace: profileID == profiles.rootNamespaceOwnerID ? nil : profileID
            )
        }
        self.definitions = definitions
        self.snapshots = snapshots
        self.guideCache = guideCache
        self.captureIdentityHints = captureIdentityHints
        self.applyIdentityHints = applyIdentityHints
    }

    public func capture(fallback: [SyncRecordID: Data]) async -> [SyncRecordID: Data] {
        let epoch = LiveTVPortableSyncPreferenceStore.storageEpoch(defaults: defaults)
        let authority = currentAuthority()
        await beginOperation()
        defer { endOperation() }
        operationAuthority = authority
        guard epoch == LiveTVPortableSyncPreferenceStore.storageEpoch(defaults: defaults) else { return [:] }
        guard !Task.isCancelled else { return fallback }
        return await captureSerially(fallback: fallback)
    }

    private func captureSerially(fallback: [SyncRecordID: Data]) async -> [SyncRecordID: Data] {
        let epoch = LiveTVPortableSyncPreferenceStore.storageEpoch(defaults: defaults)
        var result = fallback
        let removed: Set<String>
        do { removed = try removedProfiles() }
        catch { return fallback }
        result = result.filter {
            guard let key = LiveTVPortableRecordKey.parse($0.key) else { return true }
            return !removed.contains(key.profileID)
        }
        for profile in profiles.profiles where !removed.contains(profile.id) {
            guard epoch == LiveTVPortableSyncPreferenceStore.storageEpoch(defaults: defaults) else { return [:] }
            let adapter = adapter(profile.id)
            guard adapter.isEnabled else {
                statuses[profile.id] = .localOnly
                continue
            }
            guard mayApply(profile.id, epoch: epoch) else { continue }
            do {
                var libraryIssue: Status?
                let deferred = try adapter.pending(sourceStore: sourceStore(profile.id))
                do { try await applyLibrary(deferred, profileID: profile.id, epoch: epoch) }
                catch { libraryIssue = Self.libraryStatus(for: error) }
                try await applyDeferredIdentities(adapter, profileID: profile.id, epoch: epoch)
                try await applyDeferredMappings(adapter, profileID: profile.id, epoch: epoch)
                guard mayApply(profile.id, epoch: epoch) else { continue }
                var libraryState: LibraryChannelPortableState?
                do { libraryState = try await captureLibraryState(profileID: profile.id, epoch: epoch) }
                catch { libraryIssue = Self.libraryStatus(for: error) }
                let cache = guideCache(profile.id)
                let mappingAuthority = try cache.map { _ in try guideAuthority(profile.id) }
                let mappings: LiveTVPortableGuideMappingExport?
                if let cache, let mappingAuthority {
                    mappings = try await cache.portableSyncGuideMappings(configuration: mappingAuthority.configuration)
                } else {
                    mappings = nil
                }
                let identities = try await captureIdentityHints(profile.id)
                guard mayApply(profile.id, epoch: epoch) else { continue }
                if let mappingAuthority {
                    guard try guideAuthority(profile.id) == mappingAuthority else { continue }
                }
                if let state = libraryState,
                   try definitions?(profile.id).load() != state.definitions {
                    libraryState = nil
                    libraryIssue = .pendingLibraryReview
                }
                let captured = try adapter.capture(
                    sourceStore: sourceStore(profile.id), libraryDefinitions: libraryState?.definitions,
                    snapshots: libraryState?.snapshots ?? [], guideMappings: mappings?.mappings,
                    unresolvedGuideMappingIDs: mappings?.unresolvedChannelIDs ?? [],
                    identityHints: identities?.filter {
                        mappingAuthority?.authorization.allowsPlaylist($0.value.sourceID) ?? true
                    }, fallback: fallback
                )
                try await applyDeferredIdentities(adapter, profileID: profile.id, epoch: epoch)
                try await applyDeferredMappings(adapter, profileID: profile.id, epoch: epoch)
                guard mayApply(profile.id, epoch: epoch) else { continue }
                let pending = try adapter.pending(sourceStore: sourceStore(profile.id))
                do { try await applyLibrary(pending, profileID: profile.id, epoch: epoch) }
                catch { libraryIssue = Self.libraryStatus(for: error) }
                guard mayApply(profile.id, epoch: epoch) else { continue }
                result.merge(captured, uniquingKeysWith: { _, new in new })
                updateStatus(pending, profileID: profile.id)
                if let libraryIssue { statuses[profile.id] = libraryIssue }
            } catch {
                statuses[profile.id] = .unavailable
            }
        }
        guard epoch == LiveTVPortableSyncPreferenceStore.storageEpoch(defaults: defaults) else { return [:] }
        guard let latestRemoved = try? removedProfiles() else { return fallback }
        return result.filter {
            guard let key = LiveTVPortableRecordKey.parse($0.key) else { return true }
            return !latestRemoved.contains(key.profileID)
        }
    }

    public func apply(_ changes: SyncLocalChanges) async {
        let epoch = LiveTVPortableSyncPreferenceStore.storageEpoch(defaults: defaults)
        let authority = currentAuthority()
        await beginOperation()
        defer { endOperation() }
        operationAuthority = authority
        guard !Task.isCancelled,
              epoch == LiveTVPortableSyncPreferenceStore.storageEpoch(defaults: defaults) else { return }
        await applySerially(changes, epoch: epoch)
    }

    private func applySerially(_ changes: SyncLocalChanges, epoch: String) async {
        let known = Set(profiles.profiles.map(\.id))
        guard let removed = try? removedProfiles() else { return }
        let profileIDs = Set(changes.keys.compactMap(LiveTVPortableRecordKey.parse).map(\.profileID))
        for profileID in profileIDs.sorted() where known.contains(profileID) && !removed.contains(profileID) {
            guard epoch == LiveTVPortableSyncPreferenceStore.storageEpoch(defaults: defaults) else { return }
            let adapter = adapter(profileID)
            guard adapter.isEnabled else {
                statuses[profileID] = .localOnly
                continue
            }
            guard mayApply(profileID, epoch: epoch) else { continue }
            do {
                let report = try adapter.apply(changes, sourceStore: sourceStore(profileID))
                try await applyDeferredIdentities(adapter, profileID: profileID, epoch: epoch)
                try await applyDeferredMappings(adapter, profileID: profileID, epoch: epoch)
                try await applyLibrary(report, profileID: profileID, epoch: epoch)
                guard mayApply(profileID, epoch: epoch) else { continue }
                updateStatus(report, profileID: profileID)
            } catch {
                if mayApply(profileID, epoch: epoch) { statuses[profileID] = Self.libraryStatus(for: error) }
            }
        }
    }

    /// Wire to the existing profile removal lifecycle, not to a transient missing
    /// profile roster during cloud hydration.
    public func removeProfile(_ profileID: String) throws {
        var removed = try removedProfiles()
        removed.insert(profileID)
        try FileManager.default.createDirectory(at: metadataDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(removed.sorted()).write(
            to: metadataDirectory.appendingPathComponent("removed-profiles.json"), options: .atomic
        )
        try adapter(profileID).resetForAccountChange()
        statuses.removeValue(forKey: profileID)
    }

    public func accountDidChange() {
        LiveTVPortableSyncPreferenceStore.accountDidChange(defaults: defaults)
        statuses = [:]
        for profile in profiles.profiles {
            statuses[profile.id] = .localOnly
        }
    }

    public func sourceSetupStore(profileID: String) -> (any LiveTVSourcesStoring)? {
        guard profiles.profiles.contains(where: { $0.id == profileID }),
              (try? removedProfiles().contains(profileID)) == false else { return nil }
        return sourceStore(profileID)
    }

    public var stateDirectory: URL { directory }

    private func captureLibraryState(profileID: String, epoch: String) async throws -> LibraryChannelPortableState? {
        guard let definitions else { return nil }
        let store = definitions(profileID)
        let original = try store.load()
        let required = Set(original.flatMap(\.revisions).map(\.snapshotID))
        guard original.count <= LibraryChannelPortableState.maximumDefinitions,
              required.count <= LibraryChannelPortableState.maximumDefinitions * 32 else {
            throw LibraryChannelError.catalogTooLarge
        }
        var values: [LibraryChannelSnapshot] = []
        var itemCount = 0
        for id in required.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let snapshot = try await snapshots?.snapshot(id: id, profileID: profileID) else {
                throw LibraryChannelError.snapshotUnavailable
            }
            guard mayApply(profileID, epoch: epoch) else { throw CancellationError() }
            itemCount += snapshot.items.count
            guard itemCount <= LibraryChannelPortableState.maximumItems else { throw LibraryChannelError.catalogTooLarge }
            values.append(snapshot)
        }
        guard mayApply(profileID, epoch: epoch) else { throw CancellationError() }
        guard try store.load() == original else { throw LibraryChannelError.publicationConflict }
        return try LibraryChannelPortableState(definitions: original, snapshots: values)
    }

    private func applyLibrary(_ report: LiveTVPortableImport, profileID: String, epoch: String) async throws {
        var applicable = report
        applicable.libraryDefinitions.removeAll { report.libraryReviewIDs.contains($0.id) }
        do {
            try await applyLibraryChanges(applicable, profileID: profileID, epoch: epoch)
        } catch {
            if error as? LibraryChannelError == .publicationConflict, mayApply(profileID, epoch: epoch) {
                try adapter(profileID).markLibrariesForReview(Set(applicable.libraryDefinitions.map(\.id)))
            }
            throw error
        }
    }

    private func applyLibraryChanges(_ report: LiveTVPortableImport, profileID: String, epoch: String) async throws {
        guard let definitions, mayApply(profileID, epoch: epoch) else { return }
        guard !report.libraryDefinitions.isEmpty || !report.deletedLibraryIDs.isEmpty
            || !report.disabledLibraryIDs.isEmpty else { return }
        let store = definitions(profileID)
        try applyLibraryRevocations(report, profileID: profileID, store: store)
        guard !report.libraryDefinitions.isEmpty else { return }
        guard let staging = snapshots as? any LibraryChannelSnapshotStaging else {
            throw LibraryChannelError.storageFailed
        }
        let original = try store.load()
        let incomingIDs = Set(report.libraryDefinitions.flatMap(\.revisions).map(\.snapshotID))
        let incoming = report.snapshots.filter { incomingIDs.contains($0.id) }
        _ = try LibraryChannelPortableState(definitions: report.libraryDefinitions, snapshots: incoming)
        let required = Set(original.flatMap(\.revisions).map(\.snapshotID)).union(incomingIDs)
        guard required.count <= LibraryChannelPortableState.maximumDefinitions * 32 else {
            throw LibraryChannelError.catalogTooLarge
        }
        let supplied = report.snapshots.filter { required.contains($0.id) }
        var indexed = Dictionary(uniqueKeysWithValues: supplied.map { ($0.id, $0) })
        var itemCount = supplied.reduce(0) { $0 + $1.items.count }
        guard itemCount <= LibraryChannelPortableState.maximumItems else { throw LibraryChannelError.catalogTooLarge }
        for id in required.sorted(by: { $0.uuidString < $1.uuidString }) {
            let stored = try await staging.snapshot(id: id, profileID: profileID)
            guard mayApply(profileID, epoch: epoch) else { return }
            if let stored {
                if let received = indexed[id] {
                    guard received == stored else { throw LibraryChannelError.invalidSnapshot }
                } else {
                    itemCount += stored.items.count
                    guard itemCount <= LibraryChannelPortableState.maximumItems else { throw LibraryChannelError.catalogTooLarge }
                    indexed[id] = stored
                }
            }
            guard indexed[id] != nil else { throw LibraryChannelError.snapshotUnavailable }
        }
        guard try store.load() == original else { throw LibraryChannelError.publicationConflict }
        let lease = try await staging.stage(
            indexed.values.sorted { $0.id.uuidString < $1.id.uuidString }, profileID: profileID
        )
        do {
            if mayApply(profileID, epoch: epoch), !Task.isCancelled {
                try commitLibrary(
                    report, profileID: profileID, store: store, original: original, snapshots: indexed
                )
            }
        } catch {
            await staging.release(lease)
            throw error
        }
        await staging.release(lease)
    }

    /// Denial does not depend on downloading new revision inputs. Retain the
    /// currently valid schedule while pausing it; never install a partial recipe.
    private func applyLibraryRevocations(
        _ report: LiveTVPortableImport, profileID: String, store: any LibraryChannelDefinitionStoring
    ) throws {
        guard !report.deletedLibraryIDs.isEmpty || !report.disabledLibraryIDs.isEmpty else { return }
        let previous = try store.load()
        guard previous.allSatisfy({ $0.profileID == profileID }) else {
            throw LibraryChannelError.authorizationChanged
        }
        var current = previous.filter { !report.deletedLibraryIDs.contains($0.id) }
        for index in current.indices where report.disabledLibraryIDs.contains(current[index].id) {
            current[index].isEnabled = false
        }
        if current != previous { try saveLibrary(current, replacing: previous, store: store) }
        if !report.deletedLibraryIDs.isEmpty {
            try adapter(profileID).acknowledgeLibraries(report.deletedLibraryIDs)
        }
        if current != previous {
            NotificationCenter.default.post(name: .plozzLiveTVPortableStateDidApply, object: profileID)
        }
    }

    private func commitLibrary(
        _ report: LiveTVPortableImport, profileID: String, store: any LibraryChannelDefinitionStoring,
        original: [LibraryChannelDefinition], snapshots: [UUID: LibraryChannelSnapshot]
    ) throws {
        let latest = try store.load()
        guard latest == original else { throw LibraryChannelError.publicationConflict }
        let current = try LibraryChannelImportMerger.merge(
            profileID: profileID, current: latest, incoming: report.libraryDefinitions,
            deletedIDs: report.deletedLibraryIDs, snapshots: snapshots
        )
        if current != latest {
            try saveLibrary(current, replacing: latest, store: store)
        }
        try adapter(profileID).acknowledgeLibraries(
            Set(report.libraryDefinitions.map(\.id)).union(report.deletedLibraryIDs)
        )
        if current != latest || !report.snapshots.isEmpty || !report.deletedLibraryIDs.isEmpty {
            NotificationCenter.default.post(name: .plozzLiveTVPortableStateDidApply, object: profileID)
        }
    }

    private func saveLibrary(
        _ values: [LibraryChannelDefinition], replacing expected: [LibraryChannelDefinition],
        store: any LibraryChannelDefinitionStoring
    ) throws {
        guard let atomicStore = store as? any LibraryChannelDefinitionCompareAndSwapping else {
            throw LibraryChannelError.storageFailed
        }
        try atomicStore.save(values, ifUnchangedFrom: expected)
    }

    private func applyDeferredMappings(_ adapter: LiveTVPortableSyncAdapter, profileID: String, epoch: String) async throws {
        guard mayApply(profileID, epoch: epoch),
              !LiveTVPlaybackIdentityHold.isHeld(profileID: profileID),
              let cache = guideCache(profileID) else { return }
        let mappings = try adapter.deferredGuideMappings()
        guard !mappings.isEmpty else { return }
        let authority = try guideAuthority(profileID)
        let applied = try await cache.applyPortableGuideMappings(mappings, configuration: authority.configuration)
        guard !applied.isEmpty, mayApply(profileID, epoch: epoch),
              !LiveTVPlaybackIdentityHold.isHeld(profileID: profileID),
              try guideAuthority(profileID) == authority else { return }
        try adapter.acknowledgeMappings(applied)
        NotificationCenter.default.post(name: .plozzLiveTVPortableStateDidApply, object: profileID)
    }

    private struct GuideAuthority: Equatable {
        let configuration: LiveTVSourcesConfiguration
        let authorization: LiveTVSourceAuthorization
    }

    private func guideAuthority(_ profileID: String) throws -> GuideAuthority {
        guard let profile = profiles.profiles.first(where: { $0.id == profileID }) else {
            throw LiveTVSourceApprovalError.staleAuthority
        }
        let configuration = try sourceStore(profileID).load()
        let context = LiveTVSourceApprovalContext(
            profile: profile, parentalPIN: profiles.parentalPIN,
            activeAccountIDs: profiles.activeAccountIDs(for: profileID, fallback: [])
        )
        let authorization = try LiveTVSourceApprovalStore(
            defaults: defaults, profileID: profileID,
            namespace: profileID == profiles.rootNamespaceOwnerID ? nil : profileID
        ).authorization(context: context, configuration: configuration)
        return GuideAuthority(configuration: authorization.filtering(configuration), authorization: authorization)
    }

    private func applyDeferredIdentities(_ adapter: LiveTVPortableSyncAdapter, profileID: String, epoch: String) async throws {
        guard mayApply(profileID, epoch: epoch),
              !LiveTVPlaybackIdentityHold.isHeld(profileID: profileID) else { return }
        let hints = try adapter.deferredIdentityHints()
        guard !hints.isEmpty else { return }
        if try await applyIdentityHints(profileID, hints), mayApply(profileID, epoch: epoch) {
            try adapter.acknowledgeIdentityHints(Set(hints.keys))
            NotificationCenter.default.post(name: .plozzLiveTVPortableStateDidApply, object: profileID)
        }
    }

    private func mayApply(_ profileID: String, epoch: String) -> Bool {
        epoch == LiveTVPortableSyncPreferenceStore.storageEpoch(defaults: defaults)
            && profiles.profiles.contains { $0.id == profileID }
            && adapter(profileID).isEnabled
            && operationAuthority[profileID] != nil
            && operationAuthority[profileID] == authority(profileID)
            && ((try? removedProfiles().contains(profileID)) == false)
    }

    private func authority(_ profileID: String) -> ProfileAuthority? {
        let namespace = profileID == profiles.rootNamespaceOwnerID ? nil : profileID
        guard let revision = LiveTVPortableSyncPreferenceStore(
            defaults: defaults, profileID: profileID, namespace: namespace
        ).consentRevision else { return nil }
        return ProfileAuthority(namespace: namespace, consentRevision: revision)
    }

    private func currentAuthority() -> [String: ProfileAuthority] {
        var result: [String: ProfileAuthority] = [:]
        for profile in profiles.profiles { result[profile.id] = authority(profile.id) }
        return result
    }

    private func adapter(_ profileID: String) -> LiveTVPortableSyncAdapter {
        LiveTVPortableSyncAdapter(
            directory: directory, profileID: profileID, defaults: defaults,
            namespace: profileID == profiles.rootNamespaceOwnerID ? nil : profileID
        )
    }

    /// Main-actor methods can still interleave across cache/snapshot awaits.
    /// Serialize channel transactions so an older acknowledgement cannot erase
    /// a newer pending update for the same channel.
    private func beginOperation() async {
        if !operationInProgress {
            operationInProgress = true
            return
        }
        await withCheckedContinuation { operationWaiters.append($0) }
    }

    private func endOperation() {
        operationAuthority = [:]
        if operationWaiters.isEmpty { operationInProgress = false }
        else { operationWaiters.removeFirst().resume() }
    }

    public func statusSummary(profileID: String) -> LocalizedStringResource {
        guard let status = statuses[profileID] else { return "Waiting to sync Live TV." }
        switch status {
        case .localOnly: return "Live TV settings stay on this device."
        case .ready: return "Live TV settings are ready to sync."
        case .unavailable: return "Some Live TV settings could not be synced."
        case .pendingLibraryInputs: return "Waiting for complete library schedule inputs."
        case .pendingLibraryReview: return "Some library schedule changes need review before they can be applied."
        case .pendingSetup(let count): return "\(count) Live TV sources need local setup."
        case .pendingSchedules(let count): return "Waiting for \(count) library schedule snapshots."
        case .pendingChannelMatches(let count): return "Waiting to apply settings for \(count) channels."
        }
    }

    private static func libraryStatus(for error: Error) -> Status {
        if let error = error as? LibraryChannelError {
            switch error {
            case .publicationConflict: return .pendingLibraryReview
            case .snapshotUnavailable: return .pendingLibraryInputs
            default: break
            }
        }
        if error as? LiveTVPortableStateError == .incompleteSnapshot { return .pendingLibraryInputs }
        return .unavailable
    }

    private func updateStatus(_ report: LiveTVPortableImport, profileID: String) {
        let pendingIdentities = (try? adapter(profileID).deferredIdentityHints()) ?? [:]
        let pendingMappings = (try? adapter(profileID).deferredGuideMappings()) ?? [:]
        let pendingChannels = Set(pendingIdentities.keys).union(pendingMappings.keys)
        if report.rejectedCount > 0 { statuses[profileID] = .unavailable }
        else if !report.libraryReviewIDs.isEmpty { statuses[profileID] = .pendingLibraryReview }
        else if (!report.libraryDefinitions.isEmpty && (definitions == nil || snapshots == nil))
            || ((!report.deletedLibraryIDs.isEmpty || !report.disabledLibraryIDs.isEmpty) && definitions == nil) {
            statuses[profileID] = .unavailable
        }
        else if !report.incompleteSnapshotIDs.isEmpty {
            statuses[profileID] = .pendingSchedules(report.incompleteSnapshotIDs.count)
        } else if !report.pendingPlaylists.isEmpty || !report.localFileSources.isEmpty {
            statuses[profileID] = .pendingSetup(report.pendingPlaylists.count + report.localFileSources.count)
        } else if !pendingChannels.isEmpty {
            statuses[profileID] = .pendingChannelMatches(pendingChannels.count)
        } else {
            statuses[profileID] = .ready
        }
    }

    private func removedProfiles() throws -> Set<String> {
        let url = metadataDirectory.appendingPathComponent("removed-profiles.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        guard data.count <= 1_024 * 1_024 else { throw LiveTVPortableStateError.tooLarge }
        return Set(try JSONDecoder().decode([String].self, from: data))
    }

    private var metadataDirectory: URL {
        directory.appendingPathComponent(
            LiveTVPortableSyncPreferenceStore.storageEpoch(defaults: defaults), isDirectory: true
        )
    }
}
#endif
