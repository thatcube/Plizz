import CryptoKit
import Foundation

public struct LiveTVPortableImport: Sendable {
    public var appliedCount = 0
    public var rejectedCount = 0
    public var pendingPlaylists: [String: LiveTVPortableSource] = [:]
    public var localFileSources: [String: LiveTVPortableSource] = [:]
    public var libraryDefinitions: [LibraryChannelDefinition] = []
    public var deletedLibraryIDs: Set<UUID> = []
    public var disabledLibraryIDs: Set<UUID> = []
    public var libraryReviewIDs: Set<UUID> = []
    public var snapshots: [LibraryChannelSnapshot] = []
    public var incompleteSnapshotIDs: Set<UUID> = []
    public var guideMappings: [String: LiveTVPortableGuideMapping?] = [:]
    public var identityHints: [String: LiveTVPortableChannelIdentityHint?] = [:]

    public init() {}
}

/// Adapter for the existing SyncLedger/CloudConfigSyncService contract. The
/// source and preferences stores stay authoritative; this journal retains
/// tombstones and unavailable peer descriptors, not playback or guide caches.
public final class LiveTVPortableSyncAdapter: @unchecked Sendable {
    private struct StoredRecord: Codable {
        let name: String
        let value: Data
        let appliedConsentRevision: String?
        let pendingRemoteFingerprint: String?
    }

    private struct ObservedLocal: Codable {
        var sourceIDs: Set<String> = []
        var libraryIDs: Set<String> = []
        var favoriteOrder: [String] = []
        var pendingMappingIDs: Set<String> = []
        var pendingLibraryIDs: Set<String> = []
        var pendingIdentityIDs: Set<String> = []
        var clearedIdentityHintFingerprints: [String: String]?
        var libraryReviewIDs: Set<String>?
        var hydratedConsentRevision: String?
    }

    private let profileID: String
    private let directory: URL
    private let defaults: UserDefaults
    private let accountEpoch: String
    private let preferences: LiveTVPreferencesStore
    private let namespace: String?
    private static let lock = NSRecursiveLock()
    private static let maximumRecords = 50_000

    public convenience init(directory: URL, profileID: String, defaults: UserDefaults = .standard) {
        self.init(
            directory: directory, profileID: profileID, defaults: defaults,
            namespace: profileID == ProfileStore.defaultProfileID ? nil : profileID
        )
    }

    public init(directory: URL, profileID: String, defaults: UserDefaults = .standard, namespace: String?) {
        self.profileID = profileID
        self.defaults = defaults
        self.namespace = namespace
        accountEpoch = LiveTVPortableSyncPreferenceStore.storageEpoch(defaults: defaults)
        self.directory = directory
            .appendingPathComponent(LiveTVPortableSyncPreferenceStore.storageEpoch(defaults: defaults), isDirectory: true)
            .appendingPathComponent(Self.digest(profileID), isDirectory: true)
        preferences = LiveTVPreferencesStore(
            defaults: defaults, namespace: namespace
        )
    }

    public var isEnabled: Bool {
        accountEpoch == LiveTVPortableSyncPreferenceStore.storageEpoch(defaults: defaults)
            && SyncSetupFeatureFlag(defaults: defaults).isEnabled
            && LiveTVPortableSyncPreferenceStore(defaults: defaults, profileID: profileID, namespace: namespace).isEnabled
    }

