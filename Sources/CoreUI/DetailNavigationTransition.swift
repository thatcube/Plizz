import CoreModels
import Foundation
import SwiftUI

public enum DetailEntranceStage: Int, Comparable, Sendable {
    case artwork, logo, metadata, controls, complete

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

public extension View {
    @ViewBuilder
    func cinematicDetailPage(isEnabled: Bool) -> some View {
        #if os(tvOS)
        modifier(TVDetailPageTransition(isEnabled: isEnabled))
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

/// Weak, per-card geometry. Images are captured only when the card is selected.
@MainActor
public final class DetailTransitionSourceReference {
    public let coordinateSpace = UUID()
    weak var view: UIView?
    var itemKey = ""
    var cornerRadius: CGFloat = 0
    private var artworkFrame: CGRect?

    public init() {}

    public func recordArtworkFrame(_ frame: CGRect) {
        artworkFrame = frame
    }

    public func prepare(for item: MediaItem) {
        guard let window = view?.window else { return }
        DetailTransitionNavigation.prepare(for: item, in: window, source: self)
    }

    func visibleFrame(in window: UIWindow) -> CGRect? {
        guard let view, view.window === window, !view.bounds.isEmpty else { return nil }
        var ancestor: UIView? = view
        while let current = ancestor {
            guard !current.isHidden, current.alpha > 0 else { return nil }
            ancestor = current.superview
        }
        let frame = view.convert(artworkFrame ?? view.bounds, to: window)
        guard frame.width > 1, frame.height > 1, !frame.isInfinite, !frame.isNull,
              window.bounds.intersection(frame).width >= frame.width * 0.9,
              window.bounds.intersection(frame).height >= frame.height * 0.9 else { return nil }
        return frame
    }

    func restoreFocus(in window: UIWindow, preferred: (any UIFocusEnvironment)?) {
        guard let frame = visibleFrame(in: window), let view else { return }
        let system = UIFocusSystem.focusSystem(for: window)
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

    public init(reference: DetailTransitionSourceReference, itemKey: String, cornerRadius: CGFloat) {
        self.reference = reference
        self.itemKey = itemKey
        self.cornerRadius = cornerRadius
    }

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
        let screen = artworkSnapshot ?? DetailTransitionSnapshot.image(of: window)
        let frame = source?.visibleFrame(in: window)
        let card = frame.flatMap { DetailTransitionSnapshot.crop(screen, to: $0) }
        let entry = PendingDetailEntrance(
            window: window, itemKey: item.stablePresentationID,
            source: card == nil ? nil : source, cardImage: card, sourceFrame: frame, screen: screen
        )
        pending[key] = entry
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
}

@MainActor
final class PendingDetailEntrance {
    let itemKey: String
    let source: DetailTransitionSourceReference?
    let sourceFrame: CGRect?
    let cardImage: UIImage?
    weak var focusedItem: (any UIFocusEnvironment)?
    let overlay: DetailTransitionOverlay
    let inputGuard: DetailTransitionInputGuard
    var expiry: Task<Void, Never>?

    init(
        window: UIWindow, itemKey: String, source: DetailTransitionSourceReference?,
        cardImage: UIImage?, sourceFrame: CGRect?, screen: UIImage
    ) {
        self.itemKey = itemKey
        self.source = source
        self.sourceFrame = sourceFrame
        self.cardImage = cardImage
        focusedItem = UIFocusSystem.focusSystem(for: window)?.focusedItem
        overlay = DetailTransitionOverlay(screen: screen, card: cardImage)
        overlay.frame = window.bounds
        window.addSubview(overlay)
        inputGuard = DetailTransitionInputGuard()
        window.addGestureRecognizer(inputGuard)
    }

    func discard() {
        expiry?.cancel()
        expiry = nil
        overlay.removeFromSuperview()
        inputGuard.view?.removeGestureRecognizer(inputGuard)
    }
}

@MainActor @Observable
public final class TVDetailEntranceSession {
    public private(set) var stage = DetailEntranceStage.artwork
    public private(set) var isClosing = false
    public private(set) var fallbackArtwork: UIImage?
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

    public init(timing: DetailEntranceTiming = DetailEntranceTiming()) {
        self.timing = timing
    }

    public var blocksNavigation: Bool { stage != .complete || isClosing }

    func bind(to window: UIWindow) {
        self.window = window
    }

    func attach(to window: UIWindow, enabled: Bool) {
        self.window = window
        guard !hasStarted else { return }
        if DetailTransitionNavigation.consumesSuppression(in: window) {
            finishImmediately()
            return
        }
        guard enabled, !UIAccessibility.isReduceMotionEnabled else {
            hasStarted = true
            DetailTransitionNavigation.take(in: window)?.discard()
            stage = .complete
            return
        }
        hasStarted = true
        stage = .artwork
        let pending = DetailTransitionNavigation.take(in: window)
        source = pending?.source
        sourceKey = source?.itemKey
        fallbackArtwork = pending?.cardImage
        returnFocus = pending?.focusedItem
        let cover = pending?.overlay
            ?? DetailTransitionOverlay(screen: DetailTransitionSnapshot.image(of: window), card: nil)
        cover.frame = window.bounds
        if cover.superview == nil { window.addSubview(cover) }
        overlay = cover
        inputGuard = pending?.inputGuard ?? installInputGuard(in: window)
        cover.configureOpening(
            sourceFrame: pending?.sourceFrame,
            cornerRadius: source?.cornerRadius ?? 0
        )
        let animation = UIViewPropertyAnimator(duration: timing.zoom, curve: .easeInOut)
        animation.addAnimations {
            cover.cardContainer.frame = cover.bounds
            cover.cardContainer.layer.cornerRadius = 0
            cover.screen.alpha = 0
        }
        animation.addAnimations({ cover.card.alpha = 0 }, delayFactor: 0.4)
        animation.addCompletion { [weak self, weak cover] position in
            guard let self, !self.isClosing, position == .end else { return }
            cover?.removeFromSuperview()
            self.overlay = nil
            self.animator = nil
            self.startForegroundSequence()
        }
        animator = animation
        animation.startAnimation()
    }

    private func startForegroundSequence() {
        sequence = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .seconds(timing.artworkPause))
                stage = .logo
                try await Task.sleep(for: .seconds(timing.stagger))
                stage = .metadata
                try await Task.sleep(for: .seconds(timing.stagger))
                stage = .controls
                try await Task.sleep(for: .seconds(timing.reveal))
                stage = .complete
                releaseInput()
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
            fallbackArtwork = nil
            source = nil
            dismiss()
            return
        }
        isClosing = true
        sequence?.cancel()
        sequence = nil
        let interrupted = overlay != nil
        let screen = DetailTransitionSnapshot.image(of: window)
        animator?.stopAnimation(true)
        animator = nil
        overlay?.removeFromSuperview()
        let cover = DetailTransitionOverlay(screen: screen, card: fallbackArtwork)
        cover.frame = window.bounds
        cover.cardContainer.frame = cover.bounds
        cover.card.alpha = 0
        window.addSubview(cover)
        overlay = cover
        if inputGuard == nil { inputGuard = installInputGuard(in: window) }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { dismiss() }
        sequence = Task { @MainActor [self] in
            // Let the popped stack restore its source's real, current geometry.
            await Task.yield()
            window.layoutIfNeeded()
            let target = source?.itemKey == sourceKey ? source?.visibleFrame(in: window) : nil
            let animation = UIViewPropertyAnimator(duration: timing.reverse, curve: .easeInOut)
            if let target, fallbackArtwork != nil, !interrupted {
                // Both layers travel together, crossfading rather than stretching either image.
                cover.cardContainer.addSubview(cover.screen)
                cover.screen.frame = cover.cardContainer.bounds
                cover.screen.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                animation.addAnimations {
                    cover.cardContainer.frame = target
                    cover.cardContainer.layer.cornerRadius = self.source?.cornerRadius ?? 0
                    cover.screen.alpha = 0
                    cover.card.alpha = 1
                }
            } else {
                animation.addAnimations { cover.alpha = 0 }
            }
            animation.addCompletion { [self, cover] _ in
                cover.removeFromSuperview()
                overlay = nil
                animator = nil
                releaseInput()
                if source?.itemKey == sourceKey {
                    source?.restoreFocus(in: window, preferred: returnFocus)
                }
                fallbackArtwork = nil
                source = nil
                stage = .complete
                isClosing = false
                sequence = nil
            }
            animator = animation
            animation.startAnimation()
        }
    }

    func disappeared() {
        guard !isClosing else { return }
        finishImmediately()
    }

    func finishImmediately() {
        let wasStarted = hasStarted
        hasStarted = true
        if !wasStarted, let window { DetailTransitionNavigation.take(in: window)?.discard() }
        sequence?.cancel()
        sequence = nil
        animator?.stopAnimation(true)
        animator = nil
        overlay?.removeFromSuperview()
        overlay = nil
        releaseInput()
        stage = .complete
        isClosing = false
    }

    private func installInputGuard(in window: UIWindow) -> DetailTransitionInputGuard {
        let guardView = DetailTransitionInputGuard()
        window.addGestureRecognizer(guardView)
        return guardView
    }

    private func releaseInput() {
        if let inputGuard { inputGuard.view?.removeGestureRecognizer(inputGuard) }
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
    @State private var session = TVDetailEntranceSession()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .environment(\.detailEntranceSession, isEnabled && !reduceMotion ? session : nil)
            .background {
                DetailEntrancePageAnchor(session: session, enabled: isEnabled && !reduceMotion)
            }
            .onExitCommand {
                if isEnabled, !reduceMotion { session.close { dismiss() } }
                else { dismiss() }
            }
            .onDisappear { session.disappeared() }
            .onChange(of: reduceMotion) { _, reduced in
                if reduced { session.finishImmediately() }
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
            .accessibilityHidden(!reduceMotion && session?.blocksNavigation == true)
    }
}

private struct DetailEntrancePageAnchor: UIViewRepresentable {
    let session: TVDetailEntranceSession
    let enabled: Bool

    final class Coordinator {
        let session: TVDetailEntranceSession
        init(session: TVDetailEntranceSession) { self.session = session }
    }

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeUIView(context: Context) -> DetailEntranceAnchorView {
        let view = DetailEntranceAnchorView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: DetailEntranceAnchorView, context: Context) {
        view.session = session
        view.enabled = enabled
        view.attach()
    }

    static func dismantleUIView(_ view: DetailEntranceAnchorView, coordinator: Coordinator) {
        coordinator.session.disappeared()
    }
}

private final class DetailEntranceAnchorView: UIView {
    weak var session: TVDetailEntranceSession?
    var enabled = true

    override func didMoveToWindow() {
        super.didMoveToWindow()
        attach()
    }

    func attach() {
        guard let window, let session else { return }
        session.bind(to: window)
        let enabled = enabled
        DispatchQueue.main.async { [weak self, weak window, weak session] in
            guard self?.window === window, let window else { return }
            session?.attach(to: window, enabled: enabled)
        }
    }
}

@MainActor
final class DetailTransitionOverlay: UIView {
    let screen: UIImageView
    let card: UIImageView
    let cardContainer = UIView()

    init(screen: UIImage, card: UIImage?) {
        self.screen = UIImageView(image: screen)
        self.card = UIImageView(image: card)
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        self.screen.contentMode = .scaleAspectFill
        self.screen.clipsToBounds = true
        self.card.contentMode = .scaleAspectFill
        self.card.clipsToBounds = true
        cardContainer.clipsToBounds = true
        addSubview(self.screen)
        addSubview(cardContainer)
        cardContainer.addSubview(self.card)
        self.card.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        if screen.superview === self { screen.frame = bounds }
        card.frame = cardContainer.bounds
    }

    func configureOpening(sourceFrame: CGRect?, cornerRadius: CGFloat) {
        screen.frame = bounds
        cardContainer.frame = sourceFrame ?? bounds
        cardContainer.layer.cornerRadius = cornerRadius
        card.frame = cardContainer.bounds
    }
}

@MainActor
enum DetailTransitionSnapshot {
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
    init() {
        super.init(target: nil, action: nil)
        allowedPressTypes = [
            UIPress.PressType.upArrow, .downArrow, .leftArrow, .rightArrow, .select, .playPause
        ].map { NSNumber(value: $0.rawValue) }
        allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        cancelsTouchesInView = true
        delaysTouchesBegan = true
    }

    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        state = presses.contains { $0.type == .menu } ? .failed : .began
    }
    override func pressesChanged(_ presses: Set<UIPress>, with event: UIPressesEvent) {}
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent) { state = .ended }
    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent) { state = .cancelled }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) { state = .began }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {}
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { state = .ended }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { state = .cancelled }
}
#endif
