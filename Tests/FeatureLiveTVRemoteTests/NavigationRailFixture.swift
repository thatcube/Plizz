import CoreModels
import CoreUI
import Observation
import SwiftUI
@testable import AppShell

struct NavigationRailFixture: View {
    @State private var model = NavigationRailFixtureModel()

    var body: some View {
        NavigationRailShell(
            profile: model.profile,
            entries: model.entries,
            destinations: model.destinations,
            selection: $model.selection,
            onOpenProfileSwitcher: {},
            chrome: model.chrome,
            content: NavigationStack {
                if model.selection == .search {
                    SearchFixture()
                } else {
                    NavigationRailFixturePage(model: model)
                }
            }
        )
    }
}

@MainActor
@Observable
private final class NavigationRailFixtureModel {
    let profile = Profile(name: "Viewer")
    let chrome = NavigationChromeModel()
    let entries: [NavigationRailLibraryEntry]
    var selection = NavigationRailDestination.settings
    var destinations: [NavigationRailDestination]

    init() {
        let destination: NavigationRailDestination =
            ProcessInfo.processInfo.arguments.contains("--navigation-search") ? .search : .settings
        entries = (0..<30).map { index in
            NavigationRailLibraryEntry(
                key: "account:\(index)",
                library: AggregatedLibrary(
                    accountID: "account", accountName: "Account", serverName: "Server",
                    providerKind: .jellyfin,
                    library: MediaLibrary(id: "\(index)", title: "Library \(index)", kind: .movie)
                )
            )
        }
        destinations = [.home] + entries.map(\.destination) + [destination]
        selection = destination
    }
}

private struct NavigationRailFixturePage: View {
    let model: NavigationRailFixtureModel
    @Environment(\.plozzPinnedSidebarInteraction) private var interaction

    var body: some View {
        VStack(spacing: 40) {
            Button("Page content") {}
                .accessibilityIdentifier("navigation-page")
            Button("Reorder navigation") {
                model.destinations.removeAll { $0 == .settings }
                model.destinations.insert(.settings, at: 0)
            }
            .accessibilityIdentifier("navigation-reorder")
            Button("Open navigation") { interaction?.requestOpen() }
                .accessibilityIdentifier("navigation-open")
        }
        .buttonStyle(SettingsFocusButtonStyle())
        .frame(width: 500)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .focusSection()
    }
}
