import CoreModels
import Foundation
import SwiftUI

public enum DetailEntranceStage: Int, Comparable, Sendable {
    case artwork, logo, metadata, controls, episodes, complete

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct DetailEntranceTiming: Equatable, Sendable {
    public var zoom: TimeInterval = 0.55
    public var artworkPause: TimeInterval = 0.5
    public var stagger: TimeInterval = 0.18
    public var reveal: TimeInterval = 0.32
    public var reverse: TimeInterval = 0.38

    public init() {}
}

@MainActor
public func withCinematicDetailNavigation(for item: MediaItem, _ navigate: () -> Void) {
    #if os(tvOS)
    DetailTransitionNavigation.prepare(for: item)
    DetailTransitionNavigation.preloadBackdrop(for: item)
    DetailTransitionNavigation.performNavigation(navigate)
    #else
    navigate()
    #endif
}

public extension View {
    @ViewBuilder
    func cinematicDetailPage(
        isEnabled: Bool, waitsForBackdrop: Bool = false, revealsEpisodesLast: Bool = false
    ) -> some View {
        #if os(tvOS)
        modifier(TVDetailPageTransition(
            isEnabled: isEnabled, waitsForBackdrop: waitsForBackdrop,
            revealsEpisodesLast: revealsEpisodesLast
        ))
        #else
        self
        #endif
    }

    @ViewBuilder
    func detailEntranceStage(_ stage: DetailEntranceStage) -> some View {
        #if os(tvOS)
        modifier(TVDetailStageReveal(stage: stage))
        #else
        self
        #endif
    }
}

#if os(tvOS)
import CoreNetworking
import Observation
import UIKit

public struct DetailTransitionArtworkLayout: Equatable {
    public let frame: CGRect
    public let intrinsicSize: CGSize

    public init(frame: CGRect, intrinsicSize: CGSize) {
        self.frame = frame
        self.intrinsicSize = intrinsicSize
    }
}

public extension View {
    /// Measure the clipped artwork slot, not an aspect-fill image overflowing it.
    func recordDetailTransitionArtwork(_ reference: DetailTransitionSourceReference) -> some View {
        modifier(DetailArtworkTracking(reference: reference))
    }
}

private struct DetailArtworkTracking: ViewModifier {
    let reference: DetailTransitionSourceReference
    @Environment(\.plozzCardFocusStyle) private var style

    func body(content: Content) -> some View {
        if style.usesSystemEffect {
            content.background { NativeArtworkAnchor(reference: reference) }
        } else {
            content.onGeometryChange(for: DetailTransitionArtworkLayout.self) {
                DetailTransitionArtworkLayout(
                    frame: $0.frame(in: .named(reference.coordinateSpace)), intrinsicSize: $0.size
                )
            } action: {
                reference.recordArtworkFrame($0.frame, intrinsicSize: $0.intrinsicSize)
            }
        }
    }
}

private struct NativeArtworkAnchor: UIViewRepresentable {
    let reference: DetailTransitionSourceReference

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        reference.nativeArtworkView = view
    }
}

struct DetailTransitionSourceGeometry: Equatable {
    let frame: CGRect
    let cornerRadius: CGFloat
}

@MainActor
protocol DetailTransitionFocusRequesting: AnyObject {
    func requestFocus() -> Bool
}

/// Weak, per-card geometry. Images are captured only when the card is selected.
@MainActor
public final class DetailTransitionSourceReference {
    public let coordinateSpace = UUID()
    weak var view: UIView?
    weak var nativeArtworkView: UIView?
    var itemKey = ""
    var cornerRadius: CGFloat = 0
    var isFocused: Bool?
    weak var focusRequester: (any DetailTransitionFocusRequesting)?
    private var artworkFrame: CGRect?
    private var intrinsicArtworkSize: CGSize?

    public init() {}

    public func recordArtworkFrame(_ frame: CGRect, intrinsicSize: CGSize? = nil) {
        artworkFrame = frame
        intrinsicArtworkSize = intrinsicSize
    }

    public func prepare(for item: MediaItem) {
        guard let window = view?.window else { return }
        DetailTransitionNavigation.prepare(for: item, in: window, source: self)
    }

    func visibleFrame(in window: UIWindow) -> CGRect? {
        guard let view = nativeArtworkView ?? view, view.window === window, !view.bounds.isEmpty else { return nil }
        var ancestor: UIView? = view
        while let current = ancestor {
            guard !current.isHidden, current.alpha > 0 else { return nil }
            ancestor = current.superview
        }
        let frame: CGRect
        if nativeArtworkView != nil {
            guard let projected = NativeFocusProjection.frame(of: view.layer, in: window.layer) else {
                PlozzLog.app.debug("Native artwork projection is unavailable for the detail transition")
                return nil
            }
            frame = projected
        } else {
            frame = view.convert(nativeArtworkView == nil ? artworkFrame ?? view.bounds : view.bounds, to: window)
        }
        guard frame.width > 1, frame.height > 1, !frame.isInfinite, !frame.isNull,
              window.bounds.intersection(frame).width >= frame.width * 0.9,
              window.bounds.intersection(frame).height >= frame.height * 0.9 else { return nil }
        return frame
    }

    func geometry(in window: UIWindow) -> DetailTransitionSourceGeometry? {
        guard let frame = visibleFrame(in: window) else { return nil }
        let unscaledWidth = nativeArtworkView?.bounds.width ?? intrinsicArtworkSize?.width ?? view?.bounds.width ?? frame.width
        let scale = unscaledWidth > 0 ? frame.width / unscaledWidth : 1
        return DetailTransitionSourceGeometry(frame: frame, cornerRadius: cornerRadius * scale)
    }

