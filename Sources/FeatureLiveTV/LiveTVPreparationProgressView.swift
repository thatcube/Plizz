#if DEBUG
import CoreModels
import CoreUI
import FeatureLiveTVCore
import SwiftUI

struct LiveTVPreparationProgressView: View {
    let progress: LibraryChannelPreparationProgress
    @Environment(\.themePalette) private var palette

    var body: some View {
        let update = progress.update
        VStack(alignment: .leading, spacing: PlozzTheme.Spacing.medium) {
            HStack(alignment: .firstTextBaseline) {
                Text(update.stage.title).font(.headline)
                    .accessibilityIdentifier("live-tv-preparation-stage")
                Spacer(minLength: PlozzTheme.Spacing.small)
                Text("Step \(update.stage.step) of 3")
                    .font(.caption).foregroundStyle(palette.secondaryText)
            }
            if let library = update.libraryName {
                Text(library).font(.callout.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("live-tv-preparation-library")
            }
            if let server = update.serverName {
                Text(server).font(.caption).foregroundStyle(palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if update.stage == .readingLibrary, let total = update.totalItems, total > 0 {
                VStack(alignment: .leading, spacing: PlozzTheme.Spacing.xSmall) {
                    HStack {
                        Text(update.kind.readingLabel).font(.caption)
                        Spacer(minLength: PlozzTheme.Spacing.small)
                        Text("\(update.completedItems, format: .number) of \(total, format: .number)")
                            .monospacedDigit()
                            .accessibilityIdentifier("live-tv-preparation-page-count")
                    }
                    ProgressView(value: Double(update.completedItems), total: Double(total))
                        .tint(palette.accent)
                        .accessibilityLabel(update.kind.readingLabel)
                        .accessibilityIdentifier("live-tv-automatic-progress")
                }
            } else {
                ProgressView().accessibilityLabel(update.stage.title)
                    .accessibilityIdentifier("live-tv-automatic-progress")
            }
            Text("\(update.scannedItemCount, format: .number) library items checked")
                .font(.callout).monospacedDigit()
                .accessibilityIdentifier("live-tv-preparation-total")
            if update.channelCount > 0 {
                Text("\(update.channelCount, format: .number) channels in your lineup")
                    .font(.callout).monospacedDigit()
            }
            LiveTVPreparationActivityView(progress: progress)
            Text("Reading library details, not downloading videos. Turn off Plozz channels to cancel preparation.")
                .font(.caption).foregroundStyle(palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(palette.primaryText)
    }
}

private struct LiveTVPreparationActivityView: View {
    let progress: LibraryChannelPreparationProgress
    @Environment(\.themePalette) private var palette

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: PlozzTheme.Spacing.xSmall) {
                if let startedAt = progress.startedAt {
                    HStack(spacing: PlozzTheme.Spacing.xSmall) {
                        Text("Elapsed")
                        Text(startedAt, style: .timer).monospacedDigit()
                    }
                    .font(.caption).foregroundStyle(palette.secondaryText)
                }
                if progress.isWaiting(at: context.date) {
                    Text("Waiting for the server to respond. No new items have arrived recently.")
                        .font(.caption).foregroundStyle(palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("live-tv-preparation-waiting")
                }
            }
        }
    }
}

private extension LibraryChannelPreparationUpdate.Stage {
    var title: LocalizedStringResource {
        switch self {
        case .checkingServers: "Checking your libraries"
        case .readingLibrary: "Reading library items"
        case .buildingChannels: "Building your channels"
        case .savingGuides: "Saving programme guides"
        }
    }
}

private extension Optional where Wrapped == MediaItemKind {
    var readingLabel: LocalizedStringResource {
        switch self {
        case .some(.movie): "Movies"
        case .some(.episode): "Episodes"
        case .some(.series): "TV shows"
        default: "Library items"
        }
    }
}
#endif
