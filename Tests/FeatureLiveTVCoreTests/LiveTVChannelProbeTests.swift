import CoreModels
import Foundation
import XCTest
@testable import FeatureLiveTVCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@MainActor
final class LiveTVChannelProbeTests: XCTestCase {
    func testMasterPlaylistAloneIsNotReachabilityEvidence() async throws {
        let target = try scanTarget()
        let transport = ScanFixtureTransport(responses: [
            "/master.m3u8": [.ok("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=2000\nvariant.m3u8")],
            "/variant.m3u8": [.init(statusCode: 404)]
        ])
        let result = try await scanner(transport).probe(target)
        XCTAssertEqual(result.status, .uncertain)
        XCTAssertEqual(result.reason, .staleManifest)
        XCTAssertEqual(result.requests, 4)
    }

    func testMasterVariantAndBoundedSegmentEvidenceReachable() async throws {
        let transport = ScanFixtureTransport(responses: [
            "/master.m3u8": [.ok("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=2000\nvariant.m3u8")],
            "/variant.m3u8": [.ok("#EXTM3U\n#EXTINF:6,\nsegment.ts")],
            "/segment.ts": [.init(statusCode: 206, data: scanTransportStream)]
        ])
        let result = try await scanner(transport).probe(scanTarget())
        XCTAssertEqual(result.status, .reachable)
        XCTAssertEqual(result.requests, 3)
        let requests = await transport.requests
        XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "Range"), "bytes=0-4095")
    }

    func testStaleVariantFallsBackToAnotherVariantWithoutHiding() async throws {
        let transport = ScanFixtureTransport(responses: [
            "/master.m3u8": [.ok("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=100\nold.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=200\nnew.m3u8")],
            "/old.m3u8": [.init(statusCode: 404)],
            "/new.m3u8": [.ok("#EXTM3U\n#EXTINF:5,\nlive.ts")],
            "/live.ts": [.init(statusCode: 200, data: scanTransportStream)]
        ])
        let result = try await scanner(transport).probe(scanTarget())
        XCTAssertEqual(result.status, .reachable)
    }

    func testRepeatedRoot404And410AreUnavailableButSingleFailureIsNot() async throws {
        for code in [404, 410] {
            let missing = ScanFixtureTransport(responses: ["/master.m3u8": [.init(statusCode: code)]])
            let result = try await scanner(missing).probe(scanTarget())
            XCTAssertEqual(result.status, .unavailable)
            XCTAssertEqual(result.reason, .repeatedlyMissing)
            XCTAssertEqual(result.requests, 2)
        }
        let recovered = ScanFixtureTransport(responses: [
            "/master.m3u8": [.init(statusCode: 404), .init(statusCode: 200, data: scanTransportStream)]
        ])
        let recoveredResult = try await scanner(recovered).probe(scanTarget())
        XCTAssertEqual(recoveredResult.status, .reachable)
    }

    func testAuthGeoTimeoutOfflineServerAndCodecFailuresNeverHide() async throws {
        for code in [401, 403, 451, 429, 500, 503] {
            let transport = ScanFixtureTransport(responses: ["/master.m3u8": [.init(statusCode: code)]])
            let result = try await scanner(transport).probe(scanTarget())
            XCTAssertEqual(result.status, .uncertain, "\(code)")
            XCTAssertEqual(result.requests, 1)
        }
        for error in [LiveTVScanTransportError.timedOut, .networkUnavailable] {
            let transport = ScanFixtureTransport(responses: [:], failure: error)
            let result = try await scanner(transport).probe(scanTarget())
            XCTAssertEqual(result.status, .uncertain)
        }
        let html = ScanFixtureTransport(responses: ["/master.m3u8": [.ok("<html>Access restricted</html>")]])
        let result = try await scanner(html).probe(scanTarget())
        XCTAssertEqual(result.status, .uncertain)
    }

    func testExpiredSegmentsReloadManifestAndCanRecover() async throws {
        let transport = ScanFixtureTransport(responses: [
            "/master.m3u8": [.ok("#EXTM3U\n#EXTINF:5,\nexpired.ts"), .ok("#EXTM3U\n#EXTINF:5,\nnew.ts")],
            "/expired.ts": [.init(statusCode: 404)],
            "/new.ts": [.init(statusCode: 200, data: scanTransportStream)]
        ])
        let result = try await scanner(transport).probe(scanTarget())
        XCTAssertEqual(result.status, .reachable)
        XCTAssertEqual(result.requests, 4)
    }

    func testPersistentExpiredSegmentAndOldManifestRemainUncertain() async throws {
        let expired = ScanFixtureTransport(responses: [
            "/master.m3u8": [.ok("#EXTM3U\n#EXTINF:5,\nexpired.ts")],
            "/expired.ts": [.init(statusCode: 410)]
        ])
        let result = try await scanner(expired).probe(scanTarget())
        XCTAssertEqual(result.status, .uncertain)
        XCTAssertEqual(result.reason, .expiredSegment)
        let stale = ScanFixtureTransport(responses: [
            "/master.m3u8": [.ok("#EXTM3U\n#EXT-X-PROGRAM-DATE-TIME:2020-01-01T00:00:00Z\n#EXTINF:5,\nold.ts")]
        ])
        let staleResult = try await scanner(stale).probe(scanTarget())
        XCTAssertEqual(staleResult.reason, .staleManifest)
        let requests = await stale.requests
        XCTAssertEqual(requests.count, 2)
    }

    func testEncryptedMediaDoesNotFetchKeysOrClaimDecoderSupport() async throws {
        let transport = ScanFixtureTransport(responses: [
            "/master.m3u8": [.ok("#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"https://other.test/key\"\n#EXTINF:5,\nmedia.ts")]
        ])
        let result = try await scanner(transport).probe(scanTarget())
        XCTAssertEqual(result.status, .uncertain)
        XCTAssertEqual(result.reason, .encryptedMedia)
        XCTAssertEqual(result.requests, 1)
    }

    func testCredentialsStayAtOriginalOriginAndSignedMissingRootIsUncertain() async throws {
        let target = try scanTarget(headers: ["Authorization": "Bearer fixture-secret"])
        let transport = ScanFixtureTransport(responses: [
            "/master.m3u8": [.ok("#EXTM3U\n#EXTINF:5,\nmedia.ts")],
            "/media.ts": [.init(statusCode: 200, data: scanTransportStream)]
        ])
        _ = try await scanner(transport).probe(target)
        let requests = await transport.requests
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-secret" })
        let signed = try scanTarget(url: "https://fixture.test/master.m3u8?token=fixture-secret")
        let missing = ScanFixtureTransport(responses: ["/master.m3u8": [.init(statusCode: 404)]])
        let missingResult = try await scanner(missing).probe(signed)
        XCTAssertEqual(missingResult.status, .uncertain)
        XCTAssertFalse(String(describing: signed).contains("fixture-secret"))
    }

    func testCredentialBearingPathsCannotBeHiddenByMasked404Or410() async throws {
        let paths = [
            "/live/user-fixture/password-fixture/123.ts",
            "/movie/user-fixture/password-fixture/123.m3u8",
            "/series/user-fixture/password-fixture/123.m3u8",
            "/token/path-fixture/master.m3u8",
            "/hdnts=path-fixture/master.m3u8",
            "/st=100~exp=200~hmac=path-fixture/master.m3u8"
        ]
        for path in paths {
            for code in [404, 410] {
                let target = try scanTarget(url: "https://fixture.test\(path)")
                let transport = ScanFixtureTransport(responses: [path: [.init(statusCode: code)]])
                let result = try await scanner(transport).probe(target)
                XCTAssertEqual(result.status, .uncertain, path)
                XCTAssertEqual(result.reason, .authorizationRequired, path)
                XCTAssertEqual(result.requests, 1)
                XCTAssertFalse(String(describing: target).contains("password-fixture"))
                XCTAssertFalse(String(describing: target).contains("path-fixture"))
            }
        }
    }

    func testUnapprovedCrossOriginManifestAndRedirectAreNeverRequested() async throws {
        for response in [
            LiveTVScanHTTPResponse.ok("#EXTM3U\n#EXTINF:5,\nhttp://127.0.0.1/private.ts"),
            LiveTVScanHTTPResponse(statusCode: 302, location: "https://unapproved.test/private")
        ] {
            let transport = ScanFixtureTransport(responses: ["/master.m3u8": [response]])
            let result = try await scanner(transport).probe(scanTarget())
            XCTAssertEqual(result.reason, .unsafeOrigin)
            XCTAssertEqual(result.requests, 1)
        }
    }

    func testApprovedCDNDoesNotReceiveOriginalCredentials() async throws {
        let channel = scanChannel()
        let policy = try LiveTVScanOriginPolicy(
            streamURL: channel.streamURL!, headers: ["Cookie": "fixture=secret"],
            additionalAllowedOrigins: [try NetworkOrigin(scheme: "https", host: "cdn.test")]
        )
        let target = try LiveTVChannelScanTarget(channel: channel, policy: policy)
        let transport = ScanFixtureTransport(responses: [
            "/master.m3u8": [.init(statusCode: 302, location: "https://cdn.test/media.ts")],
            "/media.ts": [.init(statusCode: 200, data: scanTransportStream)]
        ])
        let result = try await scanner(transport).probe(target)
        XCTAssertEqual(result.status, .reachable)
        let requests = await transport.requests
        XCTAssertNil(requests.last?.value(forHTTPHeaderField: "Cookie"))
    }

    func testHTTPAndUnsafeHeaderRequireExplicitPolicy() throws {
        XCTAssertThrowsError(try LiveTVScanOriginPolicy(streamURL: URL(string: "http://fixture.test/live")!))
        XCTAssertNoThrow(try LiveTVScanOriginPolicy(streamURL: URL(string: "http://fixture.test/live")!, allowsHTTP: true))
        XCTAssertThrowsError(try LiveTVScanOriginPolicy(streamURL: URL(string: "https://fixture.test/live")!, headers: ["Host": "other.test"]))
        XCTAssertThrowsError(try LiveTVScanOriginPolicy(streamURL: URL(string: "https://fixture.test/live")!, headers: ["Cookie": "bad\r\nheader"]))
        for address in ["https://127.0.0.1/live", "https://192.168.1.10/live", "https://[::1]/live", "https://device.local/live"] {
            XCTAssertThrowsError(try LiveTVScanOriginPolicy(streamURL: URL(string: address)!))
            XCTAssertNoThrow(try LiveTVScanOriginPolicy(streamURL: URL(string: address)!, allowsLocalNetwork: true))
        }
    }

    func testPerChannelDeadlineCancelsSlowInjectedTransport() async throws {
        let transport = SlowScanFixtureTransport()
        let probe = LiveTVChannelProbe(
            transport: transport, limits: .init(channelTimeout: 0.1, retryDelay: .zero)
        )
        let result = try await probe.probe(scanTarget())
        XCTAssertEqual(result.status, .uncertain)
        XCTAssertEqual(result.reason, .timedOut)
        let cancelled = await transport.cancelled
        XCTAssertTrue(cancelled)
    }

    func testResponseAndRequestBudgetsBoundMalformedAndLoopingManifests() async throws {
        let tooLarge = ScanFixtureTransport(responses: [
            "/master.m3u8": [.init(statusCode: 200, data: Data(repeating: 65, count: 256 * 1_024 + 1))]
        ])
        let oversized = try await scanner(tooLarge).probe(scanTarget())
        XCTAssertEqual(oversized.reason, .responseLimit)
        let looping = ScanFixtureTransport(responses: [
            "/master.m3u8": [.ok("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=2\nmaster.m3u8")]
        ])
        let result = try await scanner(looping).probe(scanTarget())
        XCTAssertEqual(result.reason, .requestLimit)
        XCTAssertLessThanOrEqual(result.requests, 3)
        let bounded = LiveTVChannelProbe(transport: looping, limits: .init(requestsPerChannel: 2, retryDelay: .zero))
        let boundedResult = try await bounded.probe(scanTarget())
        XCTAssertLessThanOrEqual(boundedResult.requests, 2)
    }

    func testOnlyConfiguredIPTVIsEligibleAndCancellationPropagates() async throws {
        for source in [LiveTVPrototypeSource.jellyfin, .plex, .emby, .plozz] {
            let channel = scanChannel(source: source)
            XCTAssertThrowsError(try LiveTVChannelScanTarget(
                channel: channel, policy: LiveTVScanOriginPolicy(streamURL: channel.streamURL!)
            ))
        }
        let transport = ScanFixtureTransport(responses: [:], cancel: true)
        do {
            _ = try await scanner(transport).probe(scanTarget())
            XCTFail("Cancellation must not produce a health record")
        } catch is CancellationError {} catch { XCTFail("Unexpected cancellation mapping") }
    }

    private func scanner(_ transport: ScanFixtureTransport) -> LiveTVChannelProbe {
        LiveTVChannelProbe(
            transport: transport, limits: .init(retryDelay: .zero),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
    }
}

private actor SlowScanFixtureTransport: LiveTVScanHTTPTransport {
    private(set) var cancelled = false

    func fetch(_ request: URLRequest, maximumBytes: Int, acceptsPrefix: Bool) async throws -> LiveTVScanHTTPResponse {
        do {
            try await Task.sleep(for: .seconds(5))
            return .init(statusCode: 200, data: scanTransportStream)
        } catch {
            cancelled = true
            throw error
        }
    }
}

func scanChannel(
    id: String = "channel", sourceID: String = "source",
    source: LiveTVPrototypeSource = .iptv,
    url: String = "https://fixture.test/master.m3u8", headers: [String: String] = [:]
) -> LiveTVPrototypeChannel {
    LiveTVPrototypeChannel(
        id: id, number: 1, name: id, category: "Test", symbol: "tv", accent: 0, source: source,
        tagline: "", streamURL: URL(string: url)!, httpHeaders: headers, playlistSourceID: sourceID
    )
}

func scanTarget(
    id: String = "channel", sourceID: String = "source",
    url: String = "https://fixture.test/master.m3u8", headers: [String: String] = [:]
) throws -> LiveTVChannelScanTarget {
    let channel = scanChannel(id: id, sourceID: sourceID, url: url, headers: headers)
    return try LiveTVChannelScanTarget(
        channel: channel, policy: LiveTVScanOriginPolicy(streamURL: channel.streamURL!, headers: headers)
    )
}

var scanTransportStream: Data {
    var data = Data(repeating: 0, count: 564)
    for index in [0, 188, 376] { data[index] = 0x47 }
    return data
}

extension LiveTVScanHTTPResponse {
    static func ok(_ text: String) -> Self { .init(statusCode: 200, data: Data(text.utf8)) }
}

actor ScanFixtureTransport: LiveTVScanHTTPTransport {
    private var responses: [String: [LiveTVScanHTTPResponse]]
    private let failure: LiveTVScanTransportError?
    private let cancel: Bool
    private(set) var requests: [URLRequest] = []

    init(responses: [String: [LiveTVScanHTTPResponse]], failure: LiveTVScanTransportError? = nil, cancel: Bool = false) {
        self.responses = responses
        self.failure = failure
        self.cancel = cancel
    }

    func fetch(_ request: URLRequest, maximumBytes: Int, acceptsPrefix: Bool) async throws -> LiveTVScanHTTPResponse {
        requests.append(request)
        if cancel { throw CancellationError() }
        if let failure { throw failure }
        let path = request.url!.path
        guard var values = responses[path], !values.isEmpty else {
            throw LiveTVScanTransportError.invalidResponse
        }
        let value = values[0]
        if values.count > 1 { values.removeFirst() }
        responses[path] = values
        return value
    }
}
