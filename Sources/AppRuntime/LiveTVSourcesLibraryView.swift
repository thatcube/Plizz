#if DEBUG && canImport(SwiftUI)
import CoreUI
import SwiftUI

/// Keep generated-channel editing on the profile's existing library runtime,
/// including its retry path instead of starting an unauthorised second load.
public struct LiveTVSourcesLibraryView<Content: View>: View {
    private let runtime: LiveTVSourcesRuntime
    private let library: LiveTVLibraryRuntime
    private let content: () -> Content

    public init(
        runtime: LiveTVSourcesRuntime, library: LiveTVLibraryRuntime,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.runtime = runtime
        self.library = library
        self.content = content
    }

    public var body: some View {
        if !runtime.isCurrent {
            ContentUnavailableView(
                "Profile access changed", systemImage: "lock",
                description: Text("Reopen Sources to continue.")
            )
        } else if library.isLoading {
            ProgressView("Loading libraries")
        } else if library.authorizationID != nil, library.service.isLoaded {
            content()
        } else {
            ContentUnavailableView {
                Label("Plozz channels unavailable", systemImage: "sparkles.tv")
            } description: {
                if let issue = library.issue { Text(issue.message) }
                else { Text("Your libraries couldn't be loaded.") }
            } actions: {
                Button("Retry", systemImage: "arrow.clockwise", action: library.retry)
                    .plozzActionButton(role: .secondary)
            }
        }
    }
}

public struct LiveTVSourcesScanView<Content: View>: View {
    private let runtime: LiveTVSourcesRuntime
    private let content: () -> Content

    public init(runtime: LiveTVSourcesRuntime, @ViewBuilder content: @escaping () -> Content) {
        self.runtime = runtime
        self.content = content
    }

    public var body: some View {
        if !runtime.isCurrent {
            ContentUnavailableView(
                "Profile access changed", systemImage: "lock",
                description: Text("Reopen Sources to continue.")
            )
        } else if runtime.scanBinding.issue != nil {
            ContentUnavailableView {
                Label("Channel checks unavailable", systemImage: "checkmark.magnifyingglass")
            } description: {
                Text("Your channel preferences are unchanged.")
            } actions: {
                Button("Retry", systemImage: "arrow.clockwise", action: runtime.scanBinding.retry)
                    .plozzActionButton(role: .secondary)
            }
        } else {
            content()
        }
    }
}
#endif
