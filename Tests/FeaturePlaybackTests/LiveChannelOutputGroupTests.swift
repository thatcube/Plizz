#if DEBUG && canImport(UIKit)
import XCTest
@testable import FeaturePlayback

@MainActor
final class LiveChannelOutputGroupTests: XCTestCase {
    func testAddingSilentPanePreservesAudioAndSingleDisplayOwner() {
        let group = LiveChannelOutputGroup()
        let first = LiveEngineSpy()
        let second = LiveEngineSpy()
        let firstID = UUID()
        let secondID = UUID()
        group.register(first, id: firstID, audible: true)
        group.register(second, id: secondID, audible: false)
        XCTAssertTrue(first.outputPolicy.isAudible)
        XCTAssertFalse(second.outputPolicy.isAudible)
        XCTAssertFalse(first.outputPolicy.suppressesDisplayMatching)
        XCTAssertTrue(second.outputPolicy.suppressesDisplayMatching)
        XCTAssertTrue(first.outputPolicy.sharesAudioSession)
        XCTAssertTrue(second.outputPolicy.sharesAudioSession)
        group.unregister(secondID)
        group.unregister(firstID)
    }

    func testAudioHandoffNeverMakesBothEnginesAudible() {
        let group = LiveChannelOutputGroup()
        let first = LiveEngineSpy()
        let second = LiveEngineSpy()
        let firstID = UUID()
        let secondID = UUID()
        group.register(first, id: firstID, audible: true)
        group.register(second, id: secondID, audible: false)
        var overlappingAudio = false
        first.onOutputPolicy = { _ in
            overlappingAudio = overlappingAudio || (first.outputPolicy.isAudible && second.outputPolicy.isAudible)
        }
        second.onOutputPolicy = { _ in
            overlappingAudio = overlappingAudio || (first.outputPolicy.isAudible && second.outputPolicy.isAudible)
        }
        group.setAudible(true, id: secondID)
        XCTAssertFalse(overlappingAudio)
        XCTAssertFalse(first.outputPolicy.isAudible)
        XCTAssertTrue(second.outputPolicy.isAudible)
        // A delayed old-view update must not mute the newly selected pane.
        group.setAudible(false, id: firstID)
        XCTAssertTrue(second.outputPolicy.isAudible)
        first.onOutputPolicy = nil
        second.onOutputPolicy = nil
        group.unregister(firstID)
        group.unregister(secondID)
    }

    func testOnlyLastDepartingEngineMayResetSharedAudioAndDisplay() {
        let group = LiveChannelOutputGroup()
        let first = LiveEngineSpy()
        let second = LiveEngineSpy()
        let firstID = UUID()
        let secondID = UUID()
        group.register(first, id: firstID, audible: true)
        group.register(second, id: secondID, audible: false)
        group.unregister(firstID)
        XCTAssertTrue(first.outputPolicy.sharesAudioSession)
        XCTAssertTrue(first.outputPolicy.suppressesDisplayMatching)
        group.unregister(secondID)
        XCTAssertFalse(second.outputPolicy.sharesAudioSession)
        XCTAssertFalse(second.outputPolicy.suppressesDisplayMatching)
    }

    func testLateDepartingRendererCannotMuteOrUnregisterItsReplacement() {
        let group = LiveChannelOutputGroup()
        let old = LiveEngineSpy()
        let replacement = LiveEngineSpy()
        let id = UUID()
        group.register(old, id: id, audible: true)
        group.register(replacement, id: id, audible: true)
        XCTAssertFalse(old.outputPolicy.isAudible)
        group.setAudible(false, id: id, engine: old)
        group.unregister(id, engine: old)
        XCTAssertTrue(replacement.outputPolicy.isAudible)
        group.unregister(id, engine: replacement)
        XCTAssertFalse(replacement.outputPolicy.sharesAudioSession)
    }

    func testStoppingOnePlayerDoesNotStopOrReloadItsSibling() async {
        let group = LiveChannelOutputGroup()
        let first = LiveEngineSpy()
        let second = LiveEngineSpy()
        let firstModel = LiveChannelPlayerModel(
            engine: first, streamURL: URL(string: "https://example.invalid/1.m3u8")!,
            outputGroup: group, isAudible: true
        )
        let secondModel = LiveChannelPlayerModel(
            engine: second, streamURL: URL(string: "https://example.invalid/2.m3u8")!,
            outputGroup: group, isAudible: false
        )
        await firstModel.start()
        await secondModel.start()
        secondModel.stop()
        XCTAssertEqual(second.stopCount, 1)
        XCTAssertEqual(first.stopCount, 0)
        XCTAssertEqual(first.liveLoads, 1)
        XCTAssertTrue(first.outputPolicy.isAudible)
        firstModel.stop()
    }
}
#endif
