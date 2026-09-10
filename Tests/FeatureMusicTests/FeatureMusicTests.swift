import XCTest
import CoreModels
import CoreUI
import AVFoundation
import MediaPlayer
@testable import FeatureMusic

@MainActor
final class MusicNowPlayingOwnershipTests: XCTestCase {
    func testVideoTakeoverCancelsPendingMusicAndExplicitResumeReclaimsIt() async {
        let publisher = MusicPublisherSpy()
        let controller = AudioPlaybackController(nowPlayingPublisher: publisher)
        let began = expectation(description: "Music resolution began")
        let gate = MusicResolveGate()
        controller.play(tracks: [MusicTrack(id: "track", title: "Track")], startIndex: 0,
                        resolveStreamURL: { _ in
            began.fulfill()
            await gate.wait()
            return nil
        })
        await fulfillment(of: [began], timeout: 1)
        publisher.resign()
        await gate.release()
        await Task.yield()

        XCTAssertFalse(controller.isPlaying)
        XCTAssertFalse(publisher.isActive)
        XCTAssertEqual(publisher.activations, 1)
        XCTAssertEqual(controller.currentTrack?.id, "track", "Takeover preserves the queue")

        // A new explicit queue request may reclaim transport; asynchronous
        // completion of the old request must never do so.
        controller.play(tracks: [MusicTrack(id: "other", title: "Other")], startIndex: 0,
                        resolveStreamURL: { _ in nil })
        XCTAssertTrue(publisher.isActive)
        XCTAssertEqual(publisher.activations, 2)
        controller.stop()
        XCTAssertFalse(publisher.isActive)
    }
}