    func restoreFocus(in window: UIWindow, preferred: (any UIFocusEnvironment)?) {
        guard let frame = visibleFrame(in: window), let view else { return }
        let system = UIFocusSystem.focusSystem(for: window)
        var nativeOwner = nativeArtworkView?.superview
        while let current = nativeOwner {
            if current.canBecomeFocused {
                system?.requestFocusUpdate(to: current)
                system?.updateFocusIfNeeded()
                let focused = system?.focusedItem.flatMap { TVNavigationExitProtectionFocus.containingView(of: $0) }
                if current.isFocused || focused?.isDescendant(of: current) == true { return }
                // A restored SwiftUI scope can reject the native request; its
                // explicit focus binding below must still get a chance.
                break
            }
            nativeOwner = current.superview
        }
        if focusRequester?.requestFocus() == true {
            var responder: UIResponder? = view
            while let current = responder {
                if let controller = current as? UIViewController {
                    controller.setNeedsFocusUpdate()
                    system?.requestFocusUpdate(to: controller)
                    system?.updateFocusIfNeeded()
                    window.rootViewController?.setNeedsFocusUpdate()
                    window.rootViewController?.updateFocusIfNeeded()
                    return
                }

                responder = current.next
            }
        }
        if let preferred = preferred as? any UIFocusItem, preferred.canBecomeFocused,
           TVNavigationExitProtectionFocus.containingView(of: preferred)?.window === window {
            system?.requestFocusUpdate(to: preferred)
            system?.updateFocusIfNeeded()
            return
        }
        // Lazy rows may recreate the original focus proxy while details are open.
        // Resolve the current card by its live artwork rectangle, not an old index.
        var ancestor: UIView? = view
        while let current = ancestor {
            if let container = current.focusItemContainer {
                let query = container.coordinateSpace.convert(frame, from: window)
                let target = container.focusItems(in: query).first { item in
                    guard item.canBecomeFocused else { return false }
                    let candidate = window.convert(item.frame, from: container.coordinateSpace)
                    let overlap = candidate.intersection(frame)
                    return !overlap.isNull && candidate.width <= frame.width * 1.5
                        && candidate.height <= frame.height * 2
                        && overlap.width * overlap.height >= frame.width * frame.height * 0.8
                }
                if let target {
                    system?.requestFocusUpdate(to: target)
                    system?.updateFocusIfNeeded()
                    return
                }
            }
            ancestor = current.superview
        }
    }
}

public struct DetailTransitionSourceAnchor: UIViewRepresentable {
    private let reference: DetailTransitionSourceReference
    private let itemKey: String
    private let cornerRadius: CGFloat
    private let isFocused: Bool?
    private let focus: FocusState<Bool>.Binding?

    public init(
        reference: DetailTransitionSourceReference, itemKey: String,
        cornerRadius: CGFloat, isFocused: Bool? = nil, focus: FocusState<Bool>.Binding? = nil
    ) {
        self.reference = reference
        self.itemKey = itemKey
        self.cornerRadius = cornerRadius
        self.isFocused = isFocused
        self.focus = focus
    }

    public final class Coordinator: DetailTransitionFocusRequesting {
        var focus: FocusState<Bool>.Binding?

        func requestFocus() -> Bool {
            guard let focus else { return false }
            focus.wrappedValue = true
            return true
        }
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeUIView(context: Context) -> UIView {
        let view = DetailTransitionSourceView()
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        return view
    }

    public func updateUIView(_ view: UIView, context: Context) {
        reference.view = view
        reference.itemKey = itemKey
        reference.cornerRadius = cornerRadius
        reference.isFocused = isFocused
        context.coordinator.focus = focus
        reference.focusRequester = context.coordinator
        (view as? DetailTransitionSourceView)?.reference = reference
    }
}

final class DetailTransitionSourceView: UIView {
    weak var reference: DetailTransitionSourceReference?
}

@MainActor
public enum DetailTransitionNavigation {
    private static var pending: [ObjectIdentifier: PendingDetailEntrance] = [:]
    private static var suppressed: [ObjectIdentifier: UUID] = [:]
    private static var restoring: [ObjectIdentifier: (token: UUID, session: TVDetailEntranceSession)] = [:]
    private static let inputEpochs = NSMapTable<UIWindow, NSNumber>.weakToStrongObjects()
    private static let chromeRegistrations = NSMapTable<UIWindow, ChromeRegistration>.weakToStrongObjects()

    private final class ChromeRegistration {
        weak var chrome: NavigationChromeModel?
        let token: UUID
        init(chrome: NavigationChromeModel, token: UUID) {
            self.chrome = chrome
            self.token = token
        }
    }

    static func registerChrome(_ chrome: NavigationChromeModel, in window: UIWindow, token: UUID) {
        let existing = chromeRegistrations.object(forKey: window)
        if existing?.token != token || existing?.chrome !== chrome {
            chromeRegistrations.setObject(ChromeRegistration(chrome: chrome, token: token), forKey: window)
        }
        refreshChromeInput(in: window)
    }

    static func unregisterChrome(in window: UIWindow, token: UUID) {
        guard let registration = chromeRegistrations.object(forKey: window), registration.token == token else { return }
        chromeRegistrations.removeObject(forKey: window)
        registration.chrome?.updateTransitionInput(suppressesFocus: false, hidesRail: false)
    }

    static func chromeModel(in window: UIWindow) -> NavigationChromeModel? {
        chromeRegistrations.object(forKey: window)?.chrome
    }

    static func refreshChromeInput(in window: UIWindow) {
        let guards = (window.gestureRecognizers ?? []).compactMap { $0 as? DetailTransitionInputGuard }
            .filter(\.isEnabled)
        chromeModel(in: window)?.updateTransitionInput(
            suppressesFocus: !guards.isEmpty,
            hidesRail: guards.contains { $0.phase == .opening }
        )
    }

    public static var isNavigationInputSuppressed: Bool {
        activeWindow.map { navigationInputEpoch(in: $0) == nil } ?? false
    }

    /// Passive navigation observers must reject consumed input as well as
    /// checks queued before a transition changed the window's focus scope.
    public static func navigationInputEpoch(in view: UIView?) -> UInt64? {
        guard let window = (view as? UIWindow) ?? view?.window else { return nil }
        guard !(window.gestureRecognizers ?? []).contains(where: {
            $0 is DetailTransitionInputGuard && $0.isEnabled
        }) else { return nil }
        return inputEpochs.object(forKey: window)?.uint64Value ?? 0
    }

    static func installInputGuard(
        in window: UIWindow, phase: DetailTransitionInputGuard.Phase = .opening
    ) -> DetailTransitionInputGuard {
        let epoch = (inputEpochs.object(forKey: window)?.uint64Value ?? 0) &+ 1
        inputEpochs.setObject(NSNumber(value: epoch), forKey: window)
        let guardView = DetailTransitionInputGuard(phase: phase)
        window.addGestureRecognizer(guardView)
        refreshChromeInput(in: window)
        return guardView
    }

