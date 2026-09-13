import CoreModels
@testable import CoreUI
import FeatureHomeCore
import Foundation
import MetadataKit
import XCTest

@MainActor
final class ArtworkLatencyDiagnosticsTests: XCTestCase {
    func testMeasureConfiguredProvidersForReportedTitle() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let snapshotPath = environment["PLOZZ_ARTWORK_SNAPSHOT"],
              let bundlePath = environment["PLOZZ_ARTWORK_CONFIG_BUNDLE"],
              let title = environment["PLOZZ_ARTWORK_TITLE"] else {
            throw XCTSkip("Opt-in live artwork diagnostic; requires an explicit snapshot, title, and configuration bundle.")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: snapshotPath))
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
        let item = try XCTUnwrap(
            (snapshot.content.continueWatching + snapshot.content.latest + snapshot.content.watchlist)
                .first { $0.title == title }
        )
        let bundle = try XCTUnwrap(Bundle(path: bundlePath))
        let providers: [(String, any ArtworkProvider)] = [
            ("TMDb", TMDbMetadataProvider(access: MetadataProviderConfig.resolved(bundle: bundle).tmdb)),
            ("TheTVDB", TVDBArtworkProvider(client: TVDBClient(config: .resolved(bundle: bundle))))
        ]
        let query = MetadataQuery(item).seriesScoped
        var measurements: [Measurement] = []
        for pass in 0..<2 {
            let results = await withTaskGroup(of: Measurement.self) { group in
                for (name, provider) in providers {
                    group.addTask {
                        let start = Date()
                        let urls = await provider.artworkURLs(.hero, for: query, limit: 4)
                        let resolved = Date()
                        let url = urls.dropFirst().first ?? urls.first
                        var imageLoaded = false
                        if let url {
                            imageLoaded = await ArtworkImageCache.shared.image(for: url, variant: .heroPreview) != nil
                        }
                        return Measurement(
                            provider: name, pass: pass, count: urls.count,
                            lookupSeconds: resolved.timeIntervalSince(start),
                            imageSeconds: Date().timeIntervalSince(resolved),
                            imageLoaded: imageLoaded
                        )
                    }
                }
                var results: [Measurement] = []
                for await result in group { results.append(result) }
                return results
            }
            measurements.append(contentsOf: results)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let attachment = XCTAttachment(
            data: try encoder.encode(measurements), uniformTypeIdentifier: "public.json"
        )
        attachment.name = "configured-artwork-provider-timings"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private struct Snapshot: Decodable {
        let content: HomeViewModel.Content
    }

    private struct Measurement: Codable, Sendable {
        let provider: String
        let pass: Int
        let count: Int
        let lookupSeconds: TimeInterval
        let imageSeconds: TimeInterval
        let imageLoaded: Bool
    }
}
