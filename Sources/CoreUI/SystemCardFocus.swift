import CoreModels
import CoreNetworking
import SwiftUI

/// Native focus notifications update visual state, not FocusState commands.
@propertyWrapper
public struct PlozzCardFocus: DynamicProperty {
    @FocusState private var requested: Bool
    @State private var observed = false
    @Environment(\.plozzCardFocusStyle) private var style

    public init() {}

    public var wrappedValue: Bool {
        get {
            #if os(tvOS)
            style.usesSystemEffect ? observed : requested
            #else
            requested
            #endif
        }
        nonmutating set { requested = newValue }
    }

    public var projectedValue: Binding {
        Binding(focusState: $requested, observed: $observed)
    }

    public struct Binding {
        public let focusState: FocusState<Bool>.Binding
        let observed: SwiftUI.Binding<Bool>
    }
}

public extension View {
    /// Apply to the focus owner; the projection itself belongs to its artwork.
    func plozzCardFocusEffect() -> some View {
        modifier(CardFocusEffectAvailability())
    }

    /// Native tvOS projection, outside the visual's clip/rasterization boundary.
    func plozzSystemCardProjection(cornerRadius: CGFloat) -> some View {
        #if os(tvOS)
        modifier(SystemCardProjection(cornerRadius: cornerRadius))
        #else
        self
        #endif
    }

    func plozzRestingCardShadow(isFocused: Bool) -> some View {
        modifier(RestingCardShadow(isFocused: isFocused))
    }

    func plozzCardFocusButtonStyle<Style: ButtonStyle>(
        _ fallback: Style, cornerRadius: CGFloat, contentSuppliesProjection: Bool = false
    ) -> some View {
        modifier(CardFocusButtonStyle(
            fallback: fallback, cornerRadius: cornerRadius,
            contentSuppliesProjection: contentSuppliesProjection
        ))
    }
}

#if os(tvOS)
import UIKit

struct SystemCardFocusContext {
    var requestsFocus: Bool
    var isEnabled: Bool
    var onFocus: (Bool) -> Void
    var action: () -> Void
}

private struct SystemCardFocusContextKey: EnvironmentKey {
    static let defaultValue: SystemCardFocusContext? = nil
}

extension EnvironmentValues {
    var systemCardFocusContext: SystemCardFocusContext? {
        get { self[SystemCardFocusContextKey.self] }
        set { self[SystemCardFocusContextKey.self] = newValue }
    }
}

private struct SystemCardProjection: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.systemCardFocusContext) private var focusContext

    func body(content: Content) -> some View {
        if let focusContext {
            SystemCardRepresentable(content: content, cornerRadius: cornerRadius, focusContext: focusContext)
        } else {
            content
        }
    }
}

private struct SystemCardRepresentable<Content: View>: UIViewRepresentable {
    let content: Content
    let cornerRadius: CGFloat
    let focusContext: SystemCardFocusContext

    func makeUIView(context: Context) -> SystemCardControl {
        SystemCardControl(configuration: configuration(in: context))
    }

    func updateUIView(_ view: SystemCardControl, context: Context) {
        view.hostedContent.configuration = configuration(in: context)
        view.isEnabled = focusContext.isEnabled
        view.cornerRadius = cornerRadius
        view.surfaceColor = UIColor(context.environment.themePalette.raised.fill)
        view.setNeedsLayout()
        view.updateFocusContext(focusContext)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: SystemCardControl, context: Context) -> CGSize? {
        let size = uiView.hostedContent.sizeThatFits(CGSize(
            width: proposal.width ?? UIView.layoutFittingExpandedSize.width,
            height: proposal.height ?? UIView.layoutFittingExpandedSize.height
        ))
        return size
    }

    private func configuration(in context: Context) -> any UIContentConfiguration {
        UIHostingConfiguration {
            content
                .environment(\.self, context.environment)
        }
        .margins(.all, 0)
    }

    static func dismantleUIView(_ view: SystemCardControl, coordinator: ()) {
        view.focusContext = nil
    }
}