    public static var isRestoringSourcePage: Bool {
        activeWindow.map { restoring[ObjectIdentifier($0)] != nil } ?? false
    }

    static func beginSourceRestore(in window: UIWindow, token: UUID, session: TVDetailEntranceSession) {
        let key = ObjectIdentifier(window)
        if let previous = restoring[key], previous.token != token { previous.session.finishImmediately() }
        // The dismissed SwiftUI page can die before the artwork animation ends.
        restoring[key] = (token, session)
    }

    static func endSourceRestore(token: UUID) {
        if let key = restoring.first(where: { $0.value.token == token })?.key {
            restoring.removeValue(forKey: key)
        }
    }

    static func performNavigation(_ navigate: () -> Void) {
        guard let window = activeWindow, pending[ObjectIdentifier(window)] != nil else {
            navigate()
            return
        }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction, navigate)
    }

    private static var activeWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows).first(where: \.isKeyWindow)
    }

    /// The central routers call this too, covering More Info and non-card links.
    public static func prepare(for item: MediaItem, artworkSnapshot: UIImage? = nil) {
        guard let window = activeWindow else { return }
        prepare(for: item, in: window, source: nil, artworkSnapshot: artworkSnapshot)
    }

    /// A system Play route may push details underneath its player, without an entrance.
    public static func suppressNextEntranceForPlayback() {
        guard let window = activeWindow else { return }
        suppressNextEntrance(in: window)
    }

    static func suppressNextEntrance(in window: UIWindow) {
        let key = ObjectIdentifier(window)
        let token = UUID()
        pending.removeValue(forKey: key)?.discard()
        suppressed[key] = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            if suppressed[key] == token { suppressed.removeValue(forKey: key) }
        }
    }

    static func consumesSuppression(in window: UIWindow) -> Bool {
        suppressed.removeValue(forKey: ObjectIdentifier(window)) != nil
    }

    static func prepare(
        for item: MediaItem, in window: UIWindow, source: DetailTransitionSourceReference?,
        artworkSnapshot: UIImage? = nil
    ) {
        guard !UIAccessibility.isReduceMotionEnabled,
              [.movie, .series, .episode, .season].contains(item.kind) else { return }
        let key = ObjectIdentifier(window)
        guard suppressed[key] == nil else { return }
        if pending[key]?.itemKey == item.stablePresentationID { return }
        pending.removeValue(forKey: key)?.discard()
        let screen = artworkSnapshot.map(DetailTransitionSurface.init(image:))
            ?? DetailTransitionSnapshot.surface(of: window)
        let geometry = source?.geometry(in: window)
        let frame = geometry?.frame
        let card = frame.map { DetailTransitionSnapshot.surface(of: window, frame: $0) }
        let entry = PendingDetailEntrance(
            window: window, itemKey: item.stablePresentationID,
            source: card == nil ? nil : source, card: card, sourceFrame: frame,
            sourceCornerRadius: geometry?.cornerRadius ?? 0, screen: screen
        )
        pending[key] = entry
        entry.overlay.destination.image = cachedDestinationArtwork(for: item)
        entry.start()
        // A direct-play route must never leave a prepared navigation cover behind.
        entry.expiry = Task { @MainActor [weak entry] in
            do { try await Task.sleep(for: .seconds(1)) }
            catch is CancellationError { return }
            catch {
                PlozzLog.app.error("Detail transition expiry failed: \(String(describing: error))")
            }
            guard let entry, pending[key] === entry else { return }
            pending.removeValue(forKey: key)?.discard()
        }
    }

    static func take(in window: UIWindow) -> PendingDetailEntrance? {
        let result = pending.removeValue(forKey: ObjectIdentifier(window))
        result?.expiry?.cancel()
        result?.expiry = nil
        return result
    }

    static func backdropTask(matching key: String) -> Task<FirstPaintArtwork?, Never>? {
        guard let window = activeWindow, let request = pending[ObjectIdentifier(window)]?.backdropRequest,
              request.key == key else { return nil }
        return request.task
    }

    static func preloadBackdrop(for item: MediaItem) {
        guard item.kind == .movie || item.kind == .series,
              let window = activeWindow, let entry = pending[ObjectIdentifier(window)],
              entry.itemKey == item.stablePresentationID,
              entry.overlay.destination.image == nil, entry.backdropRequest == nil else { return }
        guard let request = DetailBackdropArtworkRequest(item: item) else { return }
        entry.backdropRequest = request
        entry.backdropDelivery = Task { @MainActor [weak entry] in
            guard let artwork = await request.task.value, !Task.isCancelled else { return }
            entry?.overlay.destination.image = artwork.image
            entry?.start()
        }
    }

    private static func cachedDestinationArtwork(for item: MediaItem) -> UIImage? {
        guard item.kind == .movie || item.kind == .series else { return nil }
        let source = DetailBackdropArtworkSource(item: item)
        if let prepared = ArtworkSeedMemo.prepared(for: source.key, variant: .heroBackdrop)
            ?? ArtworkSeedMemo.prepared(for: source.previewKey, variant: .heroPreview) {
            return prepared.image
        }
        guard !source.settings.preferOnlineArtwork else { return nil }
        for reference in source.references {
            if let image = ArtworkImageCache.shared.cachedImage(for: reference, variant: .heroBackdrop)
                ?? ArtworkImageCache.shared.cachedImage(for: reference, variant: .heroPreview),
               image.size.height > 0, image.size.width / image.size.height <= 3 {
                return image
            }
        }
        return nil
    }
}

@MainActor
final class PendingDetailEntrance {
    let itemKey: String
    let source: DetailTransitionSourceReference?
    let sourceFrame: CGRect?
    let sourceCornerRadius: CGFloat
    let card: DetailTransitionSurface?
    weak var focusedItem: (any UIFocusEnvironment)?
    let overlay: DetailTransitionOverlay
    let inputGuard: DetailTransitionInputGuard
    var expiry: Task<Void, Never>?
    var animator: UIViewPropertyAnimator?
    private(set) var landedAt: CFTimeInterval?
    private var hasStarted = false
    var onLanded: (() -> Void)?
    let windowSize: CGSize
    let scrollPositions: [DetailTransitionScrollPosition]
    var backdropRequest: DetailBackdropArtworkRequest?
    var backdropDelivery: Task<Void, Never>?