    /// The fallback is returned unchanged while consent is off, storage fails, or
    /// the caller cannot hydrate a store. Disabling sync is NOT a remote deletion.
    public func capture(
        sourceStore: any LiveTVSourcesStoring,
        libraryDefinitions: [LibraryChannelDefinition]? = nil,
        snapshots: [LibraryChannelSnapshot] = [],
        guideMappings: [String: LiveTVPortableGuideMapping]? = nil,
        unresolvedGuideMappingIDs: Set<String> = [],
        identityHints: [String: LiveTVPortableChannelIdentityHint]? = nil,
        fallback: [SyncRecordID: Data]
    ) throws -> [SyncRecordID: Data] {
        let baseline = scoped(fallback)
        guard isEnabled else { return baseline }
        if let libraryDefinitions {
            _ = try LibraryChannelPortableState(definitions: libraryDefinitions, snapshots: snapshots)
        } else if !snapshots.isEmpty {
            throw LibraryChannelError.snapshotUnavailable
        }
        let shareableMappings = guideMappings?.filter { $0.value.isSafe }
        Self.lock.lock()
        defer { Self.lock.unlock() }
        let journal = try readJournal()
        var records = journal.records
        let consentRevision = consent.consentRevision
        let localConfiguration = try sourceConfiguration(sourceStore)
        let localPrefs = try preferences.load()
        let localChannelIDs = localPrefs.favoriteIDs.union(localPrefs.hiddenChannelIDs)
            .union(localPrefs.channelOverrides.keys).union(shareableMappings?.keys.map { $0 } ?? [])
        let localSourceIDs = Set(localConfiguration.playlists.map(\.id) + localConfiguration.servers.map(\.id))
        let localLibraryIDs = Set((libraryDefinitions ?? []).map { $0.id.uuidString })
        let previousObservation = try readObserved()
        var hydration: SyncLocalChanges = [:]
        for (name, value) in baseline where records[name] != value {
            guard let recordKey = LiveTVPortableRecordKey.parse(name) else { continue }
            if let previousBytes = records[name] {
                let retriesFailedApply = journal.pendingRemoteFingerprints[name] == Self.digest(value)
                let replaysOptIn = consentRevision != nil
                    && previousObservation.hydratedConsentRevision != consentRevision
                    && journal.appliedConsentRevisions[name] != consentRevision
                guard retriesFailedApply || replaysOptIn else { continue }
                let previous = try LiveTVPortableRecord.decode(previousBytes, key: recordKey)
                if try localValueIsUnchanged(
                    key: recordKey, previous: previous, configuration: localConfiguration,
                    preferences: localPrefs, libraries: libraryDefinitions,
                    mappings: shareableMappings, unresolvedMappingIDs: unresolvedGuideMappingIDs,
                    hints: identityHints, observed: previousObservation
                ) {
                    hydration[name] = value
                }
                continue
            }
            let locallyOwned: Bool
            switch recordKey.kind {
            case .channel: locallyOwned = localChannelIDs.contains(recordKey.entityID)
            case .source: locallyOwned = localSourceIDs.contains(recordKey.entityID)
            case .library: locallyOwned = localLibraryIDs.contains(recordKey.entityID)
            case .snapshot: locallyOwned = false
            case .serverEnrollment:
                locallyOwned = try suppression.records()[recordKey.entityID] != nil
            }
            if !locallyOwned { hydration[name] = value }
        }
        // A cloud engine can have fetched while this collection was disabled.
        // Replay missed values once per opt-in, except records already applied
        // under this consent. An older queued capture cannot roll those back.
        if !hydration.isEmpty {
            _ = try apply(hydration, sourceStore: sourceStore)
            records = try readRecords()
        }
        for (name, value) in baseline where records[name] == nil {
            guard let key = LiveTVPortableRecordKey.parse(name),
                  (try? LiveTVPortableRecord.decode(value, key: key)) != nil else { continue }
            records[name] = value
        }
        var observed = try readObserved()
        let configuration = try sourceConfiguration(sourceStore)
        let localPreferences = try preferences.load()
        let hidden = Dictionary(uniqueKeysWithValues: localPreferences.hiddenChannels.map { ($0.id, $0.name) })
        let favoriteNames = Dictionary(uniqueKeysWithValues: localPreferences.favoriteChannels.map { ($0.id, $0.name) })
        let favoritePositions = Dictionary(uniqueKeysWithValues: localPreferences.favoriteOrder.enumerated().map { ($0.element, $0.offset) })
        let existingChannelIDs = records.keys.compactMap(LiveTVPortableRecordKey.parse)
            .filter { $0.kind == .channel }.map(\.entityID)
        let channelIDs = Set(existingChannelIDs)
            .union(localPreferences.favoriteIDs).union(hidden.keys).union(localPreferences.channelOverrides.keys)
            .union(shareableMappings?.keys.map { $0 } ?? [])
        // Native-ID hints accompany user-authored state, not every downloaded
        // station. A large catalog with no preferences is not a cloud collection.
        for id in channelIDs.sorted() {
            let key = key(.channel, id)
            let previousRecord = try records[key.recordName].map { try LiveTVPortableRecord.decode($0, key: key) }
            let previous = previousRecord?.channel
            let mapping = observed.pendingMappingIDs.contains(id) || unresolvedGuideMappingIDs.contains(id)
                ? previous?.guideMapping : shareableMappings.map { $0[id] } ?? previous?.guideMapping
            let hint = Self.capturedIdentityHint(
                id: id, local: identityHints?[id], previous: previous?.identityHint, observed: observed
            )
            if previousRecord?.isDeleted == true, !localPreferences.favoriteIDs.contains(id),
               hidden[id] == nil, localPreferences.channelOverrides[id] == nil,
               mapping == nil, hint == nil { continue }
            let position = observed.favoriteOrder == localPreferences.favoriteOrder
                ? (previous == nil ? favoritePositions[id] : previous?.favoritePosition)
                : favoritePositions[id]
            let local = LiveTVPortableRecord(channel: LiveTVPortableChannel(
                isFavorite: localPreferences.favoriteIDs.contains(id), hiddenName: hidden[id],
                favoriteName: favoriteNames[id], favoritePosition: localPreferences.favoriteIDs.contains(id) ? position : nil,
                metadata: localPreferences.channelOverrides[id],
                guideMapping: mapping, identityHint: hint
            ))
            try put(local, key: key, into: &records)
            if hint != nil { observed.clearedIdentityHintFingerprints?[id] = nil }
        }
        observed.favoriteOrder = localPreferences.favoriteOrder

        let sourceIDs = Set(configuration.playlists.map(\.id) + configuration.servers.map(\.id))
        for source in configuration.playlists {
            try put(.init(source: .init(
                kind: source.importedPlaylistID == nil ? .playlist : .importedPlaylist,
                name: source.name, isEnabled: source.isEnabled,
                discoversPlaylistGuides: source.discoversPlaylistGuides,
                guideLookbackDays: source.guideLookbackDays, guideLookaheadDays: source.guideLookaheadDays
            )), key: key(.source, source.id), into: &records)
        }
        for source in configuration.servers {
            let sourceKey = key(.source, source.id)
            let prior = try records[sourceKey.recordName].map { try LiveTVPortableRecord.decode($0, key: sourceKey) }.flatMap(\.source)
            if !source.isEnabled,
               try suppression.records()[source.accountID] == nil || prior?.isEnabled == true {
                try suppression.setSuppressed(true, accountID: source.accountID)
            }
            try put(.init(source: .init(
                kind: .server, name: source.name, isEnabled: source.isEnabled, accountID: source.accountID
            )), key: key(.source, source.id), into: &records)
        }
        for removed in observed.sourceIDs.subtracting(sourceIDs) {
            let removedKey = key(.source, removed)
            if let bytes = records[removedKey.recordName],
               let accountID = try LiveTVPortableRecord.decode(bytes, key: removedKey).source?.accountID {
                try suppression.setSuppressed(true, accountID: accountID)
            }
            try put(.init(isDeleted: true), key: key(.source, removed), into: &records)
        }
        observed.sourceIDs = sourceIDs
        for (accountID, suppressed) in try suppression.records() {
            try put(.init(serverEnrollmentSuppressed: suppressed), key: key(.serverEnrollment, accountID), into: &records)
        }

        if let libraryDefinitions {
            let ids = Set(libraryDefinitions.map { $0.id.uuidString })
            for definition in libraryDefinitions where !observed.pendingLibraryIDs.contains(definition.id.uuidString) {
                try put(.init(library: definition), key: key(.library, definition.id.uuidString), into: &records)
            }
            for removed in observed.libraryIDs.subtracting(ids) {
                try put(.init(isDeleted: true), key: key(.library, removed), into: &records)
                observed.pendingLibraryIDs.remove(removed)
                observed.libraryReviewIDs?.remove(removed)
            }
            observed.libraryIDs = ids
        }
        for snapshot in snapshots {
            for part in try LiveTVPortableSnapshots.partition(snapshot) {
                try put(.init(snapshot: part), key: key(.snapshot, part.entityID), into: &records)
            }
        }
        observed.hydratedConsentRevision = consentRevision
        try write(records)
        try writeObserved(observed)
        return records
    }

