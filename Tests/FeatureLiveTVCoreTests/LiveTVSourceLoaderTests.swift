#if DEBUG
import Foundation
import XCTest
@testable import FeatureLiveTVCore

final class LiveTVSourceLoaderTests: XCTestCase {
    func testNotModifiedResponseCanRevokeStorageAndRefreshFreshness() async throws {
        let noStore = fixtureURL()
        let fresh = fixtureURL()
        LoaderProtocol.state.register(noStore, [
            .init(status: 200, headers: ["ETag": "\"old\"", "Cache-Control": "max-age=0"], body: playlist),
            .init(status: 304, headers: ["Cache-Control": "no-store"]),
            .init(status: 200, body: playlist)
        ])
        LoaderProtocol.state.register(fresh, [
            .init(status: 200, headers: ["ETag": "\"old\"", "Cache-Control": "max-age=0"], body: playlist),
            .init(status: 304, headers: ["Cache-Control": "max-age=60"])
        ])
        defer { LoaderProtocol.state.remove(noStore); LoaderProtocol.state.remove(fresh) }
        let loader = loader()
        _ = try await loader.loadPlaylist(from: noStore)
        let revoked = try await loader.loadPlaylist(from: noStore)
        _ = try await loader.loadPlaylist(from: noStore)
        XCTAssertFalse(revoked.permitsPersistence)
        XCTAssertNil(LoaderProtocol.state.requests(noStore).last?.value(forHTTPHeaderField: "If-None-Match"))
        _ = try await loader.loadPlaylist(from: fresh)
        _ = try await loader.loadPlaylist(from: fresh)
        _ = try await loader.loadPlaylist(from: fresh)
        XCTAssertEqual(LoaderProtocol.state.requests(fresh).count, 2)
    }

    func testPastServerDateIsNotFreshAndLongHTTPDateRetryAfterDoesNotRetryEarly() async throws {
        let old = fixtureURL()
        let limited = fixtureURL()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        LoaderProtocol.state.register(old, [
            .init(status: 200, headers: ["Date": "Thu, 01 Jan 1970 00:00:00 GMT", "Cache-Control": "max-age=60"], body: playlist),
            .init(status: 200, body: playlist)
        ])
        LoaderProtocol.state.register(limited, [
            .init(status: 429, headers: ["Retry-After": formatter.string(from: Date().addingTimeInterval(3_600))])
        ])
        defer { LoaderProtocol.state.remove(old); LoaderProtocol.state.remove(limited) }
        let loader = loader()
        _ = try await loader.loadPlaylist(from: old)
        _ = try await loader.loadPlaylist(from: old)
        XCTAssertEqual(LoaderProtocol.state.requests(old).count, 2)
        do {
            _ = try await loader.loadPlaylist(from: limited)
            XCTFail("The client must surface throttling instead of retrying before the server's deadline.")
        } catch {
            XCTAssertEqual(error as? LiveTVSourceImportError, .tooManyRequests)
        }
        XCTAssertEqual(LoaderProtocol.state.requests(limited).count, 1)
    }