    init(
        window: UIWindow, itemKey: String, source: DetailTransitionSourceReference?,
        card: DetailTransitionSurface?, sourceFrame: CGRect?, sourceCornerRadius: CGFloat,
        screen: DetailTransitionSurface
    ) {
        self.itemKey = itemKey
        self.source = source
        self.sourceFrame = sourceFrame
        self.sourceCornerRadius = sourceCornerRadius
        self.card = card
        windowSize = window.bounds.size
        focusedItem = UIFocusSystem.focusSystem(for: window)?.focusedItem
        scrollPositions = DetailTransitionScrollPosition.capture(
            from: source?.view ?? (focusedItem as? any UIFocusItem).flatMap {
                TVNavigationExitProtectionFocus.containingView(of: $0)
            }
        )
        overlay = DetailTransitionOverlay(screen: screen, card: card)
        overlay.frame = window.bounds
        window.addSubview(overlay)
        inputGuard = DetailTransitionNavigation.installInputGuard(in: window)
    }

    func start(allowsMissingArtwork: Bool = false) {
        guard !hasStarted else { return }
        overlay.configureOpening(sourceFrame: sourceFrame, cornerRadius: sourceCornerRadius)
        guard overlay.destination.image != nil || allowsMissingArtwork else { return }
        hasStarted = true
        animator = overlay.animateOpening(duration: DetailEntranceTiming().zoom) { [weak self] in
            guard let self else { return }
            landedAt = CACurrentMediaTime()
            animator = nil
            onLanded?()
        }
        // Submit motion before the router constructs or loads the destination.
        CATransaction.flush()
    }

    func discard() {
        backdropDelivery?.cancel()
        backdropDelivery = nil
        backdropRequest?.cancel()
        backdropRequest = nil
        expiry?.cancel()
        expiry = nil
        animator?.stopAnimation(true)
        animator = nil
        onLanded = nil
        overlay.removeFromSuperview()
        inputGuard.invalidate()
    }
}

@MainActor
struct DetailTransitionScrollPosition {
    weak var view: UIScrollView?
    let offset: CGPoint

    static func capture(from view: UIView?) -> [Self] {
        var result: [Self] = []
        var ancestor = view
        while let current = ancestor {
            if let scroll = current as? UIScrollView {
                result.append(Self(view: scroll, offset: scroll.contentOffset))
            }
            ancestor = current.superview
        }
        return result
    }

    func restore(in window: UIWindow) {
        guard let view, view.window === window else { return }
        view.setContentOffset(offset, animated: false)
    }
}

@MainActor @Observable
public final class TVDetailEntranceSession {
    public private(set) var stage = DetailEntranceStage.artwork
    public private(set) var isClosing = false
    public private(set) var blocksNavigation = true
    /// Retained only for the return transition, never as the detail backdrop.
    private(set) var returnArtwork: DetailTransitionSurface?
    @ObservationIgnored private var returnBackground: DetailTransitionSurface?
    @ObservationIgnored private var destinationArtwork: UIImage?
    public let timing: DetailEntranceTiming
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private weak var window: UIWindow?
    @ObservationIgnored private var source: DetailTransitionSourceReference?
    @ObservationIgnored private var sourceKey: String?
    @ObservationIgnored private weak var returnFocus: (any UIFocusEnvironment)?
    @ObservationIgnored private var overlay: DetailTransitionOverlay?
    @ObservationIgnored private var inputGuard: DetailTransitionInputGuard?
    @ObservationIgnored private var animator: UIViewPropertyAnimator?
    @ObservationIgnored private var sequence: Task<Void, Never>?
    @ObservationIgnored private var earlyDestinationArtwork: UIImage?
    @ObservationIgnored private var opening: PendingDetailEntrance?
    @ObservationIgnored private var activationGeometry: DetailTransitionSourceGeometry?
    @ObservationIgnored private var activationWindowSize: CGSize?
    @ObservationIgnored private var artworkHasLanded = false
    @ObservationIgnored private var waitsForPageAppearance = false
    @ObservationIgnored private var pageIsVisible = false
    @ObservationIgnored private var returnMotionFinished = false
    @ObservationIgnored private var returnNavigationFinished = false
    @ObservationIgnored private var returnHandoffScheduled = false
    @ObservationIgnored private var scrollPositions: [DetailTransitionScrollPosition] = []
    @ObservationIgnored private let restoreToken = UUID()
    @ObservationIgnored private var backdropRequest: DetailBackdropArtworkRequest?
    @ObservationIgnored private var waitsForBackdrop = false
    @ObservationIgnored private var backdropIsResolved = false
    @ObservationIgnored private var backdropIsAvailable = false
    @ObservationIgnored private var backdropResolvedAt: CFTimeInterval?
    @ObservationIgnored private var artworkLandedAt: CFTimeInterval?
    @ObservationIgnored private var pageAppearedAt: CFTimeInterval?
    @ObservationIgnored private var foregroundSequenceStarted = false
    @ObservationIgnored private var revealsEpisodesLast = false
    @ObservationIgnored private weak var navigationChrome: NavigationChromeModel?
    @ObservationIgnored private let chromeToken = UUID()

    public init(timing: DetailEntranceTiming = DetailEntranceTiming()) {
        self.timing = timing
    }

    public func resolvedDestinationArtwork(_ image: UIImage) {
        guard !isClosing else { return }
        destinationArtwork = image
        backdropIsAvailable = true
        backdropIsResolved = true
        if backdropResolvedAt == nil { backdropResolvedAt = CACurrentMediaTime() }
        if !hasStarted {
            earlyDestinationArtwork = image
        } else if let overlay {
            overlay.destination.image = image
        }
        startOpeningIfReady()
        startForegroundIfReady()
    }

    public func resolvedDestinationVideo() {
        guard !isClosing else { return }
        backdropIsAvailable = true
        backdropIsResolved = true
        if backdropResolvedAt == nil { backdropResolvedAt = CACurrentMediaTime() }
        startOpeningIfReady()
        startForegroundIfReady()
    }