    /// Applies only this profile's explicit records. Playlist descriptors without
    /// local secure setup remain pending; no URL or parent grant is synthesized.
    public func apply(
        _ changes: SyncLocalChanges, sourceStore: any LiveTVSourcesStoring
    ) throws -> LiveTVPortableImport {
        guard isEnabled else { return LiveTVPortableImport() }
        Self.lock.lock()
        defer { Self.lock.unlock() }
        var records = try readRecords()
        var report = LiveTVPortableImport()
        var accepted: [(LiveTVPortableRecordKey, LiveTVPortableRecord)] = []
        var changedMappingIDs = Set<String>()
        var changedIdentityIDs = Set<String>()
        var clearedHints: [String: String] = [:]
        var restoredHints: Set<String> = []
        var changedLibraryIDs: Set<String> = []
        var incomingFingerprints: [String: String] = [:]
        for (name, value) in changes where records[name] != nil {
            guard let recordKey = LiveTVPortableRecordKey.parse(name), recordKey.profileID == profileID else { continue }
            let bytes = try value ?? LiveTVPortableRecord(isDeleted: true).encoded()
            guard (try? LiveTVPortableRecord.decode(bytes, key: recordKey)) != nil else { continue }
            incomingFingerprints[name] = Self.digest(bytes)
        }
        // Keep a bounded receipt before touching fallible local stores. It
        // permits retrying this exact remote value, not an older queued fallback.
        if !incomingFingerprints.isEmpty { try write(records, receivedFingerprints: incomingFingerprints) }
        let currentSources = try sourceConfiguration(sourceStore)
        for name in changes.keys.sorted() {
            guard let recordKey = LiveTVPortableRecordKey.parse(name),
                  recordKey.profileID == profileID else { continue }
            do {
                let record: LiveTVPortableRecord
                let bytes: Data
                if let value = changes[name] ?? nil {
                    record = try .decode(value, key: recordKey)
                    bytes = value
                } else {
                    record = LiveTVPortableRecord(isDeleted: true)
                    bytes = try record.encoded()
                }
                if let source = record.source {
                    if let existing = currentSources.playlists.first(where: { $0.id == recordKey.entityID }) {
                        let expected: LiveTVPortableSource.Kind = existing.importedPlaylistID == nil ? .playlist : .importedPlaylist
                        guard source.kind == expected else { throw LiveTVPortableStateError.invalidRecord }
                    }
                    if let existing = currentSources.servers.first(where: { $0.id == recordKey.entityID }),
                       source.kind != .server || existing.accountID != source.accountID {
                        throw LiveTVPortableStateError.invalidRecord
                    }
                }
                if recordKey.kind == .channel {
                    let previous = try records[name].map { try LiveTVPortableRecord.decode($0, key: recordKey) }
                    if previous?.channel?.guideMapping != record.channel?.guideMapping {
                        changedMappingIDs.insert(recordKey.entityID)
                    }
                    if previous?.channel?.identityHint != record.channel?.identityHint {
                        changedIdentityIDs.insert(recordKey.entityID)
                    }
                    if record.channel?.identityHint != nil {
                        restoredHints.insert(recordKey.entityID)
                    } else if let previousHint = previous?.channel?.identityHint {
                        clearedHints[recordKey.entityID] = Self.hintFingerprint(previousHint)
                    }
                }
                if recordKey.kind == .library {
                    let previous = try records[name].map { try LiveTVPortableRecord.decode($0, key: recordKey) }
                    if previous?.library != record.library || previous?.isDeleted != record.isDeleted {
                        changedLibraryIDs.insert(recordKey.entityID)
                    }
                }
                records[name] = bytes
                accepted.append((recordKey, record))
            } catch {
                report.rejectedCount += 1
            }
        }
        var configuration = try sourceConfiguration(sourceStore)
        let originalConfiguration = configuration
        let originalSuppression = try suppression.records()
        let savedPreferences = try preferences.load()
        var favorites = savedPreferences.favoriteIDs
        var hidden = Dictionary(uniqueKeysWithValues: savedPreferences.hiddenChannels.map { ($0.id, $0.name) })
        var favoriteNames = Dictionary(uniqueKeysWithValues: savedPreferences.favoriteChannels.map { ($0.id, $0.name) })
        var favoritePositions = Dictionary(uniqueKeysWithValues: savedPreferences.favoriteOrder.enumerated().map { ($0.element, $0.offset) })
        if try readObserved().favoriteOrder == savedPreferences.favoriteOrder {
            for (name, value) in records {
                guard let recordKey = LiveTVPortableRecordKey.parse(name), recordKey.kind == .channel else { continue }
                favoritePositions[recordKey.entityID] = try LiveTVPortableRecord.decode(value, key: recordKey)
                    .channel?.favoritePosition
            }
        }
        var metadata = savedPreferences.channelOverrides
        for (recordKey, record) in accepted {
            switch recordKey.kind {
            case .serverEnrollment:
                try suppression.setSuppressed(record.serverEnrollmentSuppressed ?? true, accountID: recordKey.entityID)
            case .channel:
                if record.channel?.isFavorite == true { favorites.insert(recordKey.entityID) }
                else { favorites.remove(recordKey.entityID) }
                hidden[recordKey.entityID] = record.channel?.hiddenName
                favoriteNames[recordKey.entityID] = record.channel?.favoriteName
                favoritePositions[recordKey.entityID] = record.channel?.favoritePosition
                metadata[recordKey.entityID] = record.channel?.metadata
                report.guideMappings.updateValue(record.channel?.guideMapping, forKey: recordKey.entityID)
                report.identityHints.updateValue(record.channel?.identityHint, forKey: recordKey.entityID)
            case .source:
                applySource(record, id: recordKey.entityID, configuration: &configuration)
            case .library, .snapshot:
                break
            }
        }
        let updatedPreferences = LiveTVPreferences(
            favoriteIDs: favorites, recentChannelIDs: savedPreferences.recentChannelIDs,
            hiddenChannels: hidden.keys.sorted().map { LiveTVHiddenChannel(id: $0, name: hidden[$0]!) },
            favoriteOrder: favorites.sorted {
                let left = favoritePositions[$0] ?? Int.max
                let right = favoritePositions[$1] ?? Int.max
                return left == right ? $0 < $1 : left < right
            },
            favoriteChannels: favoriteNames.keys.sorted().map { LiveTVHiddenChannel(id: $0, name: favoriteNames[$0]!) },
            channelOverrides: metadata, browse: savedPreferences.browse,
            favoriteMultiviews: savedPreferences.favoriteMultiviews
        )
        // Source validation happens before any writes. A failed local store keeps
        // the caller's cloud fallback intact; the next capture never fabricates emptiness.
        try configuration.validate()
        if originalConfiguration != configuration {
            try suppression.prepareChange(previous: originalConfiguration, updated: configuration)
            if let policyStore = sourceStore as? any LiveTVPortableSourcesStoring {
                try policyStore.applySyncedConfiguration(configuration)
            } else {
                try sourceStore.save(configuration)
            }
        }
        if updatedPreferences != savedPreferences { try preferences.save(updatedPreferences) }
        let suppressionDidChange = try suppression.records() != originalSuppression
        try write(records, appliedNames: Set(accepted.map { $0.0.recordName }))
        var observed = try readObserved()
        observed.favoriteOrder = updatedPreferences.favoriteOrder
        observed.pendingMappingIDs.formUnion(changedMappingIDs)
        observed.pendingIdentityIDs.formUnion(changedIdentityIDs)
        var cleared = observed.clearedIdentityHintFingerprints ?? [:]
        for id in restoredHints { cleared[id] = nil }
        cleared.merge(clearedHints, uniquingKeysWith: { _, new in new })
        observed.clearedIdentityHintFingerprints = cleared.isEmpty ? nil : cleared
        observed.libraryReviewIDs?.subtract(changedLibraryIDs)
        for (key, _) in accepted {
            if key.kind == .library { observed.pendingLibraryIDs.insert(key.entityID) }
        }
        try writeObserved(observed)
        report.appliedCount = accepted.count
        try populatePending(records, configuration: configuration, report: &report)
        if report.appliedCount > 0 {
            NotificationCenter.default.post(name: .plozzLiveTVPortableStateDidChange, object: profileID)
            if originalConfiguration != configuration || updatedPreferences != savedPreferences || suppressionDidChange {
                NotificationCenter.default.post(name: .plozzLiveTVPortableStateDidApply, object: profileID)
            }
        }
        return report
    }

