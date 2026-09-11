#if os(iOS)
import AVKit
import Combine
import FeaturePlayback
import SwiftUI

/// Picture in Picture for the custom player.
///
/// Built by hand rather than inherited from `AVPlayerViewController`. Letting
/// AVKit own the player is the small-code route and it is what AetherPlayer
/// does, but it also brings Apple's chrome to *normal* playback, which would
/// replace the transport, scrub previews, subtitle styling and menus this app
/// has. The PiP window itself is system-drawn either way, so nothing is lost by
/// driving the controller directly.
///
/// Availability is a real question, not a formality: PiP presents from an
/// `AVPlayerLayer`, and the engine only has one on its native path. A software
/// -decoded source has no `AVPlayer`, so the button has to disappear rather than
/// fail when pressed.
@MainActor
final class PlozziOSPictureInPictureController: NSObject, ObservableObject {
    @Published private(set) var isAvailable = false
    @Published private(set) var isAirPlayActive = false
    @Published private var lifecycle = LivePictureInPictureLifecycle()

    var isActive: Bool { lifecycle.state == .active || lifecycle.state == .stopping }
    var isStarting: Bool { lifecycle.state == .starting }
    var continuesPlayback: Bool { lifecycle.continuesPlayback }
    var onContinuationChanged: ((Bool) -> Void)?
    var restoreUI: (() async -> Bool)?
    var usesNativeSubtitles = true {
        didSet { updateNativeSubtitles() }
    }
    var allowsAutomaticStart = true {
        didSet {
            controller?.canStartPictureInPictureAutomaticallyFromInline =
                permitsExternalPresentation && allowsAutomaticStart
        }
    }
    var permitsExternalPresentation = true {
        didSet {
            guard permitsExternalPresentation != oldValue else { return }
            externalPlaybackPolicy.isAllowed = permitsExternalPresentation
            rebuild()
        }
    }

    /// Called when the user restores from the PiP window, so the host can put the
    /// player back on screen if it was dismissed while PiP was running.
    var onRestoreUI: (() async -> Void)?

    private var controller: AVPictureInPictureController?
    private weak var engine: (any PictureInPicturePresentingEngine)?
    private var observations: Set<AnyCancellable> = []
    private var routeObservation: AnyCancellable?
    private weak var observedPlayer: AVPlayer?
    private var startTimeout: Task<Void, Never>?
    private var layerReplacement: Task<Void, Never>?
    private weak var pendingLayer: AVPlayerLayer?
    private var restoreTask: Task<Void, Never>?
    private var restoreTimeout: Task<Void, Never>?
    private var restoreCompletion: ((Bool) -> Void)?
    private var reportedContinuation = false
    private let externalPlaybackPolicy = LiveChannelExternalPlaybackPolicy()

    /// Binds to the engine's presenting layer. Safe to call repeatedly: the
    /// engine republishes its player across audio-track reloads, and a controller
    /// built against a stale layer stops working silently.
    func attach(engine: any PictureInPicturePresentingEngine) {
        if let current = self.engine, current !== engine {
            detach()
        }
        var engine = engine
        self.engine = engine
        // Follow layer swaps rather than hoping some other state change happens
        // to re-trigger an attach. Starting AirPlay reloads the source against
        // the device's LAN address, which rebuilds the player and leaves this
        // controller holding a layer that is no longer on screen: the PiP button
        // silently disappeared until an unrelated phase change rebuilt it.
        engine.onPresentationLayerChanged = { [weak self] in
            self?.rebuild()
        }
        rebuild()
    }

    /// Hiding the inline surface is not the end of an external presentation.
    /// Only the session owner may request the default, final detach.
    func detach(preservingActivePresentation: Bool = false) {
        guard lifecycle.shouldDetach(
            preservingPresentation: preservingActivePresentation,
            externalPlaybackActive: isAirPlayActive
        ) else { return }
        startTimeout?.cancel()
        startTimeout = nil
        completeRestore(false)
        engine?.onPresentationLayerChanged = nil
        controller?.delegate = nil
        if controller?.isPictureInPictureActive == true {
            controller?.stopPictureInPicture()
        }
        finishPresentation()
        controller = nil
        engine?.setNativeSubtitlesActive(false)
        engine = nil
        observations.removeAll()
        routeObservation = nil
        observedPlayer = nil
        externalPlaybackPolicy.bind(nil)
        isAirPlayActive = false
        reportContinuation()
        isAvailable = false
    }