    func destinationArtworkUnavailable() {
        guard !isClosing, !backdropIsResolved else { return }
        PlozzLog.app.info("Detail backdrop exhausted its candidates; revealing controls without artwork")
        backdropIsResolved = true
        backdropResolvedAt = CACurrentMediaTime()
        if waitsForBackdrop, !artworkHasLanded {
            finishImmediately()
            return
        }
        startForegroundIfReady()
    }

    func backdropTask(matching key: String) -> Task<FirstPaintArtwork?, Never>? {
        if let backdropRequest, backdropRequest.key == key { return backdropRequest.task }
        return DetailTransitionNavigation.backdropTask(matching: key)
    }

    func bind(to window: UIWindow) {
        self.window = window
    }

    func attach(
        to window: UIWindow, enabled: Bool,
        waitsForPageAppearance: Bool = false, waitsForBackdrop: Bool = false,
        revealsEpisodesLast: Bool = false
    ) {
        self.window = window
        guard !hasStarted else { return }
        self.waitsForPageAppearance = waitsForPageAppearance
        self.waitsForBackdrop = waitsForBackdrop
        self.revealsEpisodesLast = revealsEpisodesLast
        if DetailTransitionNavigation.consumesSuppression(in: window) {
            finishImmediately()
            return
        }
        guard enabled, !UIAccessibility.isReduceMotionEnabled else {
            hasStarted = true
            DetailTransitionNavigation.take(in: window)?.discard()
            stage = .complete
            blocksNavigation = false
            return
        }
        hasStarted = true
        stage = .artwork
        navigationChrome = DetailTransitionNavigation.chromeModel(in: window)
        navigationChrome?.detailAppeared(chromeToken)
        let pending = DetailTransitionNavigation.take(in: window)
        source = pending?.source
        sourceKey = pending?.itemKey
        returnArtwork = pending?.card
        returnBackground = pending?.overlay.screen
        activationGeometry = pending?.sourceFrame.map {
            DetailTransitionSourceGeometry(frame: $0, cornerRadius: pending?.sourceCornerRadius ?? 0)
        }
        activationWindowSize = pending?.windowSize
        returnFocus = pending?.focusedItem
        scrollPositions = pending?.scrollPositions ?? []
        backdropRequest = pending?.backdropRequest
        let cover = pending?.overlay
            ?? DetailTransitionOverlay(screen: DetailTransitionSnapshot.surface(of: window), card: nil)
        cover.frame = window.bounds
        if cover.superview == nil { window.addSubview(cover) }
        overlay = cover
        inputGuard = pending?.inputGuard ?? installInputGuard(in: window)
        cover.destination.image = earlyDestinationArtwork ?? cover.destination.image
        destinationArtwork = cover.destination.image
        earlyDestinationArtwork = nil
        if let pending {
            opening = pending
            pending.onLanded = { [weak self] in self?.land() }
            if pending.landedAt != nil { land() }
        } else {
            cover.configureOpening(sourceFrame: nil, cornerRadius: 0)
        }
        startOpeningIfReady()
    }

    private func startOpeningIfReady() {
        guard !isClosing, !artworkHasLanded, let overlay else { return }
        if waitsForBackdrop, backdropIsResolved, !backdropIsAvailable {
            finishImmediately()
        } else if waitsForBackdrop, backdropIsAvailable, overlay.destination.image == nil {
            land()
        } else if let opening {
            opening.start(allowsMissingArtwork: !waitsForBackdrop)
        } else if animator == nil, overlay.destination.image != nil || !waitsForBackdrop {
            animator = overlay.animateOpening(duration: timing.zoom) { [weak self] in self?.land() }
        }
    }

    private func land() {
        guard !isClosing else { return }
        artworkHasLanded = true
        artworkLandedAt = opening?.landedAt ?? CACurrentMediaTime()
        opening?.onLanded = nil
        opening?.backdropDelivery?.cancel()
        opening = nil
        animator = nil
        startForegroundIfReady()
    }

    func pageAppeared() {
        guard !isClosing else { return }
        pageIsVisible = true
        navigationChrome?.detailAppeared(chromeToken)
        pageAppearedAt = CACurrentMediaTime()
        startForegroundIfReady()
        finishEntranceIfReady()
    }

    func pageDisappeared() {
        pageIsVisible = false
        navigationChrome?.detailDisappeared(chromeToken)
        guard isClosing else { return }
        returnNavigationFinished = true
        finishReturnIfReady()
    }

    private func removeOpeningCoverIfReady() {
        guard artworkHasLanded, !isClosing, !waitsForPageAppearance || pageIsVisible,
              !waitsForBackdrop || backdropIsResolved else { return }
        let cover = overlay
        UIView.animate(withDuration: 0.1, animations: { cover?.alpha = 0 }) { [weak self] _ in
            cover?.removeFromSuperview()
            if self?.overlay === cover { self?.overlay = nil }
        }
    }

    private func startForegroundIfReady() {
        guard artworkHasLanded, !isClosing, !foregroundSequenceStarted,
              !waitsForPageAppearance || pageIsVisible,
              !waitsForBackdrop || backdropIsResolved else { return }
        foregroundSequenceStarted = true
        removeOpeningCoverIfReady()
        let now = CACurrentMediaTime()
        var readyAt = artworkLandedAt ?? now
        if waitsForBackdrop {
            readyAt = max(readyAt, backdropResolvedAt ?? now, pageAppearedAt ?? readyAt)
        }
        let pause = waitsForBackdrop && !backdropIsAvailable
            ? 0 : max(0, timing.artworkPause - (now - readyAt))
        startForegroundSequence(pause: pause)
    }

    private func finishEntranceIfReady() {
        guard stage == .complete, !isClosing, !waitsForPageAppearance || pageIsVisible else { return }
        blocksNavigation = false
        releaseInput()
    }

