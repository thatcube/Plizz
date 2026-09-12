import CoreModels
import CoreNetworking
import Foundation
import XCTest
@testable import ProviderPlex

final class PlexLibraryChannelTests: XCTestCase {
    private let metadata = """
    {"ratingKey":"42","type":"episode","title":"Pilot","duration":60000,"viewOffset":59000,
     "grandparentRatingKey":"show","parentIndex":1,"index":1,"librarySectionID":1,
     "Media":[{"id":1,"container":"mkv","Part":[{"id":2,"key":"/library/parts/2/file.mkv","container":"mkv"}]}]}
    """
    private func provider(_ http: LibraryChannelHTTP) -> PlexProvider {
        PlexProvider(session: UserSession(
            server: MediaServer(id: "server", name: "Server", baseURL: URL(string: "https://server.invalid")!, provider: .plex),
            userID: "user", userName: "User", deviceID: "device", accessToken: "private-fixture-token"
        ), accountID: "account", http: http, interactiveHTTP: http, probe: http)
    }

    func testOriginalFileResolutionNeverSendsTimelineOrResumesLibraryPosition() async throws {
        let http = LibraryChannelHTTP([
            "/library/metadata/42": "{\"MediaContainer\":{\"Metadata\":[\(metadata)]}}"
        ])
        let item = try LibraryChannelItem(
            item: MediaItem(id: "42", title: "Pilot", kind: .episode, runtime: 60),
            library: LibraryChannelLibrary(accountID: "account", libraryID: "1"), serverID: "server", userID: "user"
        )
        let request = try await provider(http).libraryChannelPlayback(for: item)
        XCTAssertEqual(request.startPosition, 0)
        XCTAssertNil(request.playSessionID)
        XCTAssertTrue(request.suppressOrdinaryWatchReporting)
        XCTAssertNil(request.localRemuxSource)
        guard case .authenticatedHTTP(let locator) = request.playbackSource else { return XCTFail("Original bytes") }
        XCTAssertEqual(locator.deliveryMode, .directFile)
        let requests = await http.requests
        XCTAssertEqual(Set(requests.map(\.path)), ["/library/metadata/42"])
        XCTAssertTrue(requests.allSatisfy { $0.method == .get })
    }

    func testEpisodeCatalogUsesTypeFourPaginatedSectionQuery() async throws {
        let http = LibraryChannelHTTP([
            "/library/sections/1/all": "{\"MediaContainer\":{\"size\":1,\"totalSize\":1,\"Metadata\":[\(metadata)]}}"
        ])
        let result = try await provider(http).libraryChannelItems(
            in: "1", kind: .episode, page: PageRequest(startIndex: 0, limit: 250)
        )
        XCTAssertEqual(result.items.first?.kind, .episode)
        let requests = await http.requests
        let query = Dictionary(requests[0].queryItems.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(query["type"], "4")
        XCTAssertEqual(query["X-Plex-Container-Size"], "250")
        XCTAssertEqual(Set(requests.map(\.path)), ["/library/sections/1/all"])
    }

    func testMissingTotalCannotPublishOnlyTheFirstPageAsACompleteLibrary() async throws {
        let http = LibraryChannelHTTP([
            "/library/sections/1/all": "{\"MediaContainer\":{\"size\":1,\"Metadata\":[\(metadata)]}}"
        ])
        do {
            _ = try await provider(http).libraryChannelItems(in: "1", kind: .episode, page: PageRequest(limit: 250))
            XCTFail("Page size is not the library total")
        } catch { XCTAssertEqual(error as? LibraryChannelError, .invalidSnapshot) }
    }
}

private actor LibraryChannelHTTP: HTTPClient {
    let responses: [String: String]
    private(set) var requests: [Endpoint] = []
    init(_ responses: [String: String]) { self.responses = responses }
    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        requests.append(endpoint)
        guard let json = responses[endpoint.path] else { throw AppError.notFound }
        return (Data(json.utf8), HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
    }
}