    func toggle() {
        guard permitsExternalPresentation, let controller else { return }
        if continuesPlayback {
            lifecycle.requestStop()
            controller.stopPictureInPicture()
        } else if isAvailable {
            beginStarting()
            controller.startPictureInPicture()
        }
    }

    private func rebuild() {
        guard let layer = engine?.pictureInPicturePlayerLayer() else {
            controller?.delegate = nil
            controller?.stopPictureInPicture()
            controller = nil
            observations.removeAll()
            routeObservation = nil
            observedPlayer = nil
            externalPlaybackPolicy.bind(nil)
            isAirPlayActive = false
            finishPresentation()
            isAvailable = false
            return
        }
        externalPlaybackPolicy.bind(layer.player)
        observeRoute(layer.player)
        guard permitsExternalPresentation, AVPictureInPictureController.isPictureInPictureSupported() else {
            controller?.delegate = nil
            controller?.stopPictureInPicture()
            controller = nil
            observations.removeAll()
            finishPresentation()
            isAvailable = false
            return
        }
        // Same layer as last time: keep the controller, otherwise starting PiP
        // would present from a surface that is no longer on screen.
        if let existing = controller, existing.playerLayer === layer {
            isAvailable = existing.isPictureInPicturePossible
            isAirPlayActive = layer.player?.isExternalPlaybackActive == true
            reportContinuation()
            return
        }
        if let existing = controller, lifecycle.state == .active || lifecycle.state == .starting {
            replaceContentSourceWhenReady(layer, controller: existing)
            return
        }
        controller?.delegate = nil
        controller?.stopPictureInPicture()
        finishPresentation()
        let built = AVPictureInPictureController(playerLayer: layer)
        built?.delegate = self
        // The system decides when an inline player is eligible; asking for it
        // means backgrounding the app continues playback in a window instead of
        // stopping, which is the behaviour people expect from a video app.
        built?.canStartPictureInPictureAutomaticallyFromInline = permitsExternalPresentation && allowsAutomaticStart
        controller = built
        observations.removeAll()
        isAirPlayActive = layer.player?.isExternalPlaybackActive == true
        reportContinuation()
        isAvailable = built?.isPictureInPicturePossible == true
        built?.publisher(for: \.isPictureInPicturePossible)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak built] possible in
                guard let self, let built, self.controller === built else { return }
                self.isAvailable = self.permitsExternalPresentation && possible
            }
            .store(in: &observations)
    }

    private func replaceContentSourceWhenReady(
        _ layer: AVPlayerLayer,
        controller: AVPictureInPictureController
    ) {
        guard pendingLayer !== layer else { return }
        layerReplacement?.cancel()
        pendingLayer = layer
        layerReplacement = Task { [weak self, weak layer, weak controller] in
            for _ in 0..<100 {
                guard !Task.isCancelled, let self, let layer, let controller,
                      self.controller === controller, self.permitsExternalPresentation,
                      self.engine?.pictureInPicturePlayerLayer() === layer else { return }
                if layer.isReadyForDisplay {
                    // AVKit permits an active source swap only once the new layer is ready.
                    controller.contentSource = .init(playerLayer: layer)
                    self.pendingLayer = nil
                    self.layerReplacement = nil
                    self.isAvailable = controller.isPictureInPicturePossible
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard !Task.isCancelled, let self, let controller, self.controller === controller else { return }
            controller.stopPictureInPicture()
            self.finishPresentation()
            self.rebuild()
        }
    }

    private func observeRoute(_ player: AVPlayer?) {
        guard observedPlayer !== player else { return }
        routeObservation = nil
        observedPlayer = player
        isAirPlayActive = player?.isExternalPlaybackActive == true
        reportContinuation()
        routeObservation = player?.publisher(for: \.isExternalPlaybackActive)
            .sink { [weak self, weak player] active in
                let update = { @MainActor [weak self, weak player] in
                    guard let self, let player, self.observedPlayer === player else { return }
                    self.isAirPlayActive = active
                    self.reportContinuation()
                }
                if Thread.isMainThread {
                    MainActor.assumeIsolated { update() }
                } else {
                    Task { @MainActor in update() }
                }
            }
    }

    /// Re-reads the engine's layer. Call when playback (re)starts: the layer does
    /// not exist until the native path has loaded.
    func refresh() {
        rebuild()
    }

    private func beginStarting() {
        guard permitsExternalPresentation, lifecycle.beginStart(isPossible: true) else { return }
        updateEngineContinuation()
        startTimeout?.cancel()
        startTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self,
                  self.lifecycle.state == .starting || self.lifecycle.state == .stopping else { return }
            let engine = self.engine
            self.detach()
            if let engine { self.attach(engine: engine) }
        }
    }

    private func finishPresentation() {
        layerReplacement?.cancel()
        layerReplacement = nil
        pendingLayer = nil
        lifecycle.finish()
        startTimeout?.cancel()
        startTimeout = nil
        updateEngineContinuation()
    }

    private func updateEngineContinuation() {
        engine?.setPictureInPictureActive(permitsExternalPresentation && continuesPlayback)
        updateNativeSubtitles()
        reportContinuation()
    }

    private func updateNativeSubtitles() {
        engine?.setNativeSubtitlesActive(
            permitsExternalPresentation && (continuesPlayback || isAirPlayActive) && usesNativeSubtitles
        )
    }

    private func reportContinuation() {
        let continuing = permitsExternalPresentation && (continuesPlayback || isAirPlayActive)
        guard continuing != reportedContinuation else { return }
        reportedContinuation = continuing
        updateNativeSubtitles()
        onContinuationChanged?(continuing)
    }

    private func completeRestore(_ restored: Bool) {
        let completion = restoreCompletion
        restoreCompletion = nil
        restoreTask?.cancel()
        restoreTask = nil
        restoreTimeout?.cancel()
        restoreTimeout = nil
        completion?(restored)
    }

    private var hasVisibleInlineSurface: Bool {
        var layer: CALayer? = engine?.pictureInPicturePlayerLayer()
        while let current = layer {
            if current.isHidden || current.opacity == 0 { return false }
            if let view = current.delegate as? UIView, let window = view.window {
                var ancestor: UIView? = view
                while let currentView = ancestor {
                    if currentView.isHidden || currentView.alpha == 0 { return false }
                    ancestor = currentView.superview
                }
                return view.convert(view.bounds, to: window).intersects(window.bounds)
            }
            layer = current.superlayer
        }
        return false
    }
}

