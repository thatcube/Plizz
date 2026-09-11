#if DEBUG
import CoreModels
import FeatureLiveTVCore
import Foundation

struct PrototypeLibraryCatalogRevision: Equatable {
    let channels: [LiveTVPrototypeChannel]
    let generation: UUID
    let revisionIDs: [UUID]
    let isLoaded: Bool

    init(channels: [LiveTVPrototypeChannel], generation: UUID, revisionIDs: [UUID], isLoaded: Bool) {
        self.channels = channels
        self.generation = generation
        self.revisionIDs = revisionIDs
        self.isLoaded = isLoaded
    }

    @MainActor
    init(service: LibraryChannelService, isAuthorized: Bool = true) {
        channels = isAuthorized ? service.channels : []
        generation = service.generation
        let visible = Set(channels.map(\.id))
        revisionIDs = service.definitions.filter { visible.contains($0.catalogID) }
            .compactMap { $0.revisions.last?.id }
        isLoaded = service.isLoaded && isAuthorized
    }
}

struct PrototypeLibraryGuideRequest: Equatable {
    let catalog: PrototypeLibraryCatalogRevision
    let channelIDs: Set<String>
    let range: DateInterval

    init?(
        catalog: PrototypeLibraryCatalogRevision, rows: [LiveTVGuideRowID],
        anchor: LiveTVGuideRowID?, from: Date, to: Date
    ) {
        guard from < to, catalog.isLoaded else { return nil }
        let allowed = Set(catalog.channels.map(\.id))
        let nearby = PrototypeServerGuideRequest.nearbyChannelIDs(
            rows: rows, anchor: anchor, limit: PrototypeGuideWindowRequest.rowLimit
        )
        let channelIDs = Set(nearby).intersection(allowed)
        guard !channelIDs.isEmpty else { return nil }
        self.catalog = catalog
        self.channelIDs = channelIDs
        range = DateInterval(start: from, end: to)
    }
}
#endif
