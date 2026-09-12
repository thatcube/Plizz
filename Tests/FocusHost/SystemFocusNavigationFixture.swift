import CoreModels
import CoreUI
import SwiftUI
import UIKit

struct SystemFocusNavigationFixture: View {
    @Namespace private var scope
    @FocusState private var heroFocused: Bool
    @State private var rows: [[MediaItem]] = []
    @State private var receded = false
    @State private var selection = ""

    private var style: CardStyle {
        ProcessInfo.processInfo.arguments.contains("--borderless") ? .borderless : .framed
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 40) {
                        Button("Hero navigation") {}
                            .accessibilityIdentifier("navigation-hero")
                            .focused($heroFocused)
                            .prefersDefaultFocus(true, in: scope)
                        Button("Hero more info") {}
                    }
                    .frame(maxWidth: .infinity, minHeight: 220, alignment: .leading)
                    .padding(.horizontal, 80)
                    .offset(y: receded ? -40 : 0)
                    .id("hero")

                    LazyVStack(spacing: 60) {
                        ForEach(rows.indices, id: \.self) { row in
                            MediaRowView(
                                title: Text(row == 0 ? "Continue Watching" : "Row \(row)"),
                                items: rows[row], style: .landscape,
                                playsOnSelect: row == 0
                            ) { selection = $0.title }
                        }
                    }
                    .padding(.bottom, 100)
                }
                .focusScope(scope)
            }
            .scrollClipDisabled()
            .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y > 120 } action: { _, value in
                withAnimation(.smooth(duration: 0.9)) { receded = value }
            }
            .onChange(of: heroFocused) { _, value in
                if value {
                    withAnimation(.smooth(duration: 0.9)) {
                        receded = false
                        proxy.scrollTo("hero", anchor: .top)
                    }
                }
            }
        }
        .environment(\.plozzCardFocusStyle, .system)
        .environment(\.plozzCardStyle, style)
        .overlay(alignment: .bottomTrailing) {
            Text(rows.isEmpty ? "Loading navigation fixture" : "Navigation fixture ready")
                .font(.caption2)
                .accessibilityIdentifier("navigation-fixture-status")
                .allowsHitTesting(false)
        }
        .task { await loadRows() }
    }

    @MainActor
    private func loadRows() async {
        guard rows.isEmpty else { return }
        let store = MetadataProviderSettingsStore()
        var settings = store.load()
        settings.preferOnlineArtwork = false
        store.save(settings)
        let url = URL(string: "https://navigation-fixture.example.test/artwork.png")!
        let image = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 180)).image {
            UIColor.systemBlue.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
        }
        let data = image.pngData()!
        guard let cache = ArtworkSession.shared.configuration.urlCache else {
            preconditionFailure("The navigation fixture requires its isolated artwork cache.")
        }
        for variant in ArtworkImageVariant.allCases {
            let requestURL = variant.requestURL(for: url)
            let response = HTTPURLResponse(
                url: requestURL, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"]
            )!
            cache.storeCachedResponse(
                CachedURLResponse(response: response, data: data), for: URLRequest(url: requestURL)
            )
            guard await ArtworkImageCache.shared.image(for: url, variant: variant) != nil else {
                preconditionFailure("The navigation fixture artwork did not decode.")
            }
        }
        rows = (0..<3).map { row in
            (0..<8).map { index in
                MediaItem(
                    id: "navigation-\(row)-\(index)", title: "Row \(row) Item \(index)",
                    kind: .movie, posterURL: url, backdropURL: url
                )
            }
        }
    }
}