private actor MusicResolveGate {
    var continuation: CheckedContinuation<Void, Never>?
    var released = false
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class MusicPublisherSpy: NowPlayingPublishing {
    var isActive = false
    var activations = 0
    var resigned: (@MainActor () -> Void)?
    func bind(player: AVPlayer?) {}
    func activate(onCommand: @escaping @MainActor (NowPlayingCommand) -> Void,
                  onResigned: @escaping @MainActor () -> Void) {
        isActive = true
        activations += 1
        resigned = onResigned
    }
    func publish(_ info: [String: Any], state: MPNowPlayingPlaybackState,
                 transport: NowPlayingTransport) {}
    func invalidate() { isActive = false }
    func resign() {
        isActive = false
        resigned?()
    }
}

final class MusicFormatTests: XCTestCase {
    func testDurationUnderAnHour() {
        XCTAssertEqual(MusicFormat.duration(187), "3:07")
        XCTAssertEqual(MusicFormat.duration(0), "0:00")
        XCTAssertEqual(MusicFormat.duration(59), "0:59")
    }

    func testDurationOverAnHour() {
        XCTAssertEqual(MusicFormat.duration(3753), "1:02:33")
    }

    func testDurationHandlesNilAndInvalid() {
        XCTAssertEqual(MusicFormat.duration(nil), "--:--")
        XCTAssertEqual(MusicFormat.duration(-5), "--:--")
        XCTAssertEqual(MusicFormat.duration(.infinity), "--:--")
    }
}

final class MusicPagePagingTests: XCTestCase {
    func testCountAndHasMore() {
        let page = MusicPage(
            albums: [MusicAlbum(id: "a", title: "A"), MusicAlbum(id: "b", title: "B")],
            startIndex: 0,
            totalCount: 10
        )
        XCTAssertEqual(page.count, 2)
        XCTAssertEqual(page.endIndex, 2)
        XCTAssertTrue(page.hasMore)
    }

    func testNoMoreWhenExhausted() {
        let page = MusicPage(
            tracks: [MusicTrack(id: "t", title: "T")],
            startIndex: 9,
            totalCount: 10
        )
        XCTAssertFalse(page.hasMore)
    }
}

final class MusicTrackSubtitleTests: XCTestCase {
    func testSubtitleCombinesArtistAndAlbum() {
        let track = MusicTrack(id: "t", title: "Song", albumTitle: "LP", artistName: "Artist")
        XCTAssertEqual(track.subtitle, "Artist · LP")
    }

    func testSubtitleFallsBackToWhateverIsPresent() {
        XCTAssertEqual(MusicTrack(id: "t", title: "S", artistName: "Only Artist").subtitle, "Only Artist")
        XCTAssertNil(MusicTrack(id: "t", title: "S").subtitle)
    }
}

/// Authority matrix for caching a *negative* (no synced lyrics) resolve. These
/// guard the v2→v5 cache-poisoning regression history — particularly H1a, where
/// a background prefetch (title-only fallback disabled) that finds nothing for a
/// track filed under a different artist must NOT cache an authoritative negative,
/// or it suppresses the visible play's full fallback for 7 days.
final class LyricsNegativeAuthorityTests: XCTestCase {
    /// Baseline: every needed source answered with full effort → authoritative.
    func testFullEffortReachableNegativeIsAuthoritative() {
        XCTAssertTrue(LyricsNegativeAuthority.isAuthoritative(
            serverReachable: true,
            lrclibSkippedForMissingArtist: false,
            lrclibSkippedForDisabled: false,
            lrclibAvailable: true,
            lrclibReachable: true,
            allowedTitleOnlyFallback: true,
            hasUsableDuration: true
        ))
    }

    /// H1a: a prefetch that skipped the title-only fallback while a duration was
    /// available is reduced-effort — the fallback that finds different-artist
    /// filings never ran — so its negative is NOT authoritative.
    func testPrefetchWithoutTitleOnlyFallbackIsNotAuthoritative() {
        XCTAssertFalse(LyricsNegativeAuthority.isAuthoritative(
            serverReachable: true,
            lrclibSkippedForMissingArtist: false,
            lrclibSkippedForDisabled: false,
            lrclibAvailable: true,
            lrclibReachable: true,
            allowedTitleOnlyFallback: false,
            hasUsableDuration: true
        ))
    }

    /// Without a usable duration the visible resolve couldn't run the title-only
    /// fallback either (it's duration-gated), so a fallback-disabled negative is
    /// as complete as it'll get and stays authoritative.
    func testFallbackDisabledButNoDurationStaysAuthoritative() {
        XCTAssertTrue(LyricsNegativeAuthority.isAuthoritative(
            serverReachable: true,
            lrclibSkippedForMissingArtist: false,
            lrclibSkippedForDisabled: false,
            lrclibAvailable: true,
            lrclibReachable: true,
            allowedTitleOnlyFallback: false,
            hasUsableDuration: false
        ))
    }

    /// An unreachable server (offline/DNS/TLS) can never produce a trusted
    /// negative regardless of the other signals.
    func testUnreachableServerIsNeverAuthoritative() {
        XCTAssertFalse(LyricsNegativeAuthority.isAuthoritative(
            serverReachable: false,
            lrclibSkippedForMissingArtist: false,
            lrclibSkippedForDisabled: false,
            lrclibAvailable: true,
            lrclibReachable: true,
            allowedTitleOnlyFallback: true,
            hasUsableDuration: true
        ))
    }

    /// LRCLIB skipped purely for a missing artist → incomplete → not authoritative.
    func testMissingArtistSkipIsNotAuthoritative() {
        XCTAssertFalse(LyricsNegativeAuthority.isAuthoritative(
            serverReachable: true,
            lrclibSkippedForMissingArtist: true,
            lrclibSkippedForDisabled: false,
            lrclibAvailable: false,
            lrclibReachable: false,
            allowedTitleOnlyFallback: true,
            hasUsableDuration: true
        ))
    }

    /// LRCLIB available but unreachable (throttled/cancelled mid-skip) → the song
    /// it might have had goes unconfirmed → not authoritative.
    func testAvailableButUnreachableLRCLIBIsNotAuthoritative() {
        XCTAssertFalse(LyricsNegativeAuthority.isAuthoritative(
            serverReachable: true,
            lrclibSkippedForMissingArtist: false,
            lrclibSkippedForDisabled: false,
            lrclibAvailable: true,
            lrclibReachable: false,
            allowedTitleOnlyFallback: true,
            hasUsableDuration: true
        ))
    }

    /// B / H1b: lyrics were turned OFF, so LRCLIB was skipped and only the server
    /// was consulted. That skip is a temporary user setting, not a verdict — the
    /// server-only negative must NOT be cached as authoritative, or enabling
    /// lyrics and replaying would keep reading the poisoned negative for 7 days.
    func testLyricsDisabledServerOnlyNegativeIsNotAuthoritative() {
        XCTAssertFalse(LyricsNegativeAuthority.isAuthoritative(
            serverReachable: true,
            lrclibSkippedForMissingArtist: false,
            lrclibSkippedForDisabled: true,
            lrclibAvailable: false,
            lrclibReachable: false,
            allowedTitleOnlyFallback: true,
            hasUsableDuration: true
        ))
    }

    /// The disabled-skip guard holds even with no usable duration: re-enabling
    /// lyrics should still trigger a fresh LRCLIB lookup, so the negative formed
    /// while disabled is never authoritative.
    func testLyricsDisabledStaysNonAuthoritativeWithoutDuration() {
        XCTAssertFalse(LyricsNegativeAuthority.isAuthoritative(
            serverReachable: true,
            lrclibSkippedForMissingArtist: false,
            lrclibSkippedForDisabled: true,
            lrclibAvailable: false,
            lrclibReachable: false,
            allowedTitleOnlyFallback: true,
            hasUsableDuration: false
        ))
    }
}

@MainActor
final class MusicStreamResolutionTests: XCTestCase {
    func testResolverMaterializesAuthenticatedSourceAtPlaybackBoundary() async throws {
        let credentialRevision = CredentialRevision(rawValue: UUID())
        let locator = try AuthenticatedHTTPPlaybackLocator(
            provider: .jellyfin,
            accountID: "account",
            credentialRevision: credentialRevision,
            itemID: "track",
            deliveryMode: .directFile,
            formatHint: MediaFormatHint(container: "flac"),
            purpose: .audioStream,
            resource: try AuthenticatedHTTPResource(
                pathBase: .serverRoot,
                path: "/Audio/track/universal"
            )
        )
        let provider = ResolverMusicProvider(
            request: AudioPlaybackRequest(
                track: MusicTrack(id: "track", title: "Track"),
                playbackSource: .authenticatedHTTP(locator)
            )
        )
        let expectedURL = URL(
            string: "https://media.example/Audio/track/universal?api_key=secret"
        )!
        let resolver = RecordingAuthenticatedResolver(url: expectedURL)

        let resolved = await streamURLResolver(
            for: provider,
            authenticatedHTTPResolver: resolver
        )(MusicTrack(id: "track", title: "Track"))

        XCTAssertEqual(resolved?.url, expectedURL)
        let captured = await resolver.capturedLocator()
        XCTAssertEqual(captured, locator)
    }
}

private final class ResolverMusicProvider: MusicProvider, @unchecked Sendable {
    let accountID = "account"
    let providerKind = ProviderKind.jellyfin
    private let request: AudioPlaybackRequest

    init(request: AudioPlaybackRequest) {
        self.request = request
    }

    func musicLibraries() async throws -> [MediaLibrary] { [] }

    func musicItems(
        in containerID: String,
        kind: MusicItemKind,
        page: PageRequest
    ) async throws -> MusicPage {
        MusicPage()
    }

    func audioPlaybackInfo(
        for trackID: String,
        queueContext: [String]?
    ) async throws -> AudioPlaybackRequest {
        request
    }
}

@MainActor
private final class RecordingAuthenticatedResolver:
    AuthenticatedHTTPResourceResolving
{
    private let url: URL
    private var locator: AuthenticatedHTTPPlaybackLocator?

    init(url: URL) {
        self.url = url
    }

    func resolve(_ locator: AuthenticatedHTTPPlaybackLocator) async throws -> URL {
        self.locator = locator
        return url
    }

    func capturedLocator() -> AuthenticatedHTTPPlaybackLocator? {
        locator
    }
}