extension PlozziOSPictureInPictureController: @preconcurrency AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerWillStartPictureInPicture(
        _ controller: AVPictureInPictureController
    ) {
        guard controller === self.controller else { return }
        guard permitsExternalPresentation else {
            controller.stopPictureInPicture()
            return
        }
        beginStarting()
    }

    func pictureInPictureControllerDidStartPictureInPicture(
        _ controller: AVPictureInPictureController
    ) {
        guard controller === self.controller else { return }
        guard permitsExternalPresentation, lifecycle.didStart() else {
            controller.stopPictureInPicture()
            return
        }
        startTimeout?.cancel()
        startTimeout = nil
        updateEngineContinuation()
    }

    func pictureInPictureControllerDidStopPictureInPicture(
        _ controller: AVPictureInPictureController
    ) {
        guard controller === self.controller else { return }
        finishPresentation()
        if let layer = engine?.pictureInPicturePlayerLayer(), controller.playerLayer !== layer {
            rebuild()
        }
    }

    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        guard controller === self.controller else { return }
        finishPresentation()
    }

    /// Fired when the user taps the PiP window's restore button. The completion
    /// handler must be called or AVKit leaves the window in a half-restored
    /// state, so it runs even when the host has nothing to put back.
    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler
        completionHandler: @escaping (Bool) -> Void
    ) {
        guard controller === self.controller else { completionHandler(false); return }
        completeRestore(false)
        restoreCompletion = completionHandler
        restoreTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.completeRestore(false)
        }
        let restoreUI = restoreUI
        let legacyRestoreUI = onRestoreUI
        restoreTask = Task { [weak self] in
            let restored: Bool
            if let restoreUI {
                restored = await restoreUI()
            } else if let legacyRestoreUI {
                await legacyRestoreUI()
                restored = self?.hasVisibleInlineSurface == true
            } else {
                restored = false
            }
            guard !Task.isCancelled else { return }
            guard restored else { self?.completeRestore(false); return }
            // Tab selection and expanded-player state commit before UIKit has
            // necessarily mounted the retained layer. Confirm the real surface.
            for _ in 0..<30 {
                guard !Task.isCancelled else { return }
                if let self, controller === self.controller, self.hasVisibleInlineSurface {
                    self.completeRestore(true)
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
            self?.completeRestore(false)
        }
    }
}
#endif
