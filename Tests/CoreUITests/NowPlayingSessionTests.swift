#if canImport(MediaPlayer)
import MediaPlayer
import AVFoundation
import XCTest
@testable import CoreUI

@MainActor
final class NowPlayingSessionTests: XCTestCase {
    func testNewOwnerResignsPreviousPlayerAndRejectsItsLateMetadata() {
        let ownership = NowPlayingOwnership()
        let musicBackend = Backend()
        let videoBackend = Backend()
        let music = NowPlayingSession(ownership: ownership, backend: musicBackend)
        let video = NowPlayingSession(ownership: ownership, backend: videoBackend)
        var resigned = false
        music.activate(onCommand: { _ in }, onResigned: { resigned = true })
        music.publish(["title": "Music"], state: .playing, transport: .init())

        video.activate(onCommand: { _ in }, onResigned: {})
        video.publish(["title": "Video"], state: .playing, transport: .init(canSeek: true))
        music.publish(["title": "Late artwork"], state: .paused, transport: .init())
        music.invalidate()

        XCTAssertTrue(resigned)
        XCTAssertFalse(music.isActive)
        XCTAssertTrue(video.isActive)
        XCTAssertEqual(musicBackend.publications.count, 1)
        XCTAssertEqual(musicBackend.clearCount, 1)
        XCTAssertEqual(videoBackend.publications.last?["title"] as? String, "Video")
        XCTAssertEqual(videoBackend.clearCount, 0)
        XCTAssertEqual(videoBackend.transport, .init(canSeek: true))
        video.invalidate()
    }

    func testQueuedCommandCannotCrossAnOwnershipOrActivationChange() async throws {
        let ownership = NowPlayingOwnership()
        let backend = Backend()
        let session = NowPlayingSession(ownership: ownership, backend: backend)
        var received: [NowPlayingCommand] = []
        session.activate(onCommand: { received.append($0) }, onResigned: {})
        let oldHandler = try XCTUnwrap(backend.handler)
        oldHandler(.play)
        session.invalidate()

        let delivered = expectation(description: "Current activation receives pause")
        session.activate(onCommand: {
            received.append($0)
            delivered.fulfill()
        }, onResigned: {})
        oldHandler(.nextTrack)
        backend.handler?(.pause)
        await fulfillment(of: [delivered], timeout: 1)

        XCTAssertEqual(received, [.pause])
        session.invalidate()
    }

    func testRepeatedActivationDoesNotInstallDuplicateTargets() {
        let backend = Backend()
        let session = NowPlayingSession(ownership: NowPlayingOwnership(), backend: backend)
        session.activate(onCommand: { _ in }, onResigned: {})
        session.activate(onCommand: { _ in }, onResigned: {})

        XCTAssertEqual(backend.installCount, 1)
        session.invalidate()
        session.invalidate()
        XCTAssertEqual(backend.clearCount, 1)
    }

    func testDelayedDeinitCannotClearTheNewOwner() async {
        let ownership = NowPlayingOwnership()
        let oldBackend = Backend()
        let nextBackend = Backend()
        var old: NowPlayingSession? = NowPlayingSession(ownership: ownership, backend: oldBackend)
        old?.activate(onCommand: { _ in }, onResigned: {})
        weak var released = old
        old = nil
        XCTAssertNil(released)

        let next = NowPlayingSession(ownership: ownership, backend: nextBackend)
        next.activate(onCommand: { _ in }, onResigned: {})
        next.publish(["title": "Next"], state: .playing, transport: .init())
        await Task.yield()

        XCTAssertTrue(next.isActive)
        XCTAssertEqual(oldBackend.clearCount, 0)
        XCTAssertEqual(nextBackend.clearCount, 0)
        next.invalidate()
    }

    private final class Backend: NowPlayingBackend {
        func bind(player: AVPlayer?) {}
        var handler: (@Sendable (NowPlayingCommand) -> Void)?
        var publications: [[String: Any]] = []
        var transport = NowPlayingTransport()
        var installCount = 0
        var clearCount = 0

        func install(_ handler: @escaping @Sendable (NowPlayingCommand) -> Void) {
            self.handler = handler
            installCount += 1
        }

        func publish(_ info: [String: Any], state: MPNowPlayingPlaybackState, transport: NowPlayingTransport) {
            publications.append(info)
            self.transport = transport
        }

        func removeHandlers() {
            handler = nil
        }

        func clear() {
            clearCount += 1
        }
    }
}
#endif
