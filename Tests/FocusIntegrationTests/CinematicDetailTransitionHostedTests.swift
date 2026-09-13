import CoreModels
@testable import CoreUI
import Observation
import SwiftUI
import UIKit
import XCTest

@MainActor
final class CinematicDetailTransitionHostedTests: XCTestCase {
    func testReturnConsumesAHeldPressPastVisualCompletion() async throws {
        final class HeldLeft: UIPress {
            override var type: UIPress.PressType { .leftArrow }
        }
        let fixture = try await makeFixture()
        defer { fixture.close() }
        fixture.model.open(in: fixture.window, usesCard: true)
        try await waitUntil { fixture.model.session?.stage == .complete }
        let session = try XCTUnwrap(fixture.model.session)
        session.close { fixture.model.path.removeLast() }
        let guardView = try XCTUnwrap(inputGuards(in: fixture.window).first)
        let press = HeldLeft()
        guardView.pressesBegan([press], with: UIPressesEvent())
        try await waitUntil { self.overlays(in: fixture.window).isEmpty }
        XCTAssertTrue(guardView.view === fixture.window)
        XCTAssertTrue(DetailTransitionNavigation.isNavigationInputSuppressed)
        guardView.pressesEnded([press], with: UIPressesEvent())
        try await waitUntil { self.inputGuards(in: fixture.window).isEmpty }
        XCTAssertFalse(DetailTransitionNavigation.isNavigationInputSuppressed)
    }

