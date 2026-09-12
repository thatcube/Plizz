import Foundation
import XCTest
import AetherEngine
import CoreModels
@testable import EnginePlozzigen

final class PlozzigenLiveFailureTests: XCTestCase {
    func testHTTPRefusalsAreTypedWithoutInspectingLocalizedText() {
        let cases: [(Int, AppError)] = [
            (401, .unauthorized), (403, .unauthorized), (404, .notFound),
            (410, .notFound), (429, .rateLimited(retryAfter: nil)),
            (503, .rateLimited(retryAfter: nil)), (500, .invalidResponse)
        ]
        for (code, expected) in cases {
            let info = PlaybackErrorInfo(kind: .sourceRefused, message: "localized failure", underlyingCode: code)
            XCTAssertEqual(PlozzigenLiveFailure.appError(info), expected)
        }
    }

    func testNativeItemFailureDoesNotInventAnHTTPStatus() {
        let info = PlaybackErrorInfo(
            kind: .nativeItemFailed, message: "404 appears only in this untrusted message",
            underlyingDomain: "AVFoundationErrorDomain", underlyingCode: -11850
        )
        XCTAssertEqual(PlozzigenLiveFailure.appError(info), .invalidResponse)
        XCTAssertEqual(
            PlozzigenLiveFailure.diagnostic(info),
            "kind=nativeItemFailed domain=avfoundation code=-11850"
        )
    }

    func testNetworkRateLimitAndDecodeFailuresStayDistinct() {
        XCTAssertEqual(PlozzigenLiveFailure.appError(PlaybackErrorInfo(
            kind: .sourceOpenFailed, message: "", underlyingDomain: NSURLErrorDomain,
            underlyingCode: NSURLErrorNotConnectedToInternet
        )), .serverUnreachable)
        XCTAssertEqual(PlozzigenLiveFailure.appError(PlaybackErrorInfo(
            kind: .sourceRateLimited, message: ""
        )), .rateLimited(retryAfter: nil))
        XCTAssertEqual(PlozzigenLiveFailure.appError(PlaybackErrorInfo(
            kind: .softwarePipelineFailed, message: ""
        )), .decoding)
    }

    func testUnknownKindsAndDomainsCannotLeakLocatorsIntoDiagnosticFields() {
        let secret = "https://example.invalid/live?token=fixture-secret"
        let info = PlaybackErrorInfo(
            kind: PlaybackErrorKind(rawValue: secret), message: secret,
            underlyingDomain: secret, underlyingCode: 404
        )
        XCTAssertEqual(PlozzigenLiveFailure.diagnostic(info), "kind=unknown domain=other code=404")
        XCTAssertEqual(PlozzigenLiveFailure.appError(info), .unknown("live playback failed"))
        XCTAssertEqual(PlozzigenLiveFailure.appError(nil), .unknown("live playback failed"))
    }
}
