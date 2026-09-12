import Foundation
import XCTest
@testable import CoreNetworking

final class LiveTVTransportPolicyTests: XCTestCase {
    func testOrdinaryEndpointsKeepExistingRedirectBehavior() {
        let endpoint = Endpoint(path: "/library/sections")
        guard case .follow = endpoint.redirectPolicy else {
            return XCTFail("Redirect protection must be explicitly opted into")
        }
    }

    func testSameOriginDelegateAllowsPathsButRejectsCredentialOriginChanges() {
        let delegate = SameOriginHTTPRedirectDelegate(
            url: URL(string: "https://server.invalid/base/LiveStreams/Open")!
        )
        for value in [
            "https://server.invalid/base/redirected",
            "https://SERVER.invalid:443/other/path?cursor=1"
        ] {
            XCTAssertNotNil(delegate.allowedRequest(URLRequest(url: URL(string: value)!)))
        }
        for value in [
            "https://external.invalid/collect",
            "http://server.invalid/base",
            "https://server.invalid:8443/base",
            "https://user:credential@server.invalid/base",
            "file:///private/resource"
        ] {
            XCTAssertNil(delegate.allowedRequest(URLRequest(url: URL(string: value)!)))
        }
    }

    func testInvalidOpeningOriginFailsClosed() {
        let delegate = SameOriginHTTPRedirectDelegate(url: URL(string: "file:///invalid")!)
        XCTAssertNil(delegate.allowedRequest(URLRequest(url: URL(string: "https://server.invalid")!)))
    }

    func testLiveOwnershipAndOpenTokensAreRedactedCaseInsensitively() {
        let url = URL(string:
            "https://server.invalid/LiveStreams/Close?LiVeStReAmId=live-secret&PlaySessionID=play-secret&OpenToken=open-secret&channel=123"
        )!
        let redacted = PlozzLog.redact(url: url)
        XCTAssertFalse(redacted.contains("live-secret"))
        XCTAssertFalse(redacted.contains("play-secret"))
        XCTAssertFalse(redacted.contains("open-secret"))
        XCTAssertTrue(redacted.contains("channel=123"))
    }
}