/// UIKit owns focus, including tvOS's High Contrast ring and default motion.
/// The hosting configuration remains live inside the native image's overlay.
@MainActor
private final class SystemCardControl: UIControl {
    let focusImageView = UIImageView()
    let hostedContent: UIView & UIContentView
    var focusContext: SystemCardFocusContext?
    var cornerRadius: CGFloat = 0
    var surfaceColor: UIColor = .black
    private var carrierKey = ""
    private var selecting = false
    private var pendingFocusRequest = false
    private static let carriers: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 8 * 1024 * 1024
        return cache
    }()

    override var canBecomeFocused: Bool { isEnabled }

    init(configuration: any UIContentConfiguration) {
        hostedContent = configuration.makeContentView()
        super.init(frame: .zero)
        focusImageView.adjustsImageWhenAncestorFocused = true
        focusImageView.masksFocusEffectToContents = true
        focusImageView.overlayContentView.clipsToBounds = false
        focusImageView.overlayContentView.addSubview(hostedContent)
        hostedContent.backgroundColor = .clear
        hostedContent.isUserInteractionEnabled = false
        addSubview(focusImageView)
        isAccessibilityElement = false
        accessibilityElements = [hostedContent]
        addAction(UIAction { [weak self] _ in self?.focusContext?.action() }, for: .primaryActionTriggered)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func updateFocusContext(_ context: SystemCardFocusContext) {
        // Consume each explicit request once. An ordinary redraw must never
        // replay it after UIKit has moved focus elsewhere.
        let newlyRequested = context.requestsFocus && focusContext?.requestsFocus != true
        focusContext = context
        if !context.requestsFocus || !context.isEnabled {
            pendingFocusRequest = false
        } else if newlyRequested {
            pendingFocusRequest = true
        }
        applyPendingFocusRequest()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        applyPendingFocusRequest()
    }

    private func applyPendingFocusRequest() {
        guard pendingFocusRequest, isEnabled, window != nil, !bounds.isEmpty,
              let system = UIFocusSystem.focusSystem(for: self) else { return }
        pendingFocusRequest = false
        guard !isFocused else { return }
        system.requestFocusUpdate(to: self)
        system.updateFocusIfNeeded()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !bounds.isEmpty else { return }
        focusImageView.frame = bounds
        hostedContent.frame = focusImageView.overlayContentView.bounds
        let color = surfaceColor.resolvedColor(with: traitCollection)
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            PlozzLog.app.error("System focus requires an RGB-compatible theme surface")
            return
        }
        let key = "\(bounds.size)-\(cornerRadius)-\(red),\(green),\(blue),\(alpha)" as NSString
        if carrierKey != key as String {
            carrierKey = key as String
            if let image = Self.carriers.object(forKey: key) {
                focusImageView.image = image
            } else {
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                let image = UIGraphicsImageRenderer(size: bounds.size, format: format).image { _ in
                    color.setFill()
                    UIBezierPath(roundedRect: CGRect(origin: .zero, size: bounds.size), cornerRadius: cornerRadius).fill()
                }
                Self.carriers.setObject(image, forKey: key, cost: Int(bounds.width * bounds.height * 4))
                focusImageView.image = image
            }
        }
        applyPendingFocusRequest()
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        pendingFocusRequest = false
        if !isFocused { selecting = false }
        focusContext?.onFocus(isFocused)
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .select }) { selecting = true }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .select }) {
            if selecting, isEnabled, isFocused { sendActions(for: .primaryActionTriggered) }
            selecting = false
        }
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        selecting = false
        super.pressesCancelled(presses, with: event)
    }
}

