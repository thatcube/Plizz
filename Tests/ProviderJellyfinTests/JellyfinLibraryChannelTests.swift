import CoreModels
import CoreNetworking
import Foundation
import XCTest
@testable import ProviderJellyfin

final class JellyfinLibraryChannelTests: XCTestCase {
    private let json = """
    {"Id":"episode","Name":"Pilot","Type":"Episode","RunTimeTicks":600000000,
     "MediaSources":[{"Id":"source","Container":"mkv","RunTimeTicks":600000000,"SupportsDirectPlay":true}],
     "UserData":{"PlaybackPositionTicks":590000000,"Played":true}}
    """

    private func provider(kind: ProviderKind, http: LibraryChannelHTTP) -> JellyfinProvider {
        JellyfinProvider(session: UserSession(
            server: MediaServer(id: "server", name: "Server", baseURL: URL(string: "https://server.invalid")!, provider: kind),
            userID: "user", userName: "User", deviceID: "device", accessToken: "private-fixture-token"
        ), accountID: "account", http: http, interactiveHTTP: http)
    }

    private func scheduledItem() throws -> LibraryChannelItem {
        try LibraryChannelItem(
            item: MediaItem(id: "episode", title: "Pilot", kind: .episode, runtime: 60),
            library: LibraryChannelLibrary(accountID: "account", libraryID: "library"), serverID: "server", userID: "user"
        )
    }

    func testJellyfinAndEmbyResolveStatelessOriginalWithoutResumeOrLifecycleWrites() async throws {
        for kind in [ProviderKind.jellyfin, .emby] {
            let http = LibraryChannelHTTP(["/Users/user/Items/episode": json])
            let request = try await provider(kind: kind, http: http).libraryChannelPlayback(for: scheduledItem())
            XCTAssertEqual(request.startPosition, 0)
            XCTAssertNil(request.playSessionID)
            XCTAssertNil(request.item.resumePosition)
            XCTAssertTrue(request.suppressOrdinaryWatchReporting)
            XCTAssertFalse(request.isTranscoding)
            guard case .authenticatedHTTP(let locator) = request.playbackSource else { return XCTFail("Typed direct bytes") }
            XCTAssertEqual(locator.deliveryMode, .directFile)
            XCTAssertNil(locator.playSessionID)
            let requests = await http.requests
            XCTAssertEqual(requests.map(\.path), ["/Users/user/Items/episode"])
            XCTAssertTrue(requests.allSatisfy { $0.method == .get })
        }
    }

    func testTranscodeOnlyModeIsRejectedInsteadOfSilentlyOptingIntoHistory() async throws {
        let http = LibraryChannelHTTP([
            "/Users/user/Items/episode": json.replacingOccurrences(of: "\"SupportsDirectPlay\":true", with: "\"SupportsDirectPlay\":false")
        ])
        do {
            _ = try await provider(kind: .emby, http: http).libraryChannelPlayback(for: scheduledItem())
            XCTFail("Cannot safely promise Off")
        } catch { XCTAssertEqual(error as? LibraryChannelError, .incompatiblePlaybackMode) }
        let requests = await http.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testStaticDiscAndInfiniteSourcesCannotSilentlyStartATranscode() async throws {
        for fact in ["\"VideoType\":\"BluRay\"", "\"VideoType\":\"Dvd\"", "\"IsInfiniteStream\":true", "\"RequiresOpening\":true"] {
            let http = LibraryChannelHTTP([
                "/Users/user/Items/episode": json.replacingOccurrences(of: "\"Container\":\"mkv\"", with: "\"Container\":\"mkv\",\(fact)")
            ])
            do {
                _ = try await provider(kind: .jellyfin, http: http).libraryChannelPlayback(for: scheduledItem())
                XCTFail("A stateless source must remain stateless")
            } catch { XCTAssertEqual(error as? LibraryChannelError, .incompatiblePlaybackMode) }
        }
    }

    func testCatalogRecursivelyRequestsEpisodesAndMetadataInOnePage() async throws {
        let http = LibraryChannelHTTP([
            "/Users/user/Items": "{\"Items\":[\(json)],\"TotalRecordCount\":1}"
        ])
        let page = try await provider(kind: .jellyfin, http: http).libraryChannelItems(
            in: "library", kind: .episode, page: PageRequest(startIndex: 250, limit: 250)
        )
        XCTAssertEqual(page.items.first?.kind, .episode)
        XCTAssertEqual(page.items.first?.libraryID, "library")
        let requests = await http.requests
        let query = Dictionary(requests[0].queryItems.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(query["Recursive"], "true")
        XCTAssertEqual(query["IncludeItemTypes"], "Episode")
        XCTAssertEqual(query["StartIndex"], "250")
        XCTAssertTrue(query["Fields"]?.contains("Genres") == true)
        XCTAssertEqual(requests.count, 1)
    }
}

private actor LibraryChannelHTTP: HTTPClient {
    let responses: [String: String]
    private(set) var requests: [Endpoint] = []
    init(_ responses: [String: String]) { self.responses = responses }
    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        requests.append(endpoint)
        guard let json = responses[endpoint.path] else { throw AppError.notFound }
        return (Data(json.utf8), HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
