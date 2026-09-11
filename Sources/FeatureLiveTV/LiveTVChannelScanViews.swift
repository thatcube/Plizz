#if DEBUG
import CoreModels
import CoreUI
import FeatureLiveTVCore
import SwiftUI

/// Embed in Sources or browsing controls. The host keeps the coordinator alive
/// when this page closes, so scanning never blocks browsing or playback.
public struct LiveTVScanSourceSection: View {
    private let coordinator: LiveTVChannelScanCoordinator
    private let sourceID: String
    private let sourceName: String?

    public init(coordinator: LiveTVChannelScanCoordinator, sourceID: String, sourceName: String? = nil) {
        self.coordinator = coordinator
        self.sourceID = sourceID
        self.sourceName = sourceName
    }

    public var body: some View {
        if let sourceName {
            SettingsSectionGroup(verbatim: sourceName) {
                LiveTVScanSourceActions(coordinator: coordinator, sourceID: sourceID)
            }
        } else {
            SettingsSectionGroup {
                LiveTVScanSourceActions(coordinator: coordinator, sourceID: sourceID)
            }
        }
    }
}

/// Destination for the Sources/browsing "Check channel availability" action.
/// Only sources already bound under the current profile's authority are shown.
public struct LiveTVScanSourcesView: View {
    private let coordinator: LiveTVChannelScanCoordinator
    private let sourceNames: [String: String]

    public init(coordinator: LiveTVChannelScanCoordinator, sourceNames: [String: String]) {
        self.coordinator = coordinator
        self.sourceNames = sourceNames
    }

    public var body: some View {
        LiveTVSettingsPage(title: "Check channels") {
            if coordinator.sourceIDs.isEmpty {
                SettingsSectionGroup {
                    Text("Import a playlist before scanning.")
                    LiveTVScanIssueContent(coordinator: coordinator)
                }
            } else {
                ForEach(coordinator.sourceIDs.sorted(), id: \.self) { id in
                    LiveTVScanSourceSection(
                        coordinator: coordinator, sourceID: id, sourceName: sourceNames[id]
                    )
                }
            }
        }
    }
}

private struct LiveTVScanSourceActions: View {
    let coordinator: LiveTVChannelScanCoordinator
    let sourceID: String

    var body: some View {
        if let progress = coordinator.progress, progress.sourceID == sourceID,
           coordinator.isScanning {
            LiveTVScanProgressContent(coordinator: coordinator, progress: progress)
        } else if coordinator.canScan(sourceID: sourceID) {
            Button {
                coordinator.start(sourceID: sourceID)
            } label: {
                if coordinator.hasResults(sourceID: sourceID) {
                    SettingsRowLabel(icon: "arrow.clockwise", title: "Rescan channels")
                } else {
                    SettingsRowLabel(icon: "checkmark.magnifyingglass", title: "Scan channels")
                }
            }
            .buttonStyle(SettingsFocusButtonStyle(size: .contained))
            .accessibilityIdentifier("live-tv-scan-source")
        }
        if coordinator.hasResults(sourceID: sourceID) {
            NavigationLink {
                LiveTVScanResultsView(coordinator: coordinator, sourceID: sourceID)
            } label: {
                SettingsRowLabel(icon: "checklist", title: "Scan results")
            }
            .buttonStyle(SettingsFocusButtonStyle(size: .contained))
            NavigationLink {
                LiveTVScanResultsView(coordinator: coordinator, sourceID: sourceID, showHiddenOnly: true)
            } label: {
                SettingsRowLabel(icon: "eye.slash", title: "Show hidden")
            }
            .buttonStyle(SettingsFocusButtonStyle(size: .contained))
        }
        LiveTVScanIssueContent(coordinator: coordinator)
    }
}

/// Present only after a successful user import; Skip dismisses this offer, not
/// the channels. Importing a source never starts network probes implicitly.
public struct LiveTVScanImportOffer: View {
    private let coordinator: LiveTVChannelScanCoordinator
    private let sourceID: String
    private let skip: () -> Void

    public init(coordinator: LiveTVChannelScanCoordinator, sourceID: String, skip: @escaping () -> Void) {
        self.coordinator = coordinator
        self.sourceID = sourceID
        self.skip = skip
    }

    public var body: some View {
        if coordinator.canScan(sourceID: sourceID) {
            SettingsSectionGroup("Check channels") {
                Text("Scan for unavailable links, or start watching now.")
                    .foregroundStyle(.secondary)
                Button("Scan channels", systemImage: "checkmark.magnifyingglass") {
                    if coordinator.start(sourceID: sourceID) { skip() }
                }
                .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                .accessibilityIdentifier("live-tv-import-scan")
                Button("Not now", action: skip)
                    .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                    .accessibilityIdentifier("live-tv-skip-scan")
            }
        }
    }
}

public struct LiveTVScanResultsView: View {
    private let coordinator: LiveTVChannelScanCoordinator
    private let sourceID: String
    @State private var showHiddenOnly: Bool

    public init(
        coordinator: LiveTVChannelScanCoordinator, sourceID: String, showHiddenOnly: Bool = false
    ) {
        self.coordinator = coordinator
        self.sourceID = sourceID
        _showHiddenOnly = State(initialValue: showHiddenOnly)
    }