/// UIView/CALayer's 2D conversion drops the native focus image's Z translation
/// before its ancestor's perspective is applied. Keep homogeneous coordinates
/// through the whole chain so the captured rectangle matches the painted image.
enum NativeFocusProjection {
    static func frame(of layer: CALayer, in ancestor: CALayer) -> CGRect? {
        let bounds = (layer.presentation() ?? layer).bounds
        guard !bounds.isEmpty else { return nil }
        var points = [
            Point(x: bounds.minX, y: bounds.minY), Point(x: bounds.maxX, y: bounds.minY),
            Point(x: bounds.minX, y: bounds.maxY), Point(x: bounds.maxX, y: bounds.maxY)
        ]
        var current: CALayer? = layer
        while let node = current, node !== ancestor {
            guard let parent = node.superlayer else { return nil }
            let state = node.presentation() ?? node
            let parentState = parent.presentation() ?? parent
            let anchor = CGPoint(
                x: state.bounds.minX + state.bounds.width * state.anchorPoint.x,
                y: state.bounds.minY + state.bounds.height * state.anchorPoint.y
            )
            for index in points.indices {
                points[index].translate(x: -anchor.x, y: -anchor.y, z: -state.anchorPointZ)
                points[index].apply(state.transform)
                points[index].translate(x: state.position.x, y: state.position.y, z: state.zPosition + state.anchorPointZ)
                if !CATransform3DIsIdentity(parentState.sublayerTransform) {
                    let center = CGPoint(x: parentState.bounds.midX, y: parentState.bounds.midY)
                    points[index].translate(x: -center.x, y: -center.y)
                    points[index].apply(parentState.sublayerTransform)
                    points[index].translate(x: center.x, y: center.y)
                }
            }
            current = parent
        }
        guard current === ancestor, points.allSatisfy({ $0.w.isFinite && abs($0.w) > 0.000001 }) else { return nil }
        let projected = points.map { CGPoint(x: $0.x / $0.w, y: $0.y / $0.w) }
        guard projected.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
              let minX = projected.map(\.x).min(), let maxX = projected.map(\.x).max(),
              let minY = projected.map(\.y).min(), let maxY = projected.map(\.y).max() else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private struct Point {
        var x: CGFloat
        var y: CGFloat
        var z: CGFloat = 0
        var w: CGFloat = 1

        mutating func translate(x: CGFloat, y: CGFloat, z: CGFloat = 0) {
            self.x += x * w
            self.y += y * w
            self.z += z * w
        }

        mutating func apply(_ transform: CATransform3D) {
            let next = Point(
                x: x * transform.m11 + y * transform.m21 + z * transform.m31 + w * transform.m41,
                y: x * transform.m12 + y * transform.m22 + z * transform.m32 + w * transform.m42,
                z: x * transform.m13 + y * transform.m23 + z * transform.m33 + w * transform.m43,
                w: x * transform.m14 + y * transform.m24 + z * transform.m34 + w * transform.m44
            )
            self = next
        }
    }
}

private struct NativeCardButtonStyle: PrimitiveButtonStyle {
    let cornerRadius: CGFloat
    let contentSuppliesProjection: Bool

    func makeBody(configuration: Configuration) -> some View {
        LabelBody(configuration: configuration, cornerRadius: cornerRadius, contentSuppliesProjection: contentSuppliesProjection)
    }

    private struct LabelBody: View {
        let configuration: PrimitiveButtonStyleConfiguration
        let cornerRadius: CGFloat
        let contentSuppliesProjection: Bool
        @State private var focused = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            Group {
                if contentSuppliesProjection {
                    configuration.label
                } else {
                    configuration.label.plozzSystemCardProjection(cornerRadius: cornerRadius)
                }
            }
            .environment(\.systemCardFocusContext, SystemCardFocusContext(
                requestsFocus: false, isEnabled: enabled, onFocus: { focused = $0 }, action: configuration.trigger
            ))
            .plozzChromeFocused(focused)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                if enabled { configuration.trigger() }
            }
        }
    }
}
#endif

private struct CardFocusButtonStyle<Style: ButtonStyle>: ViewModifier {
    let fallback: Style
    let cornerRadius: CGFloat
    let contentSuppliesProjection: Bool
    @Environment(\.plozzCardFocusStyle) private var style

    func body(content: Content) -> some View {
        #if os(tvOS)
        if style.usesSystemEffect {
            content.buttonStyle(NativeCardButtonStyle(
                cornerRadius: cornerRadius, contentSuppliesProjection: contentSuppliesProjection
            ))
        } else {
            content.buttonStyle(fallback).focusEffectDisabled()
        }
        #else
        content.buttonStyle(fallback)
        #endif
    }
}

private struct CardFocusEffectAvailability: ViewModifier {
    @Environment(\.plozzCardFocusStyle) private var style

    func body(content: Content) -> some View {
        content.focusEffectDisabled(!style.usesSystemEffect)
    }
}

private struct RestingCardShadow: ViewModifier {
    let isFocused: Bool
    @Environment(\.plozzCardFocusStyle) private var style

    func body(content: Content) -> some View {
        let customFocus = isFocused && !style.usesSystemEffect
        content.shadow(
            color: .black.opacity(customFocus ? 0.36 : 0.15),
            radius: customFocus ? 20 : 8,
            y: customFocus ? 10 : 4
        )
    }
}