    private func startForegroundSequence(pause: TimeInterval) {
        sequence = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .seconds(pause))
                stage = .logo
                try await Task.sleep(for: .seconds(timing.stagger))
                stage = .metadata
                try await Task.sleep(for: .seconds(timing.stagger))
                stage = .controls
                try await Task.sleep(for: .seconds(timing.reveal))
                if revealsEpisodesLast {
                    stage = .episodes
                    try await Task.sleep(for: .seconds(timing.reveal))
                }
                stage = .complete
                backdropRequest = nil
                finishEntranceIfReady()
                sequence = nil
            } catch is CancellationError {
                // Disappearance, Reduce Motion, or Back owns the cancellation.
            } catch {
                PlozzLog.app.error("Detail entrance timing failed: \(String(describing: error))")
                finishImmediately()
            }
        }
    }

    /// Pop the real stack under a visual cover; never replace SwiftUI's navigation delegate.
    func close(dismiss: @escaping @MainActor () -> Void) {
        guard !isClosing else { return }
        guard let window, hasStarted, !UIAccessibility.isReduceMotionEnabled else {
            finishImmediately()
            returnArtwork = nil
            returnBackground = nil
            destinationArtwork = nil
            source = nil
            dismiss()
            return
        }
        if let inputGuard {
            inputGuard.setPhase(.returning)
        } else {
            inputGuard = DetailTransitionNavigation.installInputGuard(in: window, phase: .returning)
        }
        isClosing = true
        navigationChrome?.detailDisappeared(chromeToken)
        backdropRequest?.cancel()
        backdropRequest = nil
        returnMotionFinished = false
        returnNavigationFinished = !waitsForPageAppearance
        returnHandoffScheduled = false
        DetailTransitionNavigation.beginSourceRestore(in: window, token: restoreToken, session: self)
        blocksNavigation = true
        sequence?.cancel()
        sequence = nil
        let interrupted = !artworkHasLanded || (waitsForBackdrop && !backdropIsAvailable)
        // Restore the source page immediately. A detail-page snapshot would
        // keep its background visible until the native pop finished.
        let screen = activationWindowSize == window.bounds.size
            ? returnBackground ?? DetailTransitionSurface()
            : DetailTransitionSurface()
        screen.alpha = 1
        opening?.onLanded = nil
        opening?.backdropDelivery?.cancel()
        opening?.animator?.stopAnimation(true)
        opening = nil
        animator?.stopAnimation(true)
        animator = nil
        overlay?.removeFromSuperview()
        let cover = DetailTransitionOverlay(screen: screen, card: returnArtwork)
        cover.frame = window.bounds
        cover.backgroundColor = .clear
        cover.cardContainer.frame = cover.bounds
        cover.destination.image = destinationArtwork
        cover.destination.alpha = destinationArtwork == nil ? 0 : 1
        cover.card.alpha = destinationArtwork == nil ? 1 : 0
        window.addSubview(cover)
        overlay = cover
        // The source is hidden until the native pop, so its visibility is not
        // a prerequisite. Its captured focused shape is already the right target.
        let validSource = source != nil && source?.itemKey == sourceKey
            && activationWindowSize == window.bounds.size
        let target = validSource ? activationGeometry : nil
        let animation = UIViewPropertyAnimator(duration: timing.reverse, curve: .easeInOut)
        if let target, returnArtwork != nil, !interrupted {
            cover.layoutIfNeeded()
            animation.addAnimations {
                cover.cardContainer.frame = target.frame
                cover.cardContainer.layer.cornerRadius = target.cornerRadius
                cover.destination.alpha = 0
                cover.card.alpha = 1
            }
        } else {
            cover.cardContainer.isHidden = interrupted
            animation.addAnimations { cover.cardContainer.alpha = 0 }
        }
        animation.addCompletion { [weak self] position in
            guard let self, isClosing, position == .end else { return }
            returnMotionFinished = true
            finishReturnIfReady()
        }
        animator = animation
        animation.startAnimation()
        CATransaction.flush()
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { dismiss() }
    }

    private func finishReturnIfReady() {
        guard isClosing, returnMotionFinished, returnNavigationFinished,
              !returnHandoffScheduled, let cover = overlay else { return }
        guard let window else {
            finishImmediately()
            return
        }
        returnHandoffScheduled = true
        // Restore only after the source is mounted. Keep its captured page over
        // focus/scroll restoration and the following SwiftUI update, not just
        // until the independent artwork animator happens to finish.
        DispatchQueue.main.async { [self] in
            guard isClosing, overlay === cover else { return }
            UIView.performWithoutAnimation {
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    if activationWindowSize == window.bounds.size {
                        scrollPositions.forEach { $0.restore(in: window) }
                    }
                    window.layoutIfNeeded()
                    if source?.itemKey == sourceKey {
                        source?.restoreFocus(in: window, preferred: returnFocus)
                    }
                    window.layoutIfNeeded()
                }
            }
            DispatchQueue.main.async { [self] in
                guard isClosing, overlay === cover else { return }
                cover.removeFromSuperview()
                overlay = nil
                animator = nil
                releaseInput()
                DetailTransitionNavigation.endSourceRestore(token: restoreToken)
                returnArtwork = nil
                returnBackground = nil
                destinationArtwork = nil
                source = nil
                scrollPositions = []
                activationGeometry = nil
                activationWindowSize = nil
                stage = .complete
                blocksNavigation = false
                sequence = nil
                // The popped page stays hidden for its remaining lifetime.
            }
        }
    }

    func disappeared() {
        navigationChrome?.detailDisappeared(chromeToken)
        guard !isClosing else { return }
        finishImmediately()
    }

    func releaseReturnBackgroundForMemoryPressure() {
        if returnBackground != nil {
            PlozzLog.app.debug("Releasing the detail return backdrop after a memory warning")
            returnBackground = nil
        }
    }

    func finishImmediately() {
        let wasStarted = hasStarted
        hasStarted = true
        foregroundSequenceStarted = true
        backdropRequest?.cancel()
        backdropRequest = nil
        if !wasStarted, let window { DetailTransitionNavigation.take(in: window)?.discard() }
        sequence?.cancel()
        sequence = nil
        opening?.onLanded = nil
        opening?.backdropDelivery?.cancel()
        opening?.animator?.stopAnimation(true)
        opening = nil
        animator?.stopAnimation(true)
        animator = nil
        overlay?.removeFromSuperview()
        overlay = nil
        earlyDestinationArtwork = nil
        DetailTransitionNavigation.endSourceRestore(token: restoreToken)
        releaseInput(force: true)
        stage = .complete
        isClosing = false
        blocksNavigation = false
    }

    private func installInputGuard(in window: UIWindow) -> DetailTransitionInputGuard {
        DetailTransitionNavigation.installInputGuard(in: window)
    }

    private func releaseInput(force: Bool = false) {
        if force { inputGuard?.invalidate() }
        else { inputGuard?.releaseWhenIdle() }
        inputGuard = nil
    }
}