    func testEpisodeRowEntersAfterControlsAndBeforeNavigationUnlocks() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        fixture.model.revealsEpisodesLast = true
        fixture.model.open(in: fixture.window, usesCard: true)
        try await waitUntil { fixture.model.session?.stage == .controls }
        let session = try XCTUnwrap(fixture.model.session)
        let frame = try XCTUnwrap(fixture.model.frames[.episodes])
        XCTAssertLessThan(try pixel(fixture.window, at: frame)[0], 30)
        try await waitUntil { session.stage == .episodes }
        XCTAssertTrue(session.blocksNavigation)
        try await Task.sleep(for: .milliseconds(150))
        let fading = try pixel(fixture.window, at: frame)[0]
        XCTAssertGreaterThan(fading, 20)
        try await waitUntil { session.stage == .complete }
        XCTAssertGreaterThan(try pixel(fixture.window, at: frame)[0], 240)
        XCTAssertFalse(session.blocksNavigation)
        XCTAssertEqual(fixture.model.stages, [.artwork, .logo, .metadata, .controls, .episodes, .complete])
    }

    func testCardZoomPauseStagesAndReverseReturnUseTheRealSource() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let sourceFrame = try XCTUnwrap(fixture.model.source.visibleFrame(in: fixture.window))
        fixture.model.source.prepare(for: fixture.model.item)
        let initial = try XCTUnwrap(fixture.window.subviews.compactMap { $0 as? DetailTransitionOverlay }.first)
        // Motion must already be running before the destination is constructed.
        try await waitUntil {
            guard let frame = initial.cardContainer.layer.presentation()?.frame else { return false }
            return frame.width > sourceFrame.width + 30 && frame.width < fixture.window.bounds.width - 30
        }
        fixture.model.path.append(1)
        try await waitUntil { fixture.model.session != nil }
        let session = try XCTUnwrap(fixture.model.session)
        XCTAssertEqual(initial.card.contentMode, .scaleAspectFill)
        XCTAssertTrue(session.blocksNavigation)
        try await waitUntil { self.overlays(in: fixture.window).isEmpty }
        XCTAssertEqual(session.stage, .artwork)
        XCTAssertTrue(session.blocksNavigation)
        XCTAssertNotNil(session.returnArtwork)
        let hidden = try pixel(fixture.window, at: try XCTUnwrap(fixture.model.frames[.logo]))
        XCTAssertGreaterThan(hidden[2], hidden[0] + 40)
        try await waitUntil { session.stage == .complete && fixture.model.stages.last == .complete }
        XCTAssertEqual(fixture.model.stages, [.artwork, .logo, .metadata, .controls, .complete])
        XCTAssertFalse(session.blocksNavigation)
        XCTAssertTrue(inputGuards(in: fixture.window).isEmpty)
        let revealed = try pixel(fixture.window, at: try XCTUnwrap(fixture.model.frames[.logo]))
        XCTAssertGreaterThan(revealed[0], 240)
        XCTAssertGreaterThan(revealed[1], 240)
        let geometry = try XCTUnwrap(fixture.model.frames[.logo])
        XCTAssertGreaterThanOrEqual(geometry.minY, 0)
        XCTAssertLessThanOrEqual(try XCTUnwrap(fixture.model.frames[.controls]).maxY, 1080)
        let history = XCTAttachment(string: fixture.model.events.joined(separator: "\n"))
        history.name = "cinematic-detail-stage-timeline"
        history.lifetime = .keepAlways
        add(history)

        session.close { fixture.model.path.removeLast() }
        XCTAssertTrue(session.isClosing)
        try await waitUntil {
            guard let cover = self.overlays(in: fixture.window).first,
                  let frame = cover.cardContainer.layer.presentation()?.frame else { return false }
            return frame.width < fixture.window.bounds.width - 30 && frame.width > sourceFrame.width + 30
        }
        try await waitUntil { self.overlays(in: fixture.window).isEmpty }
        XCTAssertTrue(fixture.model.path.isEmpty)
        XCTAssertTrue(inputGuards(in: fixture.window).isEmpty)
        XCTAssertNil(session.returnArtwork)
        XCTAssertFalse(session.blocksNavigation)
        XCTAssertNotNil(fixture.model.source.visibleFrame(in: fixture.window))
        fixture.model.source.restoreFocus(in: fixture.window, preferred: nil)
        try await waitUntil {
            UIFocusSystem.focusSystem(for: fixture.window)?.focusedItem != nil
        }
    }

    func testNoCardStillGetsArtworkPauseAndTheSameStagedEntrance() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        fixture.model.open(in: fixture.window, usesCard: false)
        try await waitUntil { fixture.model.session != nil }
        let session = try XCTUnwrap(fixture.model.session)
        XCTAssertNil(session.returnArtwork)
        try await waitUntil { self.overlays(in: fixture.window).isEmpty }
        XCTAssertEqual(session.stage, .artwork)
        try await waitUntil { session.stage == .complete && fixture.model.stages.last == .complete }
        XCTAssertEqual(fixture.model.stages, [.artwork, .logo, .metadata, .controls, .complete])
        XCTAssertTrue(inputGuards(in: fixture.window).isEmpty)
        session.close { fixture.model.path.removeLast() }
        try await waitUntil { self.overlays(in: fixture.window).isEmpty }
        XCTAssertTrue(fixture.model.path.isEmpty)
    }

    func testBackDuringTheZoomCancelsAllRemainingReveals() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        fixture.model.open(in: fixture.window, usesCard: true)
        try await waitUntil { fixture.model.session != nil }
        let session = try XCTUnwrap(fixture.model.session)
        XCTAssertEqual(session.stage, .artwork)
        session.close { fixture.model.path.removeLast() }
        try await waitUntil { self.overlays(in: fixture.window).isEmpty }
        XCTAssertTrue(fixture.model.path.isEmpty)
        XCTAssertTrue(inputGuards(in: fixture.window).isEmpty)
        XCTAssertFalse(fixture.model.stages.contains(.logo))
        XCTAssertNil(session.returnArtwork)
    }

    func testSourceReplacementUsesNonspatialReturnInsteadOfTheWrongCard() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        fixture.model.open(in: fixture.window, usesCard: true)
        try await waitUntil { fixture.model.session?.stage == .complete }
        let session = try XCTUnwrap(fixture.model.session)
        fixture.model.source.itemKey = "another-title"
        session.close { fixture.model.path.removeLast() }
        try await waitUntil { self.overlays(in: fixture.window).isEmpty }
        XCTAssertTrue(inputGuards(in: fixture.window).isEmpty)
        XCTAssertTrue(fixture.model.path.isEmpty)
    }

    func testDisableAndDisappearanceReleaseTheInputGuardAndCover() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let disabled = TVDetailEntranceSession()
        disabled.attach(to: fixture.window, enabled: false)
        XCTAssertEqual(disabled.stage, .complete)
        XCTAssertFalse(disabled.blocksNavigation)
        XCTAssertTrue(overlays(in: fixture.window).isEmpty)
        fixture.model.open(in: fixture.window, usesCard: true)
        try await waitUntil { fixture.model.session != nil }
        let session = try XCTUnwrap(fixture.model.session)
        session.finishImmediately()
        XCTAssertEqual(session.stage, .complete)
        XCTAssertTrue(overlays(in: fixture.window).isEmpty)
        XCTAssertTrue(inputGuards(in: fixture.window).isEmpty)
    }

    func testPreparedSourceWithoutNavigationExpiresWithoutBlockingPlayback() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        fixture.model.source.prepare(for: fixture.model.item)
        XCTAssertEqual(overlays(in: fixture.window).count, 1)
        try await waitUntil { self.overlays(in: fixture.window).isEmpty }
        XCTAssertTrue(inputGuards(in: fixture.window).isEmpty)
    }

    func testInputGuardLeavesBackOutOfItsPressTypes() {
        let blocker = DetailTransitionInputGuard()
        XCTAssertFalse(blocker.allowedPressTypes.contains(NSNumber(value: UIPress.PressType.menu.rawValue)))
        XCTAssertTrue(blocker.allowedPressTypes.contains(NSNumber(value: UIPress.PressType.select.rawValue)))
        XCTAssertTrue(blocker.allowedTouchTypes.contains(NSNumber(value: UITouch.TouchType.indirect.rawValue)))
    }

    func testLateDestinationDoesNotRestartTheAlreadyRunningZoom() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        fixture.model.source.prepare(for: fixture.model.item)
        let pendingCover = try XCTUnwrap(overlays(in: fixture.window).first)
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertEqual(pendingCover.cardContainer.layer.presentation()?.frame.width ?? 0, 1920, accuracy: 1)
        fixture.model.path.append(1)
        try await waitUntil { fixture.model.session != nil }
        let session = try XCTUnwrap(fixture.model.session)
        try await waitUntil { self.overlays(in: fixture.window).isEmpty }
        XCTAssertNotNil(session.returnArtwork)
        XCTAssertEqual(pendingCover.cardContainer.frame, fixture.window.bounds)
        session.close { fixture.model.path.removeLast() }
        let reverse = try XCTUnwrap(overlays(in: fixture.window).first)
        XCTAssertLessThan(reverse.cardContainer.frame.width, 1920, "Back must assign its zoom target synchronously.")
        try await waitUntil { self.overlays(in: fixture.window).isEmpty }
    }

    func testBackStartsShrinkingEvenWhileSourceFocusIsUnavailable() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let original = try XCTUnwrap(fixture.model.source.geometry(in: fixture.window))
        fixture.model.open(in: fixture.window, usesCard: true)
        try await waitUntil { fixture.model.session?.stage == .complete }
        let session = try XCTUnwrap(fixture.model.session)
        fixture.model.source.isFocused = false
        fixture.model.source.view = nil
        session.close { fixture.model.path.removeLast() }
        let reverse = try XCTUnwrap(overlays(in: fixture.window).first)
        XCTAssertEqual(reverse.cardContainer.frame, original.frame)
        XCTAssertEqual(reverse.cardContainer.layer.cornerRadius, original.cornerRadius)
        XCTAssertEqual(reverse.backgroundColor, .clear, "The returning Home page must show outside the shrinking artwork.")
        try await waitUntil { self.overlays(in: fixture.window).isEmpty }
        XCTAssertTrue(inputGuards(in: fixture.window).isEmpty)
    }

    func testBackRevealsHomeBehindArtworkBeforeNativePopFinishes() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let corner = CGRect(x: 1890, y: 1040, width: 1, height: 1)
        let homePixel = try pixel(fixture.window, at: corner)
        fixture.model.open(in: fixture.window, usesCard: true)
        try await waitUntil { fixture.model.session?.stage == .complete }
        let session = try XCTUnwrap(fixture.model.session)
        let detailPixel = try pixel(fixture.window, at: corner)
        XCTAssertNotEqual(detailPixel, homePixel)
        session.close {
            // Keep the real detail behind the cover briefly, just as a slow
            // native pop can on device. Home must not wait for this lifecycle.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                fixture.model.path.removeLast()
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        let cover = try XCTUnwrap(overlays(in: fixture.window).first)
        XCTAssertFalse(try XCTUnwrap(cover.cardContainer.layer.presentation()).frame.contains(corner.origin))
        XCTAssertEqual(try pixel(fixture.window, at: corner), homePixel)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertTrue(cover.superview === fixture.window, "Artwork completion must not uncover a pending pop.")
        XCTAssertTrue(session.isClosing)
        XCTAssertTrue(DetailTransitionNavigation.isRestoringSourcePage)
        try await waitUntil { self.overlays(in: fixture.window).isEmpty }
        XCTAssertTrue(session.isClosing, "A popped detail must not become visible again during teardown.")
        XCTAssertFalse(DetailTransitionNavigation.isRestoringSourcePage)
    }

    func testOpeningCoverWaitsForDestinationAppearanceWithoutRestartingTheZoom() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        fixture.model.source.prepare(for: fixture.model.item)
        let session = TVDetailEntranceSession()
        defer { session.finishImmediately() }
        session.attach(to: fixture.window, enabled: true, waitsForPageAppearance: true)
        let cover = try XCTUnwrap(overlays(in: fixture.window).first)
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertTrue(cover.superview === fixture.window)
        XCTAssertEqual(cover.alpha, 1)
        XCTAssertEqual(cover.cardContainer.frame, fixture.window.bounds)
        session.pageAppeared()
        try await waitUntil { cover.superview == nil }
        XCTAssertEqual(session.stage, .artwork, "Appearance must not restart the zoom or its reveal clock.")
    }

    func testForegroundPauseStartsWhenTheLateBackdropBecomesVisible() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let coldItem = MediaItem(id: UUID().uuidString, title: "Cold movie", kind: .movie)
        let originalFrame = try XCTUnwrap(fixture.model.source.visibleFrame(in: fixture.window))
        DetailTransitionNavigation.prepare(for: coldItem, in: fixture.window, source: fixture.model.source)
        let session = TVDetailEntranceSession()
        defer { session.finishImmediately() }
        session.attach(to: fixture.window, enabled: true, waitsForBackdrop: true)
        let cover = try XCTUnwrap(overlays(in: fixture.window).first)
        try await Task.sleep(for: .milliseconds(1300))
        XCTAssertEqual(session.stage, .artwork)
        XCTAssertTrue(session.blocksNavigation)
        XCTAssertTrue(cover.superview === fixture.window)
        XCTAssertEqual(cover.screen.alpha, 1, "An unresolved backdrop must not fade the source into black.")
        XCTAssertEqual(cover.cardContainer.frame, originalFrame, "Do not animate an empty destination.")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 18)).image {
            UIColor.blue.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 32, height: 18))
        }
        let appeared = ContinuousClock.now
        session.resolvedDestinationArtwork(image)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(session.stage, .artwork)
        try await waitUntil { session.stage >= .logo }
        XCTAssertGreaterThanOrEqual(appeared.duration(to: .now), .milliseconds(450))
        XCTAssertNil(cover.superview)
        try await waitUntil { session.stage == .complete }
        session.resolvedDestinationArtwork(image)
        XCTAssertEqual(session.stage, .complete, "A quality upgrade must not restart the entrance.")
    }

    func testArtworkFailureRevealsControlsAndReleasesInput() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let session = TVDetailEntranceSession()
        defer { session.finishImmediately() }
        session.attach(to: fixture.window, enabled: true, waitsForBackdrop: true)
        let host = UIHostingController(rootView:
            HeroBackdropLayer(references: [], height: 1080, scrimTone: .black, ignoresOverscan: false)
                .environment(\.detailEntranceSession, session)
        )
        fixture.window.rootViewController = host
        host.view.layoutIfNeeded()
        try await waitUntil { session.stage == .complete }
        XCTAssertFalse(session.blocksNavigation)
        XCTAssertTrue(inputGuards(in: fixture.window).isEmpty)
    }

    func testBackStillWorksWhileWaitingForTheBackdrop() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        fixture.model.source.prepare(for: fixture.model.item)
        let session = TVDetailEntranceSession()
        defer { session.finishImmediately() }
        session.attach(to: fixture.window, enabled: true, waitsForBackdrop: true)
        try await Task.sleep(for: .milliseconds(700))
        var dismissed = false
        session.close { dismissed = true }
        XCTAssertTrue(dismissed)
        XCTAssertTrue(try XCTUnwrap(overlays(in: fixture.window).first).cardContainer.isHidden)
        try await waitUntil { self.overlays(in: fixture.window).isEmpty }
        XCTAssertFalse(session.blocksNavigation)
    }

    func testCachedPreviewReachesTransitionBeforeFullResolutionArtwork() async throws {
        let store = MetadataProviderSettingsStore()
        let original = store.load()
        var settings = original
        settings.preferOnlineArtwork = false
        store.save(settings)
        defer { store.save(original) }
        let (url, preview) = try await cachedPreview()
        ArtworkSession.shared.configuration.urlCache?.removeCachedResponse(for: URLRequest(url: url))
        XCTAssertNil(ArtworkImageCache.shared.cachedImage(for: url, variant: .heroBackdrop))
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let session = TVDetailEntranceSession()
        defer { session.finishImmediately() }
        session.attach(to: fixture.window, enabled: true, waitsForBackdrop: true)
        let cover = try XCTUnwrap(overlays(in: fixture.window).first)
        let host = UIHostingController(rootView:
            HeroBackdropLayer(
                references: [.remote(url)],
                asyncFallbackURL: {
                    try? await Task.sleep(for: .seconds(4))
                    return nil
                },
                height: 1080, scrimTone: .black, ignoresOverscan: false
            )
            .environment(\.detailEntranceSession, session)
        )
        fixture.window.rootViewController = host
        host.view.layoutIfNeeded()
        let started = ContinuousClock.now
        try await waitUntil { cover.destination.image != nil }
        XCTAssertLessThan(started.duration(to: .now), .milliseconds(500))
        XCTAssertTrue(cover.destination.image === preview)
        XCTAssertEqual(session.stage, .artwork)
    }

    func testBackdropRequestStartsBeforeDestinationAndIsAdoptedByThePage() async throws {
        let store = MetadataProviderSettingsStore()
        let original = store.load()
        var settings = original
        settings.preferOnlineArtwork = false
        store.save(settings)
        defer { store.save(original) }
        let (url, _) = try await cachedPreview(decode: false)
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let item = MediaItem(id: UUID().uuidString, title: "Show", kind: .series, backdropURL: url)
        let key = ArtworkResolveKey.make(
            references: item.artworkReferences(for: .detailBackdrop),
            variant: .heroBackdrop, maxAspectRatio: 3,
            pinIdentity: "detail:\(item.id)",
            providerPolicyIdentity: ArtworkResolveKey.policyIdentity(settings)
        )
        DetailTransitionNavigation.prepare(for: item, in: fixture.window, source: nil)
        DetailTransitionNavigation.preloadBackdrop(for: item)
        let cover = try XCTUnwrap(overlays(in: fixture.window).first)
        let task = try XCTUnwrap(DetailTransitionNavigation.backdropTask(matching: key))
        let result = await task.value
        let firstPaint = try XCTUnwrap(result)
        XCTAssertEqual(firstPaint.reference, .remote(url))
        XCTAssertEqual(firstPaint.variant, .heroPreview)
        try await waitUntil { cover.destination.image != nil }
        XCTAssertTrue(cover.destination.image === firstPaint.image)
        let session = TVDetailEntranceSession()
        defer { session.finishImmediately() }
        session.attach(to: fixture.window, enabled: true, waitsForBackdrop: true)
        XCTAssertEqual(task, try XCTUnwrap(session.backdropTask(matching: key)))
        XCTAssertNil(session.backdropTask(matching: key + "-another-title"))
    }

    func testPlayingTrailerSatisfiesBackdropReadiness() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let session = TVDetailEntranceSession()
        defer { session.finishImmediately() }
        session.attach(to: fixture.window, enabled: true, waitsForBackdrop: true)
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(session.stage, .artwork)
        session.resolvedDestinationVideo()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(session.stage, .artwork)
        try await waitUntil { session.stage == .complete }
    }

    func testFocusedPreferredBackdropPaintsAtSelectionWithoutAnotherLookup() async throws {
        let store = MetadataProviderSettingsStore()
        let original = store.load()
        var settings = original
        settings.preferOnlineArtwork = true
        store.save(settings)
        defer { store.save(original) }
        let (library, _) = try await cachedPreview()
        let (online, preview) = try await cachedPreview()
        let item = MediaItem(id: UUID().uuidString, title: "Show", kind: .series, backdropURL: library)
        let calls = ArtworkLookupCount()
        let fallback: @Sendable () async -> URL? = {
            await calls.record()
            return online
        }
        let source = DetailBackdropArtworkSource(
            references: item.artworkReferences(for: .detailBackdrop),
            pinIdentity: "detail:\(item.id)", settings: settings, fallback: fallback
        )
        await DetailBackdropFocusPrewarmer.warm(source)
        XCTAssertEqual(ArtworkSeedMemo.prepared(for: source.previewKey, variant: .heroPreview)?.reference, .remote(online))
        let fixture = try await makeFixture()
        defer { fixture.close() }
        DetailTransitionNavigation.prepare(for: item, in: fixture.window, source: nil)
        let cover = try XCTUnwrap(overlays(in: fixture.window).first)
        XCTAssertTrue(cover.destination.image === preview, "The selected preferred image must exist in the first transition frame.")
        let session = TVDetailEntranceSession()
        defer { session.finishImmediately() }
        session.attach(to: fixture.window, enabled: true, waitsForBackdrop: true)
        let host = UIHostingController(rootView:
            HeroBackdropLayer(
                references: source.references, asyncFallbackURL: fallback,
                height: 1080, scrimTone: .black, ignoresOverscan: false,
                pinIdentity: "detail:\(item.id)", backgroundVideo: { EmptyView() }
            ).environment(\.detailEntranceSession, session)
        )
        fixture.window.rootViewController = host
        host.view.layoutIfNeeded()
        try await waitUntil { session.stage == .complete }
        let count = await calls.value
        XCTAssertEqual(count, 1, "Mounting details must not choose the same image a second time.")
    }

    func testSettledFocusStartsBackdropPreparationWithoutTheOld350msDelay() async throws {
        let store = MetadataProviderSettingsStore()
        let original = store.load()
        var settings = original
        settings.preferOnlineArtwork = false
        store.save(settings)
        defer { store.save(original) }
        let (url, _) = try await cachedPreview()
        let item = MediaItem(id: UUID().uuidString, title: "Show", kind: .series, backdropURL: url)
        let source = DetailBackdropArtworkSource(item: item)
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let host = UIHostingController(rootView:
            Color.clear.preloadDetailBackdropOnFocus(for: item, isFocused: true)
        )
        let started = ContinuousClock.now
        fixture.window.rootViewController = host
        host.view.layoutIfNeeded()
        try await waitUntil { ArtworkSeedMemo.prepared(for: source.previewKey, variant: .heroPreview) != nil }
        XCTAssertLessThan(started.duration(to: .now), .milliseconds(300))
    }

    func testNavigationAdoptsFocusedLookupEvenWhenFocusLeaves() async throws {
        let store = MetadataProviderSettingsStore()
        let original = store.load()
        var settings = original
        settings.preferOnlineArtwork = true
        store.save(settings)
        defer { store.save(original) }
        let (library, _) = try await cachedPreview()
        let (online, _) = try await cachedPreview()
        let item = MediaItem(id: UUID().uuidString, title: "Show", kind: .series, backdropURL: library)
        let calls = ArtworkLookupCount()
        let gate = AsyncStream<URL>.makeStream()
        let source = DetailBackdropArtworkSource(
            references: item.artworkReferences(for: .detailBackdrop),
            pinIdentity: "detail:\(item.id)", settings: settings,
            fallback: {
                await calls.record()
                var iterator = gate.stream.makeAsyncIterator()
                return await iterator.next()
            }
        )
        let warmer = Task { await DetailBackdropFocusPrewarmer.warm(source) }
        defer {
            warmer.cancel()
            gate.continuation.finish()
        }
        let deadline = ContinuousClock.now + .seconds(2)
        while await calls.value == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let request = try XCTUnwrap(DetailBackdropArtworkRequest(item: item))
        warmer.cancel()
        gate.continuation.yield(online)
        gate.continuation.finish()
        let result = await request.task.value
        XCTAssertEqual(result?.reference, .remote(online))
        let count = await calls.value
        XCTAssertEqual(count, 1)
        XCTAssertNil(ArtworkSeedMemo.prepared(for: source.previewKey, variant: .heroPreview))
        request.cancel()
        await warmer.value
    }

    private actor ArtworkLookupCount {
        var value = 0
        func record() { value += 1 }
    }

    private func cachedPreview(decode: Bool = true) async throws -> (URL, UIImage) {
        let url = try XCTUnwrap(URL(string: "https://backdrop-fixture.example.test/\(UUID()).png"))
        let image = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 180)).image {
            UIColor.blue.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
        }
        let response = try XCTUnwrap(HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"]
        ))
        let cache = try XCTUnwrap(ArtworkSession.shared.configuration.urlCache)
        cache.storeCachedResponse(
            CachedURLResponse(response: response, data: try XCTUnwrap(image.pngData())),
            for: URLRequest(url: url)
        )
        guard decode else { return (url, image) }
        let preview = await ArtworkImageCache.shared.image(for: url, variant: .heroPreview)
        return (url, try XCTUnwrap(preview))
    }

    func testNonspatialReturnAlsoKeepsTheSourceCoveredUntilThePopCompletes() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        fixture.model.open(in: fixture.window, usesCard: false)
        try await waitUntil { fixture.model.session?.stage == .complete }
        let session = try XCTUnwrap(fixture.model.session)
        session.close {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { fixture.model.path.removeLast() }
        }
        let cover = try XCTUnwrap(overlays(in: fixture.window).first)
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertTrue(cover.superview === fixture.window)
        XCTAssertEqual(cover.alpha, 1, "Fade the artwork, not the source-page cover.")
        try await waitUntil { cover.superview == nil }
    }

    func testReturnRestoresCapturedScrollOffsetBeforeRemovingTheCover() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let scroll = UIScrollView(frame: CGRect(x: 100, y: 100, width: 500, height: 500))
        scroll.contentSize = CGSize(width: 500, height: 1800)
        let marker = UIView(frame: CGRect(x: 0, y: 500, width: 200, height: 300))
        marker.backgroundColor = .red
        scroll.addSubview(marker)
        let hosted = try XCTUnwrap(fixture.window.rootViewController)
        fixture.window.rootViewController = nil
        let container = UIViewController()
        container.view.frame = fixture.window.bounds
        container.addChild(hosted)
        container.view.addSubview(hosted.view)
        hosted.view.frame = container.view.bounds
        hosted.didMove(toParent: container)
        container.view.addSubview(scroll)
        fixture.window.rootViewController = container
        fixture.model.source.view = marker
        scroll.setContentOffset(CGPoint(x: 0, y: 400), animated: false)
        fixture.model.source.prepare(for: fixture.model.item)
        let session = TVDetailEntranceSession()
        defer { session.finishImmediately() }
        session.attach(to: fixture.window, enabled: true)
        try await waitUntil { session.stage == .complete }
        session.close { scroll.setContentOffset(.zero, animated: false) }
        try await waitUntil { self.overlays(in: fixture.window).isEmpty }
        XCTAssertEqual(scroll.contentOffset.y, 400, accuracy: 1)
        XCTAssertFalse(DetailTransitionNavigation.isRestoringSourcePage)
    }

    func testPreparedNavigationDisablesTheUnderlyingStackAnimation() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        fixture.model.open(in: fixture.window, usesCard: true)
        try await waitUntil { fixture.model.session?.stage == .complete }
        XCTAssertFalse(fixture.model.navigationAnimations.isEmpty)
        XCTAssertFalse(fixture.model.navigationAnimations.contains(true))
    }

    func testUnpreparedNavigationKeepsTheUnderlyingStackAnimation() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        withAnimation {
            DetailTransitionNavigation.performNavigation { fixture.model.path.append(1) }
        }
        try await waitUntil { fixture.model.session?.stage == .complete }
        XCTAssertTrue(fixture.model.navigationAnimations.contains(true))
    }

    func testMemoryPressureReleasesTheReturnBackdropWithoutBlockingBack() async throws {
        final class WeakSurface {
            weak var value: DetailTransitionSurface?
            init(_ value: DetailTransitionSurface?) { self.value = value }
        }
        let fixture = try await makeFixture()
        defer { fixture.close() }
        fixture.model.open(in: fixture.window, usesCard: true)
        let background = WeakSurface(overlays(in: fixture.window).first?.screen)
        try await waitUntil { fixture.model.session?.stage == .complete }
        let session = try XCTUnwrap(fixture.model.session)
        XCTAssertNotNil(background.value)
        session.releaseReturnBackgroundForMemoryPressure()
        XCTAssertNil(background.value)
        session.close { fixture.model.path.removeLast() }
        try await waitUntil { self.overlays(in: fixture.window).isEmpty }
        XCTAssertTrue(inputGuards(in: fixture.window).isEmpty)
    }

    func testDirectPlaybackDoesNotPrepareOrRunADetailEntrance() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        DetailTransitionNavigation.suppressNextEntrance(in: fixture.window)
        fixture.model.open(in: fixture.window, usesCard: true)
        XCTAssertTrue(overlays(in: fixture.window).isEmpty)
        try await waitUntil { fixture.model.session?.stage == .complete }
        XCTAssertTrue(overlays(in: fixture.window).isEmpty)
        XCTAssertTrue(inputGuards(in: fixture.window).isEmpty)
        XCTAssertNil(fixture.model.session?.returnArtwork)
    }

    func testCoveredParentCannotDiscardItsChildsPreparedTransition() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        fixture.model.open(in: fixture.window, usesCard: true)
        try await waitUntil { fixture.model.session?.stage == .complete }
        let parent = try XCTUnwrap(fixture.model.session)
        let child = MediaItem(id: "related-movie", title: "Related", kind: .movie)
        DetailTransitionNavigation.prepare(for: child, in: fixture.window, source: nil)
        let cover = try XCTUnwrap(overlays(in: fixture.window).first)
        parent.disappeared()
        XCTAssertTrue(overlays(in: fixture.window).contains { $0 === cover })
        let prepared = try XCTUnwrap(DetailTransitionNavigation.take(in: fixture.window))
        XCTAssertEqual(prepared.itemKey, child.stablePresentationID)
        prepared.discard()
        XCTAssertTrue(inputGuards(in: fixture.window).isEmpty)
    }

    func testDisabledPageDoesNotClaimALaterPreparedChild() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let parent = TVDetailEntranceSession()
        parent.attach(to: fixture.window, enabled: false)
        fixture.model.source.prepare(for: fixture.model.item)
        parent.attach(to: fixture.window, enabled: false)
        let prepared = try XCTUnwrap(DetailTransitionNavigation.take(in: fixture.window))
        prepared.discard()
    }

    func testTrailerHandoffUsesTheCapturedVideoFrameInsteadOfAScreenSnapshot() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let videoFrame = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 12)).image {
            UIColor.green.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 20, height: 12))
        }
        DetailTransitionNavigation.prepare(
            for: fixture.model.item, in: fixture.window, source: nil, artworkSnapshot: videoFrame
        )
        let cover = try XCTUnwrap(overlays(in: fixture.window).first)
        XCTAssertTrue(cover.screen.image === videoFrame)
        DetailTransitionNavigation.take(in: fixture.window)?.discard()
    }

    func testRealPosterArtworkAnchorExcludesCaptionAndSurvivesOpaqueRasterization() async throws {
        try await waitUntil {
            UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        for style in [CardStyle.framed, .borderless] {
            for shape in [PosterCardView.Style.poster, .landscape] {
                let previous = scene.windows.first(where: \.isKeyWindow)
                let item = MediaItem(id: "actual-poster-\(style)", title: "Poster Caption", kind: .movie)
                let host = UIHostingController(rootView: PosterCardView(
                    item: item, style: shape, enablesAsyncArtworkFallback: false
                ) {}.frame(width: shape == .poster ? 240 : 520)
                    .environment(\.plozzCardStyle, style)
                    // Rasterization belongs to custom focus; native projection
                    // can change the presented artwork's aspect ratio.
                    .environment(\.plozzCardFocusStyle, .outlined)
                    .environment(\.plozzReduceTransparency, true))
                let window = UIWindow(windowScene: scene)
                window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
                window.rootViewController = host
                window.makeKeyAndVisible()
                host.view.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(150))
                defer {
                    DetailTransitionNavigation.take(in: window)?.discard()
                    window.isHidden = true
                    window.rootViewController = nil
                    previous?.makeKeyAndVisible()
                }
                try await waitUntil { self.sourceView(in: window)?.reference?.visibleFrame(in: window) != nil }
                let marker = try XCTUnwrap(sourceView(in: window))
                let source = try XCTUnwrap(marker.reference)
                let artwork = try XCTUnwrap(source.visibleFrame(in: window))
                let wholeCard = marker.convert(marker.bounds, to: window)
                XCTAssertEqual(
                    artwork.width / artwork.height,
                    shape == .poster ? 2.0 / 3.0 : 16.0 / 9.0, accuracy: 0.02
                )
                XCTAssertLessThan(artwork.maxY, wholeCard.maxY - 10, "The transition must not enlarge the caption")
                source.prepare(for: item)
                let cover = try XCTUnwrap(overlays(in: window).first)
                XCTAssertEqual(cover.card.captureSize.width, artwork.width, accuracy: 1)
                XCTAssertEqual(cover.card.captureSize.height, artwork.height, accuracy: 1)
            }
        }
    }

    private func sourceView(in view: UIView) -> DetailTransitionSourceView? {
        if let source = view as? DetailTransitionSourceView { return source }
        return view.subviews.lazy.compactMap { self.sourceView(in: $0) }.first
    }

    private func pixel(_ window: UIWindow, at frame: CGRect) throws -> [Int] {
        let image = DetailTransitionSnapshot.image(of: window)
        let pixel = try XCTUnwrap(image.cgImage?.cropping(to: CGRect(
            x: frame.midX, y: frame.midY, width: 1, height: 1
        )))
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes {
            let context = try XCTUnwrap(CGContext(
                data: $0.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes.map(Int.init)
    }

    private func makeFixture() async throws -> CinematicFixtureWindow {
        try await waitUntil {
            UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let fixture = CinematicFixtureWindow(scene: scene)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 180)).image {
            UIColor.blue.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
        }
        let source = DetailBackdropArtworkSource(item: fixture.model.item)
        ArtworkSeedMemo.store(
            FirstPaintArtwork(
                image: image, reference: .remote(URL(string: "https://cinematic-fixture.example.test/blue.png")!),
                variant: .heroBackdrop
            ),
            for: source.key
        )
        try await waitUntil { fixture.model.source.visibleFrame(in: fixture.window) != nil }
        try await Task.sleep(for: .milliseconds(150))
        return fixture
    }

    private func overlays(in window: UIWindow) -> [DetailTransitionOverlay] {
        window.subviews.compactMap { $0 as? DetailTransitionOverlay }
    }

    private func inputGuards(in window: UIWindow) -> [DetailTransitionInputGuard] {
        (window.gestureRecognizers ?? []).compactMap { $0 as? DetailTransitionInputGuard }
    }

    private func waitUntil(
        file: StaticString = #filePath, line: UInt = #line,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "Cinematic transition did not reach its expected state", file: file, line: line)
    }
}

@MainActor
private final class CinematicFixtureWindow {
    let window: UIWindow
    let previousWindow: UIWindow?
    let model = CinematicFixtureModel()

    init(scene: UIWindowScene) {
        previousWindow = scene.windows.first(where: \.isKeyWindow)
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let host = UIHostingController(rootView: CinematicFixtureRoot(model: model))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        window.layoutIfNeeded()
    }

    func close() {
        model.session?.finishImmediately()
        DetailTransitionNavigation.take(in: window)?.discard()
        window.isHidden = true
        window.rootViewController = nil
        previousWindow?.makeKeyAndVisible()
    }
}

@MainActor @Observable
private final class CinematicFixtureModel {
    let item = MediaItem(id: "cinematic-movie", title: "Movie", kind: .movie)
    let source = DetailTransitionSourceReference()
    var path: [Int] = []
    var revealsEpisodesLast = false
    @ObservationIgnored var session: TVDetailEntranceSession?
    @ObservationIgnored var stages: [DetailEntranceStage] = []
    @ObservationIgnored var frames: [DetailEntranceStage: CGRect] = [:]
    @ObservationIgnored var events: [String] = []
    @ObservationIgnored var navigationAnimations: [Bool] = []

    func open(in window: UIWindow, usesCard: Bool) {
        DetailTransitionNavigation.prepare(for: item, in: window, source: usesCard ? source : nil)
        withCinematicDetailNavigation(for: item) { path.append(1) }
    }
}

private struct CinematicFixtureRoot: View {
    @Bindable var model: CinematicFixtureModel

    var body: some View {
        NavigationStack(path: $model.path) {
            Color.red
                .frame(width: 200, height: 300)
                .clipShape(RoundedRectangle(cornerRadius: 24))
                .background {
                    DetailTransitionSourceAnchor(reference: model.source,
                                                 itemKey: model.item.stablePresentationID, cornerRadius: 24)
                }
                .focusable()
                .navigationDestination(for: Int.self) { _ in
                    CinematicFixturePage(model: model)
                        .cinematicDetailPage(isEnabled: true, revealsEpisodesLast: model.revealsEpisodesLast)
                }
        }
    }
}

private struct CinematicFixturePage: View {
    let model: CinematicFixtureModel
    @Environment(\.detailEntranceSession) private var session

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Color.white.frame(width: 200, height: 60)
                .detailEntranceStage(.logo)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                    model.frames[.logo] = $0
                }
            Color.yellow.frame(width: 400, height: 60)
                .detailEntranceStage(.metadata)
            Button("Play") {}
                .detailEntranceStage(.controls)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                    model.frames[.controls] = $0
                }
            if model.revealsEpisodesLast {
                Color(red: 1, green: 0, blue: 1)
                    .frame(width: 400, height: 60)
                    .detailEntranceStage(.episodes)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                        model.frames[.episodes] = $0
                    }
            }
        }
        .padding(80)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .background(.blue)
        .background { NavigationAppearanceProbe(model: model) }
        .modifier(DetailTopSafeAreaBreakout())
        .onAppear {
            model.session = session
            model.stages = [.artwork]
        }

        .onChange(of: session?.stage) { _, stage in
            if let stage, model.stages.last != stage {
                model.stages.append(stage)
                model.events.append("\(Date().timeIntervalSince1970): \(stage)")
            }
        }
    }
}

private struct NavigationAppearanceProbe: UIViewControllerRepresentable {
    let model: CinematicFixtureModel

    func makeUIViewController(context: Context) -> Controller {
        Controller(model: model)
    }

    func updateUIViewController(_ controller: Controller, context: Context) {}

    final class Controller: UIViewController {
        let model: CinematicFixtureModel

        init(model: CinematicFixtureModel) {
            self.model = model
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            model.navigationAnimations.append(transitionCoordinator?.isAnimated ?? animated)
        }
    }
}