    public var body: some View {
        let rows = coordinator.results(sourceID: sourceID)
        LiveTVSettingsPage(title: "Scan results") {
            if let progress = coordinator.progress, progress.sourceID == sourceID {
                SettingsSectionGroup {
                    if coordinator.isScanning {
                        LiveTVScanProgressContent(coordinator: coordinator, progress: progress)
                    } else if progress.isCancelled {
                        Text("Scan stopped. \(progress.completed) of \(progress.total) checked.")
                    } else {
                        Text("Scan complete. \(progress.completed) channels checked.")
                    }
                }
            }
            SettingsSectionGroup {
                LiveTVScanSummary(rows: rows)
                Toggle("Show hidden only", isOn: $showHiddenOnly)
                if rows.contains(where: \.isScanHidden) {
                    Button("Restore hidden channels", systemImage: "eye") {
                        coordinator.restoreAll(sourceID: sourceID)
                    }
                    .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                    .accessibilityIdentifier("live-tv-scan-restore-all")
                }
                if coordinator.canScan(sourceID: sourceID), !coordinator.isScanning {
                    Button("Rescan channels", systemImage: "arrow.clockwise") {
                        coordinator.start(sourceID: sourceID)
                    }
                    .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                }
                LiveTVScanIssueContent(coordinator: coordinator)
            }
            if showHiddenOnly && !rows.contains(where: \.isScanHidden) {
                SettingsSectionGroup { Text("No channels hidden by scanning.") }
            } else if rows.isEmpty {
                SettingsSectionGroup { Text("No checks yet.") }
            } else {
                LazyVStack(spacing: 16) {
                    ForEach(rows.filter { !showHiddenOnly || $0.isScanHidden }) { row in
                        LiveTVScanResultRow(row: row) { coordinator.restore(channelID: row.id) }
                    }
                }
            }
        }
    }
}

private struct LiveTVScanProgressContent: View {
    let coordinator: LiveTVChannelScanCoordinator
    let progress: LiveTVChannelScanProgress

    var body: some View {
        ProgressView(value: Double(progress.completed), total: Double(max(1, progress.total))) {
            Text("Checking channels")
        } currentValueLabel: {
            Text("\(progress.completed) of \(progress.total)")
        }
        .accessibilityIdentifier("live-tv-scan-progress")
        Button("Cancel scan", systemImage: "xmark") { coordinator.cancel() }
            .buttonStyle(SettingsFocusButtonStyle(size: .contained))
            .accessibilityIdentifier("live-tv-cancel-scan")
    }
}

private struct LiveTVScanSummary: View {
    let rows: [LiveTVChannelScanRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(rows.filter { $0.status == .reachable }.count) reachable")
            Text("\(rows.filter(\.isScanHidden).count) unavailable and hidden")
            Text("\(rows.filter { $0.status == .uncertain }.count) need another check")
            Text("Checks reachability, not playback support.")
                .foregroundStyle(.secondary)
        }
    }
}

private struct LiveTVScanResultRow: View {
    let row: LiveTVChannelScanRow
    let restore: () -> Void

    var body: some View {
        SettingsSectionGroup {
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: row.name)
                Text(row.reason.scanDescription)
                    .foregroundStyle(.secondary)
            }
            if row.isScanHidden {
                Button("Restore channel", systemImage: "eye", action: restore)
                    .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                    .accessibilityIdentifier("live-tv-scan-restore-channel")
            }
        }
    }
}

private struct LiveTVScanIssueContent: View {
    let coordinator: LiveTVChannelScanCoordinator

    var body: some View {
        if let issue = coordinator.issue {
            Label {
                Text(issue.scanDescription)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
            if issue == .healthSaveFailed {
                Button("Retry saving") { coordinator.retrySaving() }
                    .buttonStyle(SettingsFocusButtonStyle(size: .contained))
            }
        }
    }
}

private extension LiveTVChannelScanError {
    var scanDescription: LocalizedStringResource {
        switch self {
        case .ineligibleChannel, .sourceUnavailable, .invalidCatalog:
            "Refresh this source before scanning."
        case .healthLoadFailed:
            "Saved scan results couldn't be read. Refresh sources to retry."
        case .healthSaveFailed:
            "Latest scan results couldn't be saved."
        }
    }
}

private extension LiveTVChannelHealthReason {
    var scanDescription: LocalizedStringResource {
        switch self {
        case .mediaObserved: "Media reached."
        case .repeatedlyMissing: "Link unavailable on repeated checks."
        case .authorizationRequired: "Check this source's sign-in or access."
        case .restricted: "Access is restricted in this region."
        case .timedOut: "Check timed out. Try again later."
        case .networkUnavailable: "Check your connection, then rescan."
        case .rateLimited: "Source is busy. Rescan later."
        case .serverFailure: "Source couldn't respond. Rescan later."
        case .staleManifest: "Stream playlist is out of date. Rescan later."
        case .expiredSegment: "Recent media expired. Rescan later."
        case .encryptedMedia: "Encrypted stream. Playback wasn't checked."
        case .unsupportedMedia: "Playback support wasn't checked."
        case .invalidManifest: "Stream response wasn't recognized."
        case .unsafeOrigin: "Stream address isn't allowed by its network policy."
        case .responseLimit, .requestLimit: "Check reached its safety limit."
        }
    }
}
#endif