private struct DetailEntranceSessionKey: EnvironmentKey {
    static let defaultValue: TVDetailEntranceSession? = nil
}

public extension EnvironmentValues {
    var detailEntranceSession: TVDetailEntranceSession? {
        get { self[DetailEntranceSessionKey.self] }
        set { self[DetailEntranceSessionKey.self] = newValue }
    }
}

private struct TVDetailPageTransition: ViewModifier {
    let isEnabled: Bool
    let waitsForBackdrop: Bool
    let revealsEpisodesLast: Bool
    @State private var session = TVDetailEntranceSession()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .opacity(session.isClosing ? 0 : 1)
            .animation(nil, value: session.isClosing)
            .environment(\.detailEntranceSession, isEnabled && !reduceMotion ? session : nil)
            .background {
                DetailEntrancePageAnchor(
                    session: session, enabled: isEnabled && !reduceMotion,
                    waitsForBackdrop: waitsForBackdrop, revealsEpisodesLast: revealsEpisodesLast
                )
            }
            .onExitCommand {
                if isEnabled, !reduceMotion { session.close { dismiss() } }
                else { dismiss() }
            }
            .onDisappear { session.disappeared() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                session.releaseReturnBackgroundForMemoryPressure()
            }
            .onChange(of: reduceMotion) { _, reduced in
                if reduced { session.finishImmediately() }
            }
            .onChange(of: isEnabled) { _, enabled in
                if !enabled { session.finishImmediately() }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { session.finishImmediately() }
            }
    }
}

private struct TVDetailStageReveal: ViewModifier {
    let stage: DetailEntranceStage
    @Environment(\.detailEntranceSession) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let visible = reduceMotion
            || (session.map { $0.stage >= stage && !$0.isClosing } ?? true)
        let duration = session?.isClosing == true ? 0.12 : (session?.timing.reveal ?? 0)
        content
            .offset(y: visible ? 0 : 14)
            .mask { Rectangle().padding(-600).opacity(visible ? 1 : 0) }
            .animation(reduceMotion ? nil : .easeOut(duration: duration), value: visible)
    }
}

private struct DetailEntrancePageAnchor: UIViewControllerRepresentable {
    let session: TVDetailEntranceSession
    let enabled: Bool
    let waitsForBackdrop: Bool
    let revealsEpisodesLast: Bool

    final class Coordinator {
        let session: TVDetailEntranceSession
        init(session: TVDetailEntranceSession) { self.session = session }
    }

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeUIViewController(context: Context) -> DetailEntranceController {
        DetailEntranceController()
    }

    func updateUIViewController(_ controller: DetailEntranceController, context: Context) {
        controller.session = session
        let view = controller.anchor
        view.session = session
        view.enabled = enabled
        view.waitsForBackdrop = waitsForBackdrop
        view.revealsEpisodesLast = revealsEpisodesLast
        view.attach()
    }

    static func dismantleUIViewController(_ controller: DetailEntranceController, coordinator: Coordinator) {
        coordinator.session.pageDisappeared()
        coordinator.session.disappeared()
    }
}

private final class DetailEntranceController: UIViewController {
    let anchor = DetailEntranceAnchorView()
    weak var session: TVDetailEntranceSession?

    override func loadView() {
        anchor.isUserInteractionEnabled = false
        view = anchor
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        session?.pageAppeared()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        session?.pageDisappeared()
    }
}

private final class DetailEntranceAnchorView: UIView {
    weak var session: TVDetailEntranceSession?
    var enabled = true
    var waitsForBackdrop = false
    var revealsEpisodesLast = false

    override func didMoveToWindow() {
        super.didMoveToWindow()
        attach()
    }

    func attach() {
        guard let window, let session else { return }
        session.bind(to: window)
        let enabled = enabled
        let waitsForBackdrop = waitsForBackdrop
        let revealsEpisodesLast = revealsEpisodesLast
        DispatchQueue.main.async { [weak self, weak window, weak session] in
            guard self?.window === window, let window else { return }
            session?.attach(
                to: window, enabled: enabled,
                waitsForPageAppearance: true, waitsForBackdrop: waitsForBackdrop,
                revealsEpisodesLast: revealsEpisodesLast
            )
        }
    }
}

@MainActor
final class DetailTransitionOverlay: UIView {
    let screen: DetailTransitionSurface
    let card: DetailTransitionSurface
    let destination = UIImageView()
    let cardContainer = UIView()

    init(screen: DetailTransitionSurface, card: DetailTransitionSurface?) {
        self.screen = screen
        self.card = card ?? DetailTransitionSurface()
        super.init(frame: .zero)
        backgroundColor = .black
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        self.screen.contentMode = .scaleAspectFill
        self.screen.clipsToBounds = true
        self.card.contentMode = .scaleAspectFill
        self.card.clipsToBounds = true
        destination.contentMode = .scaleAspectFill
        destination.clipsToBounds = true
        destination.alpha = 0
        cardContainer.clipsToBounds = true
        cardContainer.layer.cornerCurve = .continuous
        addSubview(self.screen)
        addSubview(cardContainer)
        cardContainer.addSubview(self.card)
        cardContainer.addSubview(destination)
        self.card.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        destination.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        self.card.alpha = 1
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        if screen.superview === self { screen.frame = bounds }
        card.frame = cardContainer.bounds
        destination.frame = cardContainer.bounds
    }

    func configureOpening(sourceFrame: CGRect?, cornerRadius: CGFloat) {
        screen.frame = bounds
        cardContainer.frame = sourceFrame ?? bounds
        cardContainer.layer.cornerRadius = cornerRadius
        card.frame = cardContainer.bounds
        destination.frame = cardContainer.bounds
    }

    func animateOpening(duration: TimeInterval, completion: @escaping () -> Void) -> UIViewPropertyAnimator {
        layoutIfNeeded()
        let animation = UIViewPropertyAnimator(duration: duration, curve: .easeInOut)
        animation.addAnimations {
            self.cardContainer.frame = self.bounds
            self.cardContainer.layer.cornerRadius = 0
        }
        UIView.animateKeyframes(withDuration: duration, delay: 0, options: [.calculationModeLinear]) {
            UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.3) {
                self.card.alpha = 0
                self.screen.alpha = 0
                self.destination.alpha = 1
            }
        }
        animation.addCompletion { position in
            if position == .end { completion() }
        }
        animation.startAnimation()
        return animation
    }
}

