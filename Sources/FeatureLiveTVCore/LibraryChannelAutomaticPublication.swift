#if DEBUG
import CoreModels
import Foundation

struct LibraryChannelPublication: Sendable {
    var definitions: [LibraryChannelDefinition]
    var snapshots: [UUID: LibraryChannelSnapshot]
    var schedules: [UUID: LibraryChannelSchedule]
    var staged: [LibraryChannelSnapshot]
}

enum LibraryChannelAutomaticPublication {
    static func prepare(
        groups: [LibraryChannelAutomaticPlanner.Group], profileID: String,
        previous: [LibraryChannelDefinition], snapshots: [UUID: LibraryChannelSnapshot],
        schedules: [UUID: LibraryChannelSchedule], blockedSourceIDs: Set<UUID>, now: Date
    ) throws -> LibraryChannelPublication {
        let seconds = now.timeIntervalSince1970
        guard seconds.isFinite, seconds >= 0, seconds < 253_402_300_798 else {
            throw LibraryChannelError.invalidSnapshot
        }
        let epoch = Int64(seconds.rounded(.down))
        let keys = Set(groups.map(\.key))
        var next = LibraryChannelPublication(definitions: [], snapshots: snapshots, schedules: schedules, staged: [])
        for var definition in previous {
            try Task.checkCancellation()
            if definition.isAutomatic {
                while definition.revisions.count > 1,
                      definition.revisions[1].epochSeconds <= epoch - 86_400 {
                    definition.revisions.removeFirst()
                }
                if let key = definition.automaticKey, !keys.contains(key) {
                    next.schedules[definition.id] = nil
                    continue
                }
            }
            next.definitions.append(definition)
        }
        let initialReferences = Set(next.definitions.flatMap(\.revisions).map(\.snapshotID))
        next.snapshots = next.snapshots.filter { initialReferences.contains($0.key) }
        for group in groups {
            try Task.checkCancellation()
            let id = LibraryChannelAutomaticIdentity.channelID(profileID: profileID, key: group.key)
            let sourceID = LibraryChannelAutomaticIdentity.sourceID(profileID: profileID, key: group.key)
            let existingIndex = next.definitions.firstIndex { $0.id == id }
            if let existingIndex {
                guard next.definitions[existingIndex].automaticKey == group.key,
                      next.definitions[existingIndex].sourceID == sourceID else {
                    throw LibraryChannelError.publicationConflict
                }
            }
            // Source approval is an independent authority, never a planner hint to route around.
            guard !blockedSourceIDs.contains(sourceID) else { continue }
            if existingIndex == nil && next.definitions.count >= LibraryChannelPortableState.maximumDefinitions {
                if group.isCatchall { throw LibraryChannelError.catalogTooLarge }
                continue
            }
            let candidate = try LibraryChannelSnapshot(items: group.items, createdAt: now)
            var definition = existingIndex.map { next.definitions[$0] } ?? LibraryChannelDefinition(
                id: id, sourceID: sourceID, profileID: profileID, revisions: [], automaticKey: group.key
            )
            if let missing = definition.revisions.lastIndex(where: { next.snapshots[$0.snapshotID] == nil }),
               missing + 1 < definition.revisions.count {
                definition.revisions.removeFirst(missing + 1)
            }
            let latest = definition.revisions.last
            let unchanged = latest.map {
                $0.recipe == group.recipe && next.snapshots[$0.snapshotID]?.items == candidate.items
            } ?? false
            var addedSnapshot: LibraryChannelSnapshot?
            if !unchanged {
                let boundary: Int64
                let recoverableSchedule: LibraryChannelSchedule?
                if let cached = schedules[id] { recoverableSchedule = cached }
                else if !definition.revisions.isEmpty,
                        definition.revisions.allSatisfy({ next.snapshots[$0.snapshotID] != nil }) {
                    recoverableSchedule = try LibraryChannelSchedule(definition: definition, snapshots: next.snapshots)
                } else { recoverableSchedule = nil }
                if let schedule = recoverableSchedule, let latest {
                    boundary = try schedule.slot(
                        at: Date(timeIntervalSince1970: Double(max(epoch, definition.publishedThrough, latest.epochSeconds)))
                    ).endSeconds
                } else if let latest {
                    // Eviction erased the evidence needed to reproduce the frozen slots.
                    // Restart only beyond that entire horizon, never fabricate replacement guide cells.
                    boundary = max(epoch, definition.publishedThrough, latest.epochSeconds) + 1
                    definition.revisions = []
                } else {
                    boundary = epoch
                }
                guard definition.revisions.count < 32 else { throw LibraryChannelError.tooManyRevisions }
                definition.revisions.append(LibraryChannelRevision(
                    snapshotID: candidate.id, recipe: group.recipe, epochSeconds: boundary
                ))
                addedSnapshot = candidate
            }
            // There is intentionally no independent per-channel auto opt-in: the profile switch owns it.
            definition.isEnabled = true
            var trial = next.definitions
            if let existingIndex { trial[existingIndex] = definition }
            else { trial.append(definition) }
            let references = Set(trial.flatMap(\.revisions).map(\.snapshotID))
            let retainedCount = next.snapshots.reduce(0) { $0 + (references.contains($1.key) ? $1.value.items.count : 0) }
            guard retainedCount + (addedSnapshot?.items.count ?? 0) <= LibraryChannelPortableState.maximumItems else {
                if group.isCatchall { throw LibraryChannelError.catalogTooLarge }
                // Retire an optional stale group instead of retaining a misleading catalogue indefinitely.
                if let existingIndex {
                    next.definitions.remove(at: existingIndex)
                    next.schedules[id] = nil
                    let retained = Set(next.definitions.flatMap(\.revisions).map(\.snapshotID))
                    next.snapshots = next.snapshots.filter { retained.contains($0.key) }
                }
                continue
            }
            if let addedSnapshot {
                next.snapshots[addedSnapshot.id] = addedSnapshot
                next.staged.append(addedSnapshot)
            }
            next.snapshots = next.snapshots.filter { references.contains($0.key) }
            if definition.revisions.allSatisfy({ next.snapshots[$0.snapshotID] != nil }) {
                if schedules[id]?.definition.revisions != definition.revisions {
                    next.schedules[id] = try LibraryChannelSchedule(definition: definition, snapshots: next.snapshots)
                }
            } else { throw LibraryChannelError.snapshotUnavailable }
            next.definitions = trial
        }
        let references = Set(next.definitions.flatMap(\.revisions).map(\.snapshotID))
        next.snapshots = next.snapshots.filter { references.contains($0.key) }
        next.staged = next.staged.filter { references.contains($0.id) }
        return next
    }
}
#endif
