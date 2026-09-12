#if DEBUG && os(iOS)
import CoreUI
import FeatureLiveTVCore
import SwiftUI

struct PrototypeSearchHeader: View {
    @Binding var query: String
    let channelCount: Int
    let category: String?
    let focusRequest: Int
    let browse: () -> Void
    let close: () -> Void
    let focusChanged: (Bool) -> Void
    @FocusState private var focused: Control?
    @Environment(\.themePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private enum Control: Hashable { case query, clear }

    var body: some View {
        VStack(alignment: .leading, spacing: PrototypeLayout.gap) {
            HStack(spacing: PrototypeLayout.gap) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(palette.secondaryText)
                    .accessibilityHidden(true)
                TextField("Search channels", text: $query)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                    .focused($focused, equals: .query)
                    .accessibilityIdentifier("live-tv-search-field")
                    .onSubmit {
                        focused = nil
                        browse()
                    }
                if !query.isEmpty {
                    Button {
                        query = ""
                        focused = .query
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .accessibilityLabel("Clear search")
                    .buttonStyle(PrototypeButtonStyle(surface: .control))
                    .focused($focused, equals: .clear)
                }
            }
            .font(.title2.weight(.semibold))
            .padding(PrototypeLayout.gap)
            .background { PrototypeControlSurface() }

            PrototypeSearchSummary(channelCount: channelCount, category: category)
        }
        .task(id: focusRequest) {
            if !reduceMotion { try? await Task.sleep(for: .milliseconds(340)) }
            guard !Task.isCancelled else { return }
            focused = .query
        }
        .onChange(of: focused) { _, value in focusChanged(value != nil) }
        #if os(tvOS)
        .onMoveCommand { direction in
            if direction == .down, focused != nil {
                focused = nil
                browse()
            }
        }
        .onExitCommand(perform: close)
        #endif
    }
}
#endif

#if DEBUG
import SwiftUI

private struct PrototypeSearchResultsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var prototypeSearchResults: Bool {
        get { self[PrototypeSearchResultsKey.self] }
        set { self[PrototypeSearchResultsKey.self] = newValue }
    }
}

struct PrototypeSearchResults<Content: View>: View {
    let content: Content
    var body: some View { content.environment(\.prototypeSearchResults, true) }
}

struct PrototypeSearchFocusBoundary<Content: View>: View {
    @Environment(\.prototypeSearchResults) private var isSearchResult
    @ViewBuilder let content: () -> Content

    var body: some View {
        #if os(tvOS)
        if isSearchResult {
            PrototypeSearchRowHost(content: content())
        } else {
            content()
        }
        #else
        content()
        #endif
    }
}

#if os(tvOS)
import UIKit

/// Give native Search a row-sized focused UIView, not the entire lazy stack.
/// Its keyboard-collapse scrolling still runs unchanged using this real boundary.
struct PrototypeSearchRowHost<Content: View>: UIViewControllerRepresentable {
    let content: Content

    struct HostedContent: View {
        let content: Content
        let environment: EnvironmentValues
        var body: some View { content.environment(\.self, environment) }
    }

    func makeUIViewController(context: Context) -> UIHostingController<HostedContent> {
        let controller = UIHostingController(rootView: HostedContent(content: content, environment: context.environment))
        controller.view.backgroundColor = .clear
        controller.safeAreaRegions = []
        return controller
    }

    func updateUIViewController(_ controller: UIHostingController<HostedContent>, context: Context) {
        controller.rootView = HostedContent(content: content, environment: context.environment)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, uiViewController: UIHostingController<HostedContent>, context: Context
    ) -> CGSize? {
        guard let width = proposal.width else { return nil }
        return uiViewController.sizeThatFits(in: CGSize(width: width, height: UIView.layoutFittingExpandedSize.height))
    }
}
#endif
#endif
