#if DEBUG
import CoreUI
import FeatureLiveTVCore
import SwiftUI

enum LiveTVMultiviewSelection: Equatable {
    case add
    case replace(UUID)

    var title: LocalizedStringResource {
        switch self {
        case .add: "Add channel to Multiview"
        case .replace: "Replace channel in Multiview"
        }
    }

    @MainActor
    func apply(_ channel: LiveTVPrototypeChannel, to coordinator: LiveTVMultiviewCoordinator) {
        switch self {
        case .add: coordinator.add(channel)
        case .replace(let id): coordinator.replace(id, with: channel)
        }
    }
}

struct LiveTVMultiviewGuideSelectionHeader: View {
    let selection: LiveTVMultiviewSelection
    let cancel: () -> Void

    var body: some View {
        HStack {
            Text(selection.title)
                .font(.callout.weight(.semibold))
                .accessibilityIdentifier("live-multiview-guide-selection")
            Spacer()
            Button("Cancel", systemImage: "xmark", action: cancel)
                .buttonStyle(PrototypeButtonStyle(surface: .control))
                .accessibilityIdentifier("live-multiview-cancel-selection")
        }
        #if os(tvOS)
        .focusSection()
        .onExitCommand(perform: cancel)
        #endif
    }
}

struct LiveTVMultiviewGuideExit: ViewModifier {
    let cancel: (() -> Void)?

    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(tvOS)
        if let cancel {
            content.onExitCommand(perform: cancel)
        } else {
            content
        }
        #else
        content
        #endif
    }
}

struct LiveTVMultiviewFavoritesView: View {
    let model: LiveTVPrototypeModel
    let open: (LiveTVMultiviewFavorite) -> Void

    var body: some View {
        LiveTVSettingsPage(title: "Favorite Multiviews") {
            if model.favoriteMultiviews.isEmpty {
                ContentUnavailableView(
                    "No favorite Multiviews", systemImage: "star",
                    description: Text("Favorite a Multiview to open its channels and layout here."))
            } else {
                SettingsSectionGroup {
                    ForEach(model.favoriteMultiviews) { favorite in
                        Button {
                            open(favorite)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(favorite.name).lineLimit(2)
                                HStack {
                                    Text("\(favorite.channelIDs.count) channels")
                                    Text(favorite.layout.title)
                                }
                                .font(.caption)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                        .accessibilityIdentifier("live-multiview-saved-\(favorite.id)")
                        .contextMenu {
                            Button("Remove from Favorites", systemImage: "star.slash") {
                                model.removeMultiviewFavorite(favorite.id)
                            }
                        }
                    }
                }
            }
            if model.preferencesIssue != nil {
                SettingsSectionGroup {
                    Text("Multiview favorites could not be loaded or saved. Retry to keep your changes.")
                    Button("Retry", action: model.retryPreferences)
                        .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                }
            }
        }
    }
}
#endif