/// A render-server snapshot avoids rasterizing the complete Home hierarchy on
/// the main thread. Uniform scaling crops the snapshot instead of stretching it.
@MainActor
final class DetailTransitionSurface: UIView {
    private let capturedView: UIView
    let captureSize: CGSize
    let image: UIImage?

    init() {
        capturedView = UIView()
        captureSize = .zero
        image = nil
        super.init(frame: .zero)
        clipsToBounds = true
    }

    init(image: UIImage) {
        self.image = image
        capturedView = UIImageView(image: image)
        captureSize = image.size
        super.init(frame: .zero)
        clipsToBounds = true
        addSubview(capturedView)
    }

    init(snapshot: UIView, size: CGSize) {
        image = nil
        capturedView = snapshot
        captureSize = size
        super.init(frame: .zero)
        clipsToBounds = true
        addSubview(capturedView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard captureSize.width > 0, captureSize.height > 0 else { return }
        let scale = max(bounds.width / captureSize.width, bounds.height / captureSize.height)
        capturedView.bounds = CGRect(origin: .zero, size: captureSize)
        capturedView.center = CGPoint(x: bounds.midX, y: bounds.midY)
        capturedView.transform = CGAffineTransform(scaleX: scale, y: scale)
    }
}

@MainActor
enum DetailTransitionSnapshot {
    static func surface(of window: UIWindow, frame: CGRect? = nil) -> DetailTransitionSurface {
        let frame = frame ?? window.bounds
        let root = window.rootViewController?.viewIfLoaded ?? window
        let rect = root.convert(frame, from: window)
        if let snapshot = root.resizableSnapshotView(
            from: rect, afterScreenUpdates: false, withCapInsets: .zero
        ) {
            return DetailTransitionSurface(snapshot: snapshot, size: frame.size)
        }
        PlozzLog.app.debug("No rendered transition snapshot; using the neutral surface without blocking navigation")
        let result = DetailTransitionSurface()
        result.backgroundColor = window.backgroundColor ?? .black
        return result
    }

    static func image(of window: UIWindow) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { context in
            if !window.drawHierarchy(in: window.bounds, afterScreenUpdates: false) {
                PlozzLog.app.debug("Detail transition using layer snapshot fallback")
                window.layer.render(in: context.cgContext)
            }
        }
    }

    static func crop(_ image: UIImage, to frame: CGRect) -> UIImage? {
        guard let source = image.cgImage, let cropped = source.cropping(to: frame) else { return nil }
        return UIImage(cgImage: cropped)
    }
}

/// Physical input is discarded while the entrance runs, but Back/Home remain native.
@MainActor
final class DetailTransitionInputGuard: UIGestureRecognizer {
    enum Phase { case opening, returning }
    private(set) var phase: Phase
    private var activePresses: Set<ObjectIdentifier> = []
    private var activeTouches: Set<ObjectIdentifier> = []
    private var releaseRequested = false
    private var removalScheduled = false

    init(phase: Phase = .opening) {
        self.phase = phase
        super.init(target: nil, action: nil)
        allowedPressTypes = [
            UIPress.PressType.upArrow, .downArrow, .leftArrow, .rightArrow,
            .pageUp, .pageDown, .select, .playPause
        ].map { NSNumber(value: $0.rawValue) }
        allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        cancelsTouchesInView = true
        delaysTouchesBegan = true
        name = "Plozz cinematic navigation input"
        NotificationCenter.default.addObserver(
            self, selector: #selector(applicationWillDeactivate),
            name: UIApplication.willResignActiveNotification, object: nil
        )
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func applicationWillDeactivate() { invalidate() }

    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    func releaseWhenIdle() {
        releaseRequested = true
        if activePresses.isEmpty, activeTouches.isEmpty { invalidate() }
    }

    func invalidate() {
        releaseRequested = false
        let window = view as? UIWindow
        view?.removeGestureRecognizer(self)
        if let window { DetailTransitionNavigation.refreshChromeInput(in: window) }
    }

    func setPhase(_ phase: Phase) {
        guard self.phase != phase else { return }
        self.phase = phase
        if let window = view as? UIWindow { DetailTransitionNavigation.refreshChromeInput(in: window) }
    }

    private func finishInputIfIdle() {
        guard activePresses.isEmpty, activeTouches.isEmpty else { return }
        state = .ended
        guard releaseRequested, !removalScheduled else { return }
        removalScheduled = true
        // Keep suppression visible to passive observers handling this same
        // release event, including a swipe that began before visual completion.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            removalScheduled = false
            guard releaseRequested, activePresses.isEmpty, activeTouches.isEmpty else { return }
            invalidate()
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        let blocked = presses.filter { allowedPressTypes.contains(NSNumber(value: $0.type.rawValue)) }
        guard !blocked.isEmpty else { return }
        activePresses.formUnion(blocked.map(ObjectIdentifier.init))
        state = .began
    }
    override func pressesChanged(_ presses: Set<UIPress>, with event: UIPressesEvent) {}
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        let identifiers = Set(presses.map(ObjectIdentifier.init))
        guard !activePresses.isDisjoint(with: identifiers) else { return }
        activePresses.subtract(identifiers)
        finishInputIfIdle()
    }
    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        let identifiers = Set(presses.map(ObjectIdentifier.init))
        guard !activePresses.isDisjoint(with: identifiers) else { return }
        activePresses.subtract(identifiers)
        finishInputIfIdle()
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        activeTouches.formUnion(touches.map(ObjectIdentifier.init))
        state = .began
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {}
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        let identifiers = Set(touches.map(ObjectIdentifier.init))
        guard !activeTouches.isDisjoint(with: identifiers) else { return }
        activeTouches.subtract(identifiers)
        finishInputIfIdle()
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        let identifiers = Set(touches.map(ObjectIdentifier.init))
        guard !activeTouches.isDisjoint(with: identifiers) else { return }
        activeTouches.subtract(identifiers)
        finishInputIfIdle()
    }
}
#endif
