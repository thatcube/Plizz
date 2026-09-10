import XCTest
import CoreModels
@testable import ProviderJellyfin

final class JellyfinBrowsePerformanceTests: XCTestCase {
    private func provider(_ stub: StubHTTPClient, kind: ProviderKind) -> JellyfinProvider {
        JellyfinProvider(
            session: UserSession(
                server: MediaServer(
                    id: "server", name: "Server",
                    baseURL: URL(string: "https://media.example.test")!, provider: kind
                ),
                userID: "user", userName: "User", deviceID: "device", accessToken: "fixture"
            ),
            http: stub
        )
    }

    private func resumeFixture() -> StubHTTPClient {
        let stub = StubHTTPClient()
        let episodes = (0..<251).map { index in
            """
            {"Id":"episode-\(index)","Type":"Episode","SeriesId":"series-\(index)",
             "UserData":{"PlaybackPositionTicks":1200000000,"LastPlayedDate":"2026-09-01T00:00:00Z"}}
            """
        }
        stub.stub(
            pathSuffix: "/Items/Resume",
            requiring: [URLQueryItem(name: "ParentId", value: "series-250")],
            json: #"{"Items":[\#(episodes[250])],"TotalRecordCount":1}"#
        )
        for start in stride(from: 0, to: episodes.count, by: 100) {
            let page = episodes[start..<min(start + 100, episodes.count)].joined(separator: ",")
            stub.stub(
                pathSuffix: "/Items/Resume",
                requiring: [URLQueryItem(name: "StartIndex", value: String(start))],
                json: #"{"Items":[\#(page)],"TotalRecordCount":251}"#
            )
        }
        stub.stub(pathSuffix: "/Shows/NextUp", json: #"{"Items":[],"TotalRecordCount":0}"#)
        return stub
    }

    func testScopedResumeMatchesTheGlobalFeedWithoutReadingUnrelatedPages() async throws {
        for kind in [ProviderKind.emby, .jellyfin] {
            let stub = resumeFixture()
            let feed = try await provider(stub, kind: kind).continueWatching(limit: .max)
            let episode = try XCTUnwrap(feed.first { $0.seriesID == "series-250" })
            XCTAssertEqual(episode.id, "episode-250")
            XCTAssertEqual(episode.resumePosition, 120)
            XCTAssertEqual(stub.sentPaths.count, 4)
            print("Issue56 baseline \(kind): series resume = \(stub.sentPaths.count) requests, \(feed.count) decoded episodes")

            let scoped = try await provider(stub, kind: kind).resumeEpisode(inSeries: "series-250")
            XCTAssertEqual(scoped?.id, episode.id)
            XCTAssertEqual(scoped?.resumePosition, episode.resumePosition)
            XCTAssertEqual(stub.sentPaths.count - 4, 2)
            for query in stub.sentQueryItems.suffix(2) {
                XCTAssertEqual(query.first { $0.name == "ParentId" }?.value, "series-250")
                XCTAssertEqual(query.first { $0.name == "StartIndex" }?.value, "0")
            }
            let nextUp = try XCTUnwrap(stub.queryItems(forPathSuffix: "/Shows/NextUp"))
            XCTAssertEqual(nextUp.first { $0.name == "SeriesId" }?.value, "series-250")
            XCTAssertEqual(nextUp.first { $0.name == "UserId" }?.value, "user")
            XCTAssertEqual(nextUp.first { $0.name == "EnableResumable" }?.value, "false")
            XCTAssertEqual(nextUp.first { $0.name == "EnableRewatching" }?.value, "false")
            print("Issue56 optimized \(kind): series resume = 2 scoped requests, 1 episode in response")
        }
    }

    func testBatchHomeIdentityMatchesFullDetailsWithOneLightweightRequest() async throws {
        for kind in [ProviderKind.emby, .jellyfin] {
            let stub = StubHTTPClient()
            for index in 0..<20 {
                stub.stub(
                    pathSuffix: "/Items/series-\(index)",
                    json: #"{"Id":"series-\#(index)","Type":"Series","ProviderIds":{"Tvdb":"\#(index + 1)"}}"#
                )
            }
            let provider = provider(stub, kind: kind)
            var ids: [String: [String: String]] = [:]
            for index in 0..<20 {
                ids["series-\(index)"] = try await provider.item(id: "series-\(index)").providerIDs
            }
            XCTAssertEqual(ids.count, 20)
            XCTAssertEqual(stub.sentPaths.count, 20)
            XCTAssertTrue(stub.sentQueryItems.allSatisfy {
                $0.first { $0.name == "Fields" }?.value?.contains("MediaSources") == true
            })
            print("Issue56 baseline \(kind): 20 Home series identities = \(stub.sentPaths.count) full-detail requests")

            let series = (0..<20).map { index in
                #"{"Id":"series-\#(index)","Type":"Series","ProviderIds":{"Tvdb":"\#(index + 1)"}}"#
            }.joined(separator: ",")
            stub.stub(pathSuffix: "/Users/user/Items", json: #"{"Items":[\#(series)]}"#)
            let batch = try await provider.seriesProviderIDs(for: Array(ids.keys))
            XCTAssertEqual(batch, ids)
            XCTAssertEqual(stub.sentPaths.count - 20, 1)
            let query = try XCTUnwrap(stub.queryItems(forPathSuffix: "/Users/user/Items"))
            XCTAssertEqual(query.first { $0.name == "Fields" }?.value, "ProviderIds")
            XCTAssertEqual(query.first { $0.name == "EnableImages" }?.value, "false")
            XCTAssertEqual(query.first { $0.name == "EnableUserData" }?.value, "false")
            XCTAssertEqual(query.first { $0.name == "EnableTotalRecordCount" }?.value, "false")
            XCTAssertEqual(query.first { $0.name == "Limit" }?.value, "20")
            print("Issue56 optimized \(kind): 20 Home series identities = 1 lightweight request")
        }
    }

    func testScopedResumePreservesRecencyAndRejectsUnrelatedEpisodes() async throws {
        for kind in [ProviderKind.emby, .jellyfin] {
            let stub = StubHTTPClient()
            stub.stub(pathSuffix: "/Items/Resume", json: """
            {"Items":[
              {"Id":"unrelated","Type":"Episode","SeriesId":"other",
               "UserData":{"LastPlayedDate":"2026-09-10T00:00:00Z"}},
              {"Id":"resuming","Type":"Episode","SeriesId":"show",
               "UserData":{"PlaybackPositionTicks":1200000000,"LastPlayedDate":"2026-09-01T00:00:00Z"}}
            ],"TotalRecordCount":2}
            """)
            stub.stub(pathSuffix: "/Shows/NextUp", json: """
            {"Items":[{"Id":"next","Type":"Episode","SeriesId":"show",
              "ParentIndexNumber":4,"IndexNumber":3}],"TotalRecordCount":1}
            """)
            stub.stub(pathSuffix: "/Users/user/Items", json: """
            {"Items":[{"Id":"show","Type":"Series",
              "UserData":{"LastPlayedDate":"2026-09-09T00:00:00Z"}}]}
            """)
            let episode = try await provider(stub, kind: kind).resumeEpisode(inSeries: "show")
            XCTAssertEqual(episode?.id, "next")
            XCTAssertEqual(episode?.seasonNumber, 4)
            XCTAssertEqual(episode?.episodeNumber, 3)
            XCTAssertNotNil(episode?.lastPlayedAt)
            let recency = try XCTUnwrap(stub.queryItems(forPathSuffix: "/Users/user/Items"))
            XCTAssertEqual(recency.first { $0.name == "Ids" }?.value, "show")
            XCTAssertEqual(stub.sentPaths.count, 3)
        }
    }

    func testScopedResumeDrainsTheSelectedSeriesWithoutAnArbitraryCap() async throws {
        for kind in [ProviderKind.emby, .jellyfin] {
            let stub = StubHTTPClient()
            let older = (0..<100).map {
                #"{"Id":"e\#($0)","Type":"Episode","SeriesId":"show","UserData":{"LastPlayedDate":"2026-09-01T00:00:00Z"}}"#
            }.joined(separator: ",")
            stub.stubSequence(pathSuffix: "/Items/Resume", jsons: [
                #"{"Items":[\#(older)],"TotalRecordCount":101}"#,
                #"{"Items":[{"Id":"newest","Type":"Episode","SeriesId":"show","UserData":{"LastPlayedDate":"2026-09-09T00:00:00Z"}}],"TotalRecordCount":101}"#
            ])
            stub.stub(pathSuffix: "/Shows/NextUp", json: #"{"Items":[],"TotalRecordCount":0}"#)
            let episode = try await provider(stub, kind: kind).resumeEpisode(inSeries: "show")
            XCTAssertEqual(episode?.id, "newest")
            XCTAssertEqual(stub.sentPaths.count, 3)
            XCTAssertTrue(stub.sentQueryItems.allSatisfy {
                $0.first { $0.name == "ParentId" }?.value == "show"
            })
        }
    }

    func testScopedResumeRefreshesWatchStateInsteadOfReusingAnOldAnswer() async throws {
        let stub = StubHTTPClient()
        stub.stubSequence(pathSuffix: "/Items/Resume", jsons: [120, 240].map { seconds in
            """
            {"Items":[{"Id":"episode","Type":"Episode","SeriesId":"show",
            "UserData":{"PlaybackPositionTicks":\(seconds * 10_000_000),
            "LastPlayedDate":"2026-09-09T00:00:00Z"}}],"TotalRecordCount":1}
            """
        })
        stub.stub(pathSuffix: "/Shows/NextUp", json: #"{"Items":[],"TotalRecordCount":0}"#)
        let provider = provider(stub, kind: .emby)
        let first = try await provider.resumeEpisode(inSeries: "show")
        let second = try await provider.resumeEpisode(inSeries: "show")
        XCTAssertEqual(first?.resumePosition, 120)
        XCTAssertEqual(second?.resumePosition, 240)
        XCTAssertEqual(stub.sentPaths.count, 4)
    }

    func testScopedResumeKeepsTheSuccessfulEndpointAndThrowsWhenNeitherAnswers() async throws {
        for kind in [ProviderKind.emby, .jellyfin] {
            for workingPath in ["/Items/Resume", "/Shows/NextUp"] {
                let stub = StubHTTPClient()
                stub.stub(pathSuffix: workingPath, json: """
                {"Items":[{"Id":"episode","Type":"Episode","SeriesId":"show",
                  "UserData":{"LastPlayedDate":"2026-09-09T00:00:00Z"}}],"TotalRecordCount":1}
                """)
                let episode = try await provider(stub, kind: kind).resumeEpisode(inSeries: "show")
                XCTAssertEqual(episode?.id, "episode")
            }
            let stub = StubHTTPClient()
            do {
                _ = try await provider(stub, kind: kind).resumeEpisode(inSeries: "show")
                XCTFail("An outage is not an authoritative empty series")
            } catch let error as AppError {
                XCTAssertEqual(error, .notFound)
            }
        }
    }

    func testScopedResumeCancellationDoesNotFallBackToTheGlobalFeed() async throws {
        let stub = StubHTTPClient()
        stub.error = .cancelled
        do {
            _ = try await provider(stub, kind: .emby).resumeEpisode(inSeries: "show")
            XCTFail("Cancellation must propagate")
        } catch let error as AppError {
            XCTAssertEqual(error, .cancelled)
        }
        XCTAssertTrue(stub.sentQueryItems.allSatisfy {
            $0.first { $0.name == "ParentId" }?.value == "show"
        })
    }

    func testScopedResumeHasNoTargetWhenBothServerFeedsAreEmpty() async throws {
        for kind in [ProviderKind.emby, .jellyfin] {
            let stub = StubHTTPClient()
            stub.stub(pathSuffix: "/Items/Resume", json: #"{"Items":[],"TotalRecordCount":0}"#)
            stub.stub(pathSuffix: "/Shows/NextUp", json: #"{"Items":[],"TotalRecordCount":0}"#)
            let episode = try await provider(stub, kind: kind).resumeEpisode(inSeries: "show")
            XCTAssertNil(episode)
            XCTAssertEqual(stub.sentPaths.count, 2)
        }
    }

    func testScopedNextUpRecencyOnlyLooksInsideItsOwnShow() async throws {
        for kind in [ProviderKind.emby, .jellyfin] {
            let stub = StubHTTPClient()
            stub.stub(pathSuffix: "/Items/Resume", json: #"{"Items":[],"TotalRecordCount":0}"#)
            stub.stub(pathSuffix: "/Shows/NextUp", json: """
            {"Items":[{"Id":"next","Type":"Episode","SeriesId":"show"}],"TotalRecordCount":1}
            """)
            stub.stub(
                pathSuffix: "/Users/user/Items",
                requiring: [URLQueryItem(name: "Ids", value: "show")],
                json: #"{"Items":[{"Id":"show","Type":"Series"}]}"#
            )
            stub.stub(
                pathSuffix: "/Users/user/Items",
                requiring: [URLQueryItem(name: "ParentId", value: "show")],
                json: """
                {"Items":[{"Id":"finished","Type":"Episode","SeriesId":"show",
                  "UserData":{"LastPlayedDate":"2026-09-09T00:00:00Z"}}]}
                """
            )
            let episode = try await provider(stub, kind: kind).resumeEpisode(inSeries: "show")
            XCTAssertEqual(episode?.id, "next")
            XCTAssertNotNil(episode?.lastPlayedAt)
            XCTAssertEqual(stub.sentPaths.count, 4)
            XCTAssertTrue(stub.sentQueryItems.allSatisfy {
                $0.contains(URLQueryItem(name: "ParentId", value: "show"))
                    || $0.contains(URLQueryItem(name: "Ids", value: "show"))
            })
        }
    }

    func testBatchIdentityDeduplicatesBoundsAndScopesRequests() async throws {
        for kind in [ProviderKind.emby, .jellyfin] {
            let stub = StubHTTPClient()
            let ids = (0..<51).map { "show-\($0)" }.sorted()
            for start in stride(from: 0, to: ids.count, by: 50) {
                let batch = Array(ids[start..<min(start + 50, ids.count)])
                let records = batch.map {
                    #"{"Id":"\#($0)","Type":"Series","ProviderIds":{"Tvdb":"\#($0)"}}"#
                }.joined(separator: ",")
                stub.stub(
                    pathSuffix: "/Users/user/Items",
                    requiring: [URLQueryItem(name: "Ids", value: batch.joined(separator: ","))],
                    json: #"{"Items":[\#(records),{"Id":"unrequested","Type":"Series","ProviderIds":{"Tvdb":"wrong"}}]}"#
                )
            }
            let result = try await provider(stub, kind: kind).seriesProviderIDs(for: ids + ids + [""])
            XCTAssertEqual(Set(result.keys), Set(ids))
            XCTAssertEqual(stub.sentPaths.count, 2)
            XCTAssertEqual(stub.sentQueryItems.map {
                $0.first { $0.name == "Limit" }?.value
            }, ["50", "1"])
        }
    }

    func testBatchIdentityDoesNotMislabelEpisodeIDsOrRequestEmptyInput() async throws {
        let stub = StubHTTPClient()
        let provider = provider(stub, kind: .emby)
        let empty = try await provider.seriesProviderIDs(for: [""])
        XCTAssertTrue(empty.isEmpty)
        XCTAssertTrue(stub.sentPaths.isEmpty)
        stub.stub(pathSuffix: "/Users/user/Items", json: """
        {"Items":[
          {"Id":"show","Type":"Episode","ProviderIds":{"Tvdb":"episode-id"}},
          {"Id":"other","Type":"Series","ProviderIds":{"Tvdb":"unrelated"}}
        ]}
        """)
        let mismatched = try await provider.seriesProviderIDs(for: ["show"])
        XCTAssertTrue(mismatched.isEmpty)
    }
}
