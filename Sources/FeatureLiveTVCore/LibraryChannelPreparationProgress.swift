#if DEBUG
import CoreModels
import Foundation
import Observation

public struct LibraryChannelPreparationUpdate: Equatable, Sendable {
    public enum Stage: Int, Sendable {
        case checkingServers, readingLibrary, buildingChannels, savingGuides

        public var step: Int {
            switch self {
            case .checkingServers, .readingLibrary: 1
            case .buildingChannels: 2
            case .savingGuides: 3
            }
        }
    }

    public var stage: Stage
    public var serverName: String?
    public var libraryName: String?
    public var kind: MediaItemKind?
    public var scannedItemCount: Int
    public var completedItems: Int
    public var totalItems: Int?
    public var channelCount: Int

    public init(
        stage: Stage, serverName: String? = nil, libraryName: String? = nil,
        kind: MediaItemKind? = nil, scannedItemCount: Int = 0,
        completedItems: Int = 0, totalItems: Int? = nil, channelCount: Int = 0
    ) {
        self.stage = stage
        self.serverName = serverName
        self.libraryName = libraryName
        self.kind = kind
        self.scannedItemCount = scannedItemCount
        self.completedItems = completedItems
        self.totalItems = totalItems
        self.channelCount = channelCount
    }
}

/// Observed only by the progress panel, not by the guide or its containing shell.
@MainActor
@Observable
public final class LibraryChannelPreparationProgress {
    public private(set) var update = LibraryChannelPreparationUpdate(stage: .checkingServers)
    public private(set) var startedAt: Date?
    public private(set) var lastUpdatedAt: Date?

    public init() {}

    public func begin(at date: Date = Date()) {
        update = LibraryChannelPreparationUpdate(stage: .checkingServers)
        startedAt = date
        lastUpdatedAt = date
    }

    public func receive(_ value: LibraryChannelPreparationUpdate, at date: Date = Date()) {
        guard value != update else { return }
        update = value
        lastUpdatedAt = date
    }

    public func isWaiting(at date: Date) -> Bool {
        guard update.stage == .checkingServers || update.stage == .readingLibrary,
              let lastUpdatedAt else { return false }
        return date.timeIntervalSince(lastUpdatedAt) >= 15
    }
}

@MainActor
final class LibraryChannelPreparationReporter {
    private var counts: [String: Int] = [:]
    private let report: @MainActor @Sendable (LibraryChannelPreparationUpdate) -> Void
    var scannedItemCount: Int { counts.values.reduce(0, +) }

    init(report: @escaping @MainActor @Sendable (LibraryChannelPreparationUpdate) -> Void) {
        self.report = report
    }

    func receive(_ update: LibraryChannelPreparationUpdate, accountID: String) {
        counts[accountID] = max(counts[accountID, default: 0], update.scannedItemCount)
        var combined = update
        combined.scannedItemCount = scannedItemCount
        report(combined)
    }
}
#endif