    public func pending(sourceStore: any LiveTVSourcesStoring) throws -> LiveTVPortableImport {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        var report = LiveTVPortableImport()
        try populatePending(readRecords(), configuration: sourceStore.load(), report: &report)
        return report
    }

    /// Called by the existing CloudKit account-change hook. Local sources and
    /// preferences remain intact, but the new household needs fresh opt-in.
    public func resetForAccountChange() throws {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        LiveTVPortableSyncPreferenceStore(defaults: defaults, profileID: profileID, namespace: namespace).isEnabled = false
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    public func deferredGuideMappings() throws -> [String: LiveTVPortableGuideMapping?] {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        let records = try readRecords()
        var mappings: [String: LiveTVPortableGuideMapping?] = [:]
        for id in try readObserved().pendingMappingIDs {
            let key = key(.channel, id)
            guard let data = records[key.recordName] else { continue }
            mappings.updateValue(try LiveTVPortableRecord.decode(data, key: key).channel?.guideMapping, forKey: id)
        }
        return mappings
    }

    public func acknowledgeMappings(_ ids: Set<String>) throws {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        var observed = try readObserved()
        observed.pendingMappingIDs.subtract(ids)
        try writeObserved(observed)
    }

    public func deferredIdentityHints() throws -> [String: LiveTVPortableChannelIdentityHint?] {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        let records = try readRecords()
        var hints: [String: LiveTVPortableChannelIdentityHint?] = [:]
        for id in try readObserved().pendingIdentityIDs {
            let key = key(.channel, id)
            guard let data = records[key.recordName] else { continue }
            hints.updateValue(try LiveTVPortableRecord.decode(data, key: key).channel?.identityHint, forKey: id)
        }
        return hints
    }

    public func acknowledgeIdentityHints(_ ids: Set<String>) throws {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        var observed = try readObserved()
        observed.pendingIdentityIDs.subtract(ids)
        try writeObserved(observed)
    }

    public func acknowledgeLibraries(_ ids: Set<UUID>) throws {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        var observed = try readObserved()
        observed.pendingLibraryIDs.subtract(ids.map(\.uuidString))
        observed.libraryReviewIDs?.subtract(ids.map(\.uuidString))
        try writeObserved(observed)
    }

    public func markLibrariesForReview(_ ids: Set<UUID>) throws {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        var observed = try readObserved()
        observed.libraryReviewIDs = (observed.libraryReviewIDs ?? []).union(ids.map(\.uuidString))
        try writeObserved(observed)
    }

    private func applySource(
        _ record: LiveTVPortableRecord, id: String, configuration: inout LiveTVSourcesConfiguration
    ) {
        if record.isDeleted {
            configuration.playlists.removeAll { $0.id == id }
            configuration.servers.removeAll { $0.id == id }
            return
        }
        guard let source = record.source else { return }
        if source.kind == .playlist || source.kind == .importedPlaylist,
           let index = configuration.playlists.firstIndex(where: { $0.id == id }) {
            let expected: LiveTVPortableSource.Kind = configuration.playlists[index].importedPlaylistID == nil
                ? .playlist : .importedPlaylist
            guard source.kind == expected else { return }
            configuration.playlists[index].name = source.name
            configuration.playlists[index].isEnabled = source.isEnabled
            configuration.playlists[index].discoversPlaylistGuides = source.discoversPlaylistGuides ?? true
            configuration.playlists[index].guideLookbackDays = source.guideLookbackDays ?? 1
            configuration.playlists[index].guideLookaheadDays = source.guideLookaheadDays ?? 7
        } else if source.kind == .server,
                  let index = configuration.servers.firstIndex(where: { $0.id == id }),
                  configuration.servers[index].accountID == source.accountID {
            // A descriptor cannot retarget an existing authorization or enroll an
            // account. Native authorized server discovery owns those decisions.
            configuration.servers[index].name = source.name
            configuration.servers[index].isEnabled = source.isEnabled
        }
    }

    private func populatePending(
        _ records: [String: Data], configuration: LiveTVSourcesConfiguration,
        report: inout LiveTVPortableImport
    ) throws {
        var parts: [UUID: [LiveTVPortableSnapshotPart]] = [:]
        var definitions: [LibraryChannelDefinition] = []
        let observed = try readObserved()
        let pendingLibraryIDs = observed.pendingLibraryIDs
        report.libraryReviewIDs = Set((observed.libraryReviewIDs ?? [])
            .intersection(pendingLibraryIDs).compactMap(UUID.init(uuidString:)))
        let localPlaylists = Set(configuration.playlists.map(\.id))
        for name in records.keys.sorted() {
            guard let bytes = records[name], let recordKey = LiveTVPortableRecordKey.parse(name) else { continue }
            let record = try LiveTVPortableRecord.decode(bytes, key: recordKey)
            if let source = record.source, source.kind == .playlist, !localPlaylists.contains(recordKey.entityID) {
                report.pendingPlaylists[recordKey.entityID] = source
            }
            if let source = record.source, source.kind == .importedPlaylist,
               !localPlaylists.contains(recordKey.entityID) {
                report.localFileSources[recordKey.entityID] = source
            }
            if recordKey.kind == .library, pendingLibraryIDs.contains(recordKey.entityID),
               record.isDeleted, let id = UUID(uuidString: recordKey.entityID) {
                report.deletedLibraryIDs.insert(id)
            }
            if let definition = record.library, pendingLibraryIDs.contains(recordKey.entityID) {
                definitions.append(definition)
                if !definition.isEnabled { report.disabledLibraryIDs.insert(definition.id) }
            }
            if let part = record.snapshot { parts[part.snapshotID, default: []].append(part) }
        }
        var complete: [UUID: LibraryChannelSnapshot] = [:]
        let requiredSnapshots = Set(definitions.flatMap(\.revisions).map(\.snapshotID))
        for (id, pieces) in parts where requiredSnapshots.contains(id) {
            do { complete[id] = try LiveTVPortableSnapshots.assemble(pieces) }
            catch { report.incompleteSnapshotIDs.insert(id) }
        }
        for definition in definitions {
            let required = Set(definition.revisions.map(\.snapshotID))
            let missing = required.subtracting(complete.keys)
            report.incompleteSnapshotIDs.formUnion(missing)
            if missing.isEmpty { report.libraryDefinitions.append(definition) }
        }
        report.snapshots = complete.values.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    private func localValueIsUnchanged(
        key: LiveTVPortableRecordKey, previous: LiveTVPortableRecord,
        configuration: LiveTVSourcesConfiguration, preferences: LiveTVPreferences,
        libraries: [LibraryChannelDefinition]?,
        mappings: [String: LiveTVPortableGuideMapping]?,
        unresolvedMappingIDs: Set<String>,
        hints: [String: LiveTVPortableChannelIdentityHint]?, observed: ObservedLocal
    ) throws -> Bool {
        let id = key.entityID
        switch key.kind {
        case .channel:
            let hidden = preferences.hiddenChannels.first { $0.id == id }?.name
            let favoriteName = preferences.favoriteChannels.first { $0.id == id }?.name
            let mapping = observed.pendingMappingIDs.contains(id) || unresolvedMappingIDs.contains(id)
                ? previous.channel?.guideMapping : mappings.map { $0[id] } ?? previous.channel?.guideMapping
            let hint = Self.capturedIdentityHint(
                id: id, local: hints?[id], previous: previous.channel?.identityHint, observed: observed
            )
            if previous.isDeleted, !preferences.favoriteIDs.contains(id), hidden == nil,
               preferences.channelOverrides[id] == nil, mapping == nil, hint == nil { return true }
            let position = observed.favoriteOrder == preferences.favoriteOrder
                ? previous.channel?.favoritePosition : preferences.favoriteOrder.firstIndex(of: id)
            return previous == LiveTVPortableRecord(channel: .init(
                isFavorite: preferences.favoriteIDs.contains(id), hiddenName: hidden,
                favoriteName: favoriteName, favoritePosition: preferences.favoriteIDs.contains(id) ? position : nil,
                metadata: preferences.channelOverrides[id],
                guideMapping: mapping, identityHint: hint
            ))
        case .source:
            if let source = configuration.playlists.first(where: { $0.id == id }) {
                return previous.source == LiveTVPortableSource(
                    kind: source.importedPlaylistID == nil ? .playlist : .importedPlaylist,
                    name: source.name, isEnabled: source.isEnabled,
                    discoversPlaylistGuides: source.discoversPlaylistGuides,
                    guideLookbackDays: source.guideLookbackDays, guideLookaheadDays: source.guideLookaheadDays
                )
            }
            if let source = configuration.servers.first(where: { $0.id == id }) {
                return previous.source == LiveTVPortableSource(
                    kind: .server, name: source.name, isEnabled: source.isEnabled, accountID: source.accountID
                )
            }
            return previous.isDeleted || !observed.sourceIDs.contains(id)
        case .library:
            guard let libraries else { return true }
            if observed.pendingLibraryIDs.contains(id) { return true }
            if let definition = libraries.first(where: { $0.id.uuidString == id }) {
                return previous.library == definition
            }
            return previous.isDeleted || !observed.libraryIDs.contains(id)
        case .snapshot:
            return true
        case .serverEnrollment:
            let current = try suppression.records()[id]
            return current == nil || previous.serverEnrollmentSuppressed == current
        }
    }

    private func key(_ kind: LiveTVPortableRecordKey.Kind, _ id: String) -> LiveTVPortableRecordKey {
        .init(profileID: profileID, kind: kind, entityID: id)
    }

    private var suppression: LiveTVServerEnrollmentSuppressionStore {
        LiveTVServerEnrollmentSuppressionStore(defaults: defaults, profileID: profileID, namespace: namespace)
    }

    private var consent: LiveTVPortableSyncPreferenceStore {
        LiveTVPortableSyncPreferenceStore(defaults: defaults, profileID: profileID, namespace: namespace)
    }

    private func sourceConfiguration(_ store: any LiveTVSourcesStoring) throws -> LiveTVSourcesConfiguration {
        if let policyStore = store as? any LiveTVPortableSourcesStoring {
            return try policyStore.loadSyncConfiguration()
        }
        return try store.load()
    }

    private func scoped(_ records: [String: Data]) -> [String: Data] {
        records.filter { LiveTVPortableRecordKey.parse($0.key)?.profileID == profileID }
    }

    private func put(
        _ record: LiveTVPortableRecord, key: LiveTVPortableRecordKey, into records: inout [String: Data]
    ) throws {
        try record.validate(key: key)
        if let original = records[key.recordName],
           try LiveTVPortableRecord.decode(original, key: key) == record { return }
        records[key.recordName] = try record.encoded()
    }

    private func readRecords() throws -> [String: Data] {
        try readJournal().records
    }

    private func readJournal() throws -> (
        records: [String: Data], appliedConsentRevisions: [String: String], pendingRemoteFingerprints: [String: String]
    ) {
        guard FileManager.default.fileExists(atPath: directory.path) else { return ([:], [:], [:]) }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
            .filter { $0.pathExtension == "record" }
        guard files.count <= Self.maximumRecords else { throw LiveTVPortableStateError.tooLarge }
        var records: [String: Data] = [:]
        var appliedConsentRevisions: [String: String] = [:]
        var pendingRemoteFingerprints: [String: String] = [:]
        var total = 0
        for file in files {
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            guard size <= LiveTVPortableRecord.maximumBytes * 2 else { throw LiveTVPortableStateError.tooLarge }
            total += size
            guard total <= 128 * 1_024 * 1_024 else { throw LiveTVPortableStateError.tooLarge }
            let stored = try JSONDecoder().decode(StoredRecord.self, from: Data(contentsOf: file))
            guard let recordKey = LiveTVPortableRecordKey.parse(stored.name),
                  recordKey.profileID == profileID,
                  file.deletingPathExtension().lastPathComponent == Self.digest(stored.name) else {
                throw LiveTVPortableStateError.wrongProfile
            }
            _ = try LiveTVPortableRecord.decode(stored.value, key: recordKey)
            records[stored.name] = stored.value
            appliedConsentRevisions[stored.name] = stored.appliedConsentRevision
            pendingRemoteFingerprints[stored.name] = stored.pendingRemoteFingerprint
        }
        return (records, appliedConsentRevisions, pendingRemoteFingerprints)
    }

    private func write(
        _ records: [String: Data], appliedNames: Set<String> = [], receivedFingerprints: [String: String] = [:]
    ) throws {
        guard records.count <= Self.maximumRecords,
              records.values.reduce(0, { $0 + $1.count }) <= 64 * 1_024 * 1_024 else {
            throw LiveTVPortableStateError.tooLarge
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let currentConsentRevision = consent.consentRevision
        for (name, bytes) in records {
            let url = directory.appendingPathComponent(Self.digest(name)).appendingPathExtension("record")
            let old = (try? Data(contentsOf: url)).flatMap {
                try? JSONDecoder().decode(StoredRecord.self, from: $0)
            }
            let revision = appliedNames.contains(name) ? currentConsentRevision : old?.appliedConsentRevision
            let pending = receivedFingerprints[name] ?? (
                appliedNames.contains(name) || old?.value != bytes ? nil : old?.pendingRemoteFingerprint
            )
            let stored = StoredRecord(
                name: name, value: bytes, appliedConsentRevision: revision, pendingRemoteFingerprint: pending
            )
            if old?.name == name, old?.value == bytes, old?.appliedConsentRevision == revision,
               old?.pendingRemoteFingerprint == pending { continue }
            try JSONEncoder().encode(stored).write(to: url, options: .atomic)
        }
    }

    private func readObserved() throws -> ObservedLocal {
        let url = directory.appendingPathComponent("observed-local.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return ObservedLocal() }
        let data = try Data(contentsOf: url)
        guard data.count <= 2 * 1_024 * 1_024 else { throw LiveTVPortableStateError.tooLarge }
        return try JSONDecoder().decode(ObservedLocal.self, from: data)
    }

    private func writeObserved(_ observed: ObservedLocal) throws {
        let data = try JSONEncoder().encode(observed)
        guard data.count <= 2 * 1_024 * 1_024 else { throw LiveTVPortableStateError.tooLarge }
        try data.write(to: directory.appendingPathComponent("observed-local.json"), options: .atomic)
    }

    private static func capturedIdentityHint(
        id: String, local: LiveTVPortableChannelIdentityHint?, previous: LiveTVPortableChannelIdentityHint?,
        observed: ObservedLocal
    ) -> LiveTVPortableChannelIdentityHint? {
        guard !observed.pendingIdentityIDs.contains(id), let local else { return previous }
        // An unchanged downloaded catalog must not echo an explicitly removed
        // association back into sync. Different evidence may establish a new one.
        guard observed.clearedIdentityHintFingerprints?[id] != hintFingerprint(local) else { return previous }
        return local
    }

    private static func hintFingerprint(_ hint: LiveTVPortableChannelIdentityHint) -> String {
        digest(hint.sourceID + "\u{1F}" + hint.nativeID)
    }

    private static func digest(_ value: String) -> String {
        digest(Data(value.utf8))
    }

    private static func digest(_ value: Data) -> String {
        SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined()
    }
}
