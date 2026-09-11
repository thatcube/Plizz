import Foundation

/// The exact reproducible inputs, with no credentials, playback locators,
/// ordinary watch state or source-approval grants.
public struct LibraryChannelPortableState: Codable, Equatable, Sendable {
    public static let maximumDefinitions = 100
    public static let maximumItems = 200_000
    public let version: Int
    public let definitions: [LibraryChannelDefinition]
    public let snapshots: [LibraryChannelSnapshot]

    public init(definitions: [LibraryChannelDefinition], snapshots: [LibraryChannelSnapshot]) throws {
        version = 1
        self.definitions = definitions
        self.snapshots = snapshots
        try validate()
    }

    public func validate() throws {
        guard version == 1 else { throw LibraryChannelError.unsupportedVersion }
        guard definitions.count <= Self.maximumDefinitions,
              Set(definitions.map(\.id)).count == definitions.count,
              Set(definitions.map(\.sourceID)).count == definitions.count,
              Set(definitions.map(\.profileID)).count <= 1,
              snapshots.count <= Self.maximumDefinitions * 32,
              Set(snapshots.map(\.id)).count == snapshots.count else {
            throw LibraryChannelError.invalidSnapshot
        }
        let required = Set(definitions.flatMap(\.revisions).map(\.snapshotID))
        guard required == Set(snapshots.map(\.id)) else { throw LibraryChannelError.snapshotUnavailable }
        var itemCount = 0
        for snapshot in snapshots {
            try snapshot.validate()
            itemCount += snapshot.items.count
            guard itemCount <= Self.maximumItems else { throw LibraryChannelError.catalogTooLarge }
        }
        let indexed = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0) })
        for definition in definitions {
            _ = try LibraryChannelSchedule(definition: definition, snapshots: indexed)
        }
    }
}

/// The sync transport resolves record/tombstone ordering. This layer refuses
/// revisions that would alter a locally published broadcast, even if the remote
/// record is newer. Keep such a record pending instead of acknowledging it.
public enum LibraryChannelImportMerger {
    public static func merge(
        profileID: String,
        current: [LibraryChannelDefinition],
        incoming: [LibraryChannelDefinition],
        deletedIDs: Set<UUID>,
        snapshots: [UUID: LibraryChannelSnapshot],
        at now: Date = Date()
    ) throws -> [LibraryChannelDefinition] {
        let seconds = now.timeIntervalSince1970
        guard seconds.isFinite, abs(seconds) < 253_402_300_799,
              current.count <= LibraryChannelPortableState.maximumDefinitions,
              incoming.count <= LibraryChannelPortableState.maximumDefinitions,
              deletedIDs.count <= LibraryChannelPortableState.maximumDefinitions,
              Set(current.map(\.id)).count == current.count,
              Set(incoming.map(\.id)).count == incoming.count,
              deletedIDs.isDisjoint(with: incoming.map(\.id)) else {
            throw LibraryChannelError.invalidSnapshot
        }
        guard !profileID.isEmpty, (current + incoming).allSatisfy({ $0.profileID == profileID }) else {
            throw LibraryChannelError.authorizationChanged
        }
        var merged = current.filter { !deletedIDs.contains($0.id) }
        for remote in incoming {
            try remote.validate()
            guard let index = merged.firstIndex(where: { $0.id == remote.id }) else {
                merged.append(remote)
                continue
            }
            let local = merged[index]
            guard local.sourceID == remote.sourceID, local.profileID == remote.profileID else {
                throw LibraryChannelError.publicationConflict
            }
            let oldSchedule = try LibraryChannelSchedule(definition: local, snapshots: snapshots)
            let known = Dictionary(uniqueKeysWithValues: local.revisions.map { ($0.id, $0) })
            var additions: [LibraryChannelRevision] = []
            for revision in remote.revisions {
                if let previous = known[revision.id] {
                    guard previous == revision else { throw LibraryChannelError.publicationConflict }
                } else if revision.epochSeconds < local.revisions[0].epochSeconds {
                    continue
                } else {
                    additions.append(revision)
                }
            }
            if !additions.isEmpty {
                let latestEpoch = local.revisions.last!.epochSeconds
                let frozenThrough = max(max(Int64(seconds.rounded(.down)), local.publishedThrough), latestEpoch)
                let earliest = try oldSchedule.slot(
                    at: Date(timeIntervalSince1970: Double(frozenThrough))
                ).endSeconds
                guard additions.allSatisfy({ $0.epochSeconds >= earliest }) else {
                    throw LibraryChannelError.publicationConflict
                }
            }
            var combined = local
            combined.revisions += additions
            combined.revisions.sort { $0.epochSeconds < $1.epochSeconds }
            combined.publishedThrough = max(local.publishedThrough, remote.publishedThrough)
            combined.isEnabled = remote.isEnabled
            prune(&combined, at: now)
            merged[index] = combined
        }
        for index in merged.indices { prune(&merged[index], at: now) }
        let required = Set(merged.flatMap(\.revisions).map(\.snapshotID))
        let referenced = try required.map { id -> LibraryChannelSnapshot in
            guard let snapshot = snapshots[id], snapshot.id == id else {
                throw LibraryChannelError.snapshotUnavailable
            }
            return snapshot
        }
        _ = try LibraryChannelPortableState(definitions: merged, snapshots: referenced)
        return merged
    }

    private static func prune(_ definition: inout LibraryChannelDefinition, at now: Date) {
        let cutoff = Int64(now.addingTimeInterval(-86_400).timeIntervalSince1970.rounded(.down))
        while definition.revisions.count > 1, definition.revisions[1].epochSeconds <= cutoff {
            definition.revisions.removeFirst()
        }
    }
}
