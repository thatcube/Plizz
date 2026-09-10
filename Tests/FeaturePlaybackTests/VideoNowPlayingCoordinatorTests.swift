import AVFoundation
import MediaPlayer
import UIKit
import CoreModels
import CoreUI
import XCTest
@testable import FeaturePlayback

@MainActor
final class VideoNowPlayingCoordinatorTests: XCTestCase {
    func testPublishesVideoIdentityAndHonestTransportState() {
        let host = NowPlayingHostSpy()
        let publisher = VideoNowPlayingPublisherSpy()
        let sut = makeCoordinator(host, publisher)
        sut.begin(item: movie(), title: "Movie", subtitle: "", position: 25)

        XCTAssertEqual(publisher.info[MPMediaItemPropertyTitle] as? String, "Movie")
        XCTAssertEqual(publisher.info[MPNowPlayingInfoPropertyMediaType] as? UInt,
                       MPNowPlayingInfoMediaType.video.rawValue)
        XCTAssertEqual(publisher.info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 25)
        XCTAssertEqual(publisher.info[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 0)
        XCTAssertEqual(publisher.info[MPMediaItemPropertyPlaybackDuration] as? Double, 120)
        XCTAssertFalse(publisher.transport.canSeek)

        host.nowPlayingReady = true
        host.nowPlayingTime = 40
        host.nowPlayingSpeed = 1.5
        sut.refresh()
        XCTAssertEqual(publisher.info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 40)
        XCTAssertEqual(publisher.info[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 1.5)
        XCTAssertTrue(publisher.transport.canSeek)

        host.nowPlayingAdvancing = false
        sut.refresh()
        XCTAssertEqual(publisher.info[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 0)
        host.nowPlayingAdvancing = true
        host.nowPlayingSeeking = true
        sut.refresh()
        XCTAssertEqual(publisher.info[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 0)
        host.nowPlayingSeeking = false
        host.nowPlayingPaused = true
        sut.refresh()
        XCTAssertEqual(publisher.info[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 0)
        sut.end()
    }

    func testUnknownDurationIsNeitherSeekableNorAssumedLive() {
        let host = NowPlayingHostSpy()
        host.nowPlayingReady = true
        host.nowPlayingDuration = .infinity
        host.nowPlayingTime = .nan
        let publisher = VideoNowPlayingPublisherSpy()
        let sut = makeCoordinator(host, publisher)
        sut.begin(item: MediaItem(id: "live", title: "Stream", kind: .movie),
                  title: "Stream", subtitle: "", position: .nan)
        XCTAssertNil(publisher.info[MPMediaItemPropertyPlaybackDuration])
        XCTAssertNil(publisher.info[MPNowPlayingInfoPropertyIsLiveStream])
        XCTAssertEqual(publisher.info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 0)
        XCTAssertFalse(publisher.transport.canSeek)
        sut.end()
    }

    func testRemoteTransportUsesIntentAndClampsSeekAndRapidSkips() {
        let host = NowPlayingHostSpy()
        host.nowPlayingReady = true
        let publisher = VideoNowPlayingPublisherSpy()
        let sut = makeCoordinator(host, publisher)
        sut.begin(item: movie(), title: "Movie", subtitle: "", position: 0)

        publisher.command?(.togglePlayPause)
        XCTAssertTrue(host.nowPlayingPaused)
        publisher.command?(.togglePlayPause)
        XCTAssertFalse(host.nowPlayingPaused)
        publisher.command?(.seek(500))
        publisher.command?(.seek(-40))
        publisher.command?(.seek(.nan))
        host.nowPlayingPendingSeek = 50
        publisher.command?(.skip(10))
        publisher.command?(.skip(10))
        XCTAssertEqual(host.seeks, [120, 0, 60, 70])

        host.nowPlayingCanPlay = false
        host.nowPlayingPaused = true
        host.nowPlayingNext = MediaItem(id: "next", title: "Next", kind: .episode)
        sut.refresh()
        publisher.command?(.play)
        publisher.command?(.nextTrack)
        XCTAssertTrue(host.nowPlayingPaused)
        XCTAssertFalse(publisher.transport.canPlay)
        XCTAssertFalse(publisher.transport.hasNext)
        XCTAssertTrue(host.episodes.isEmpty)
        sut.end()
    }

    func testNeighborsAndStopUsePlayerLifecycle() {
        let host = NowPlayingHostSpy()
        host.nowPlayingReady = true
        let publisher = VideoNowPlayingPublisherSpy()
        let sut = makeCoordinator(host, publisher)
        sut.begin(item: movie(), title: "Movie", subtitle: "", position: 0)
        XCTAssertFalse(publisher.transport.hasNext)
        host.nowPlayingNext = MediaItem(id: "next", title: "Next", kind: .episode)
        host.nowPlayingPrevious = MediaItem(id: "previous", title: "Previous", kind: .episode)
        sut.refresh()
        XCTAssertTrue(publisher.transport.hasNext)
        XCTAssertTrue(publisher.transport.hasPrevious)
        publisher.command?(.nextTrack)
        publisher.command?(.previousTrack)
        publisher.command?(.stop)
        XCTAssertEqual(host.episodes, ["next", "previous"])
        XCTAssertEqual(host.stops, 1)
        sut.end()
    }

    func testResignedPlayerCannotReclaimControlsWhenFallbackFinishes() {
        let host = NowPlayingHostSpy()
        let publisher = VideoNowPlayingPublisherSpy()
        let sut = makeCoordinator(host, publisher)
        sut.begin(item: movie(), title: "Movie", subtitle: "", position: 0)
        publisher.resign()
        XCTAssertTrue(host.nowPlayingPaused)
        sut.begin(item: movie(), title: "Movie", subtitle: "", position: 60)
        sut.refresh()
        XCTAssertEqual(publisher.activations, 1)
        XCTAssertFalse(publisher.isActive)
        sut.activate()
        XCTAssertEqual(publisher.activations, 2)
        sut.end()
        XCTAssertFalse(publisher.isActive)
        XCTAssertTrue(publisher.info.isEmpty)
    }

    func testEpisodeArtworkNeverFallsBackToSpoilerFrames() {
        let spoiler = URL(string: "https://example.test/episode.jpg")!
        let series = URL(string: "https://example.test/series.jpg")!
        var item = MediaItem(id: "episode", title: "Episode", kind: .episode,
                             posterURL: spoiler, backdropURL: spoiler)
        XCTAssertTrue(VideoNowPlayingCoordinator.artworkReferences(for: item).isEmpty)
        item.seriesPosterURL = series
        XCTAssertEqual(VideoNowPlayingCoordinator.artworkReferences(for: item), [.remote(series)])
    }

    func testLateArtworkCannotRepublishAnEndedSession() async {
        let host = NowPlayingHostSpy()
        let publisher = VideoNowPlayingPublisherSpy()
        let began = expectation(description: "Artwork loader began")
        let finished = expectation(description: "Artwork loader returned")
        var completion: CheckedContinuation<MPMediaItemArtwork?, Never>?
        let sut = VideoNowPlayingCoordinator(
            host: host, publisher: publisher, startsClock: false,
            artworkLoader: { _, onUpdate in
                let result = await withCheckedContinuation { continuation in
                    completion = continuation
                    began.fulfill()
                }
                if let result { onUpdate(result) }
                finished.fulfill()
            }
        )
        let item = MediaItem(id: "movie", title: "Movie", kind: .movie,
                             posterURL: URL(string: "https://example.test/poster.jpg"))
        sut.begin(item: item, title: "Movie", subtitle: "", position: 0)
        await fulfillment(of: [began], timeout: 1)
        sut.end()
        completion?.resume(returning: NowPlayingSession.artwork(from: UIImage(systemName: "film")!))
        await fulfillment(of: [finished], timeout: 1)
        XCTAssertFalse(publisher.isActive)
        XCTAssertTrue(publisher.info.isEmpty)
    }

    func testProgressiveArtworkCannotOverwriteAnotherItemOrOwner() async throws {
        let host = NowPlayingHostSpy()
        let publisher = VideoNowPlayingPublisherSpy()
        let firstStarted = expectation(description: "First artwork loader")
        let nextStarted = expectation(description: "Next artwork loader")
        var callbacks: [String: @MainActor (MPMediaItemArtwork) -> Void] = [:]
        let sut = VideoNowPlayingCoordinator(
            host: host, publisher: publisher, startsClock: false,
            artworkLoader: { item, onUpdate in
                callbacks[item.id] = onUpdate
                (item.id == "movie" ? firstStarted : nextStarted).fulfill()
            }
        )
        sut.begin(item: movie(), title: "Movie", subtitle: "", position: 0)
        await fulfillment(of: [firstStarted], timeout: 1)
        let plain = NowPlayingSession.artwork(from: UIImage(systemName: "film")!)
        callbacks["movie"]?(plain)
        XCTAssertTrue(publisher.info[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork === plain)

        sut.begin(item: MediaItem(id: "next", title: "Next", kind: .movie),
                  title: "Next", subtitle: "", position: 0)
        await fulfillment(of: [nextStarted], timeout: 1)
        let next = NowPlayingSession.artwork(from: UIImage(systemName: "play")!)
        callbacks["next"]?(next)
        callbacks["movie"]?(plain)
        XCTAssertTrue(publisher.info[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork === next)
        publisher.resign()
        callbacks["next"]?(next)
        XCTAssertTrue(publisher.info.isEmpty)
        sut.end()
    }

    func testResumeRetriesLogoLoadCancelledAfterPlainArtwork() async {
        let host = NowPlayingHostSpy()
        let publisher = VideoNowPlayingPublisherSpy()
        let started = expectation(description: "Initial artwork")
        let retried = expectation(description: "Artwork retried after ownership returns")
        var completion: CheckedContinuation<Void, Never>?
        var attempts = 0
        let plain = NowPlayingSession.artwork(from: UIImage(systemName: "film")!)
        let sut = VideoNowPlayingCoordinator(
            host: host, publisher: publisher, startsClock: false,
            artworkLoader: { _, onUpdate in
                attempts += 1
                onUpdate(plain)
                if attempts == 1 {
                    await withCheckedContinuation {
                        completion = $0
                        started.fulfill()
                    }
                } else {
                    retried.fulfill()
                }
            }
        )
        sut.begin(item: movie(), title: "Movie", subtitle: "", position: 0)
        await fulfillment(of: [started], timeout: 1)
        publisher.resign()
        completion?.resume()
        sut.activate()
        await fulfillment(of: [retried], timeout: 1)
        XCTAssertEqual(attempts, 2)
        sut.end()
    }

    private func movie() -> MediaItem {
        MediaItem(id: "movie", title: "Movie", kind: .movie, runtime: 120)
    }

    private func makeCoordinator(
        _ host: NowPlayingHostSpy, _ publisher: VideoNowPlayingPublisherSpy
    ) -> VideoNowPlayingCoordinator {
        VideoNowPlayingCoordinator(host: host, publisher: publisher, startsClock: false,
                                   artworkLoader: { _, _ in })
    }
}

@MainActor
final class VideoNowPlayingPublisherSpy: NowPlayingPublishing {
    var isActive = false
    var info: [String: Any] = [:]
    var transport = NowPlayingTransport()
    var command: (@MainActor (NowPlayingCommand) -> Void)?
    var resigned: (@MainActor () -> Void)?
    var activations = 0
    func bind(player: AVPlayer?) {}
    func activate(onCommand: @escaping @MainActor (NowPlayingCommand) -> Void,
                  onResigned: @escaping @MainActor () -> Void) {
        isActive = true
        activations += 1
        command = onCommand
        resigned = onResigned
    }
    func publish(_ info: [String: Any], state: MPNowPlayingPlaybackState,
                 transport: NowPlayingTransport) {
        guard isActive else { return }
        self.info = info
        self.transport = transport
    }
    func invalidate() {
        isActive = false
        info = [:]
        command = nil
    }
    func resign() {
        invalidate()
        resigned?()
    }
}

@MainActor
private final class NowPlayingHostSpy: VideoNowPlayingHost {
    var nowPlayingPlayer: AVPlayer?
    var nowPlayingCanPlay = true
    var nowPlayingTime: TimeInterval = 0
    var nowPlayingDuration: TimeInterval = 0
    var nowPlayingSpeed = 1.0
    var nowPlayingPaused = false
    var nowPlayingAdvancing = true
    var nowPlayingReady = false
    var nowPlayingSeeking = false
    var nowPlayingPendingSeek: TimeInterval?
    var nowPlayingPrevious: MediaItem?
    var nowPlayingNext: MediaItem?
    var nowPlayingBackwardInterval: TimeInterval = 10
    var nowPlayingForwardInterval: TimeInterval = 30
    var seeks: [TimeInterval] = []
    var episodes: [String] = []
    var stops = 0
    func nowPlayingSetPaused(_ paused: Bool) { nowPlayingPaused = paused }
    func nowPlayingSeek(to seconds: TimeInterval) {
        seeks.append(seconds)
        nowPlayingPendingSeek = seconds
    }
    func nowPlayingPlayEpisode(_ item: MediaItem) { episodes.append(item.id) }
    func nowPlayingStop() { stops += 1 }
}