    func testConditionalRequestReusesAnUnchangedPlaylist() async throws {
        let url = fixtureURL()
        LoaderProtocol.state.register(url, [
            .init(status: 200, headers: ["ETag": "\"generation-one\"", "Cache-Control": "max-age=0"], body: playlist),
            .init(status: 304)
        ])
        defer { LoaderProtocol.state.remove(url) }
        let loader = loader()
        let first = try await loader.loadPlaylist(from: url)
        let second = try await loader.loadPlaylist(from: url)
        XCTAssertEqual(first.channels, second.channels)
        let requests = LoaderProtocol.state.requests(url)
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "If-None-Match"), "\"generation-one\"")
    }

    func testNoStoreDoesNotPersistOrRevalidateTheResponse() async throws {
        let url = fixtureURL()
        LoaderProtocol.state.register(url, [
            .init(status: 200, headers: ["ETag": "\"secret\"", "Cache-Control": "no-store"], body: playlist),
            .init(status: 200, body: playlist)
        ])
        defer { LoaderProtocol.state.remove(url) }
        let loader = loader()
        let first = try await loader.loadPlaylist(from: url)
        _ = try await loader.loadPlaylist(from: url)
        XCTAssertFalse(first.permitsPersistence)
        XCTAssertNil(LoaderProtocol.state.requests(url).last?.value(forHTTPHeaderField: "If-None-Match"))
    }

    func testProviderFreshnessAvoidsUnnecessaryDownload() async throws {
        let url = fixtureURL()
        LoaderProtocol.state.register(url, [.init(status: 200, headers: ["Cache-Control": "max-age=60"], body: playlist)])
        defer { LoaderProtocol.state.remove(url) }
        let loader = loader()
        _ = try await loader.loadPlaylist(from: url)
        _ = try await loader.loadPlaylist(from: url)
        XCTAssertEqual(LoaderProtocol.state.requests(url).count, 1)
    }

    func testTemporaryServerFailureRetriesButForbiddenDoesNot() async throws {
        let transient = fixtureURL()
        let forbidden = fixtureURL()
        LoaderProtocol.state.register(transient, [.init(status: 503), .init(status: 200, body: playlist)])
        LoaderProtocol.state.register(forbidden, [.init(status: 403)])
        defer { LoaderProtocol.state.remove(transient); LoaderProtocol.state.remove(forbidden) }
        let loader = loader()
        let imported = try await loader.loadPlaylist(from: transient)
        XCTAssertEqual(imported.channels.count, 1)
        do {
            _ = try await loader.loadPlaylist(from: forbidden)
            XCTFail("Forbidden source must fail without anonymous fallback.")
        } catch {
            XCTAssertEqual(error as? LiveTVSourceImportError, .authenticationRequired)
        }
        XCTAssertEqual(LoaderProtocol.state.requests(transient).count, 2)
        XCTAssertEqual(LoaderProtocol.state.requests(forbidden).count, 1)
    }

    func testDirectHLSContentImportsOneChannelAndNotItsRenditions() async throws {
        let url = fixtureURL()
        LoaderProtocol.state.register(url, [.init(status: 200, body: Data("""
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=1000000
        low/index.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=4000000
        high/index.m3u8
        """.utf8))])
        defer { LoaderProtocol.state.remove(url) }
        let result = try await loader().loadPlaylist(from: url)
        XCTAssertEqual(result.channels.count, 1)
        XCTAssertEqual(result.channels.first?.streamURL, url)
    }

    private func loader() -> LiveTVSourceLoader {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LoaderProtocol.self]
        return LiveTVSourceLoader(configuration: configuration)
    }

    private func fixtureURL() -> URL {
        URL(string: "https://example.test/" + UUID().uuidString + "/catalog.m3u")!
    }

    private var playlist: Data {
        Data("#EXTM3U\n#EXTINF:-1 tvg-id=\"test\",Test channel\nhttps://example.test/live.m3u8\n".utf8)
    }
}

private struct LoaderResponse: Sendable {
    let status: Int
    var headers: [String: String] = [:]
    var body = Data()
}

private final class LoaderProtocol: URLProtocol {
    static let state = State()

    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var responses: [URL: [LoaderResponse]] = [:]
        private var received: [URL: [URLRequest]] = [:]

        func register(_ url: URL, _ plan: [LoaderResponse]) {
            lock.lock()
            defer { lock.unlock() }
            responses[url] = plan
            received[url] = []
        }
        func remove(_ url: URL) {
            lock.lock()
            defer { lock.unlock() }
            responses[url] = nil
            received[url] = nil
        }
        func next(_ request: URLRequest) -> LoaderResponse? {
            lock.lock()
            defer { lock.unlock() }
            guard let url = request.url, var plan = responses[url], !plan.isEmpty else { return nil }
            received[url, default: []].append(request)
            let result = plan.removeFirst()
            responses[url] = plan
            return result
        }
        func requests(_ url: URL) -> [URLRequest] {
            lock.lock()
            defer { lock.unlock() }
            return received[url] ?? []
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let next = Self.state.next(request),
              let response = HTTPURLResponse(url: url, statusCode: next.status, httpVersion: "HTTP/1.1", headerFields: next.headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: next.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
#endif
