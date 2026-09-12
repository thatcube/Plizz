import CoreModels
import SwiftUI

private struct NativeFocusSurfaceKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var plozzNativeFocusSurface: Bool {
        get { self[NativeFocusSurfaceKey.self] }
        set { self[NativeFocusSurfaceKey.self] = newValue }
    }
}

@propertyWrapper
public struct PlozzCardFocus: DynamicProperty {
    @FocusState private var focused: Bool

    public init() {}

    public var wrappedValue: Bool {
        get { focused }
        nonmutating set { focused = newValue }
    }

    public var projectedValue: Binding { Binding(focusState: $focused) }

    public struct Binding {
        public let focusState: FocusState<Bool>.Binding
    }
}

public extension View {
    func plozzCardFocusEffect() -> some View {
        modifier(CardFocusEffectAvailability())
    }

    /// Apple's tvOS projection, specular highlight and remote-driven parallax.
    func plozzSystemCardProjection(cornerRadius: CGFloat) -> some View {
        #if os(tvOS)
        hoverEffect(.highlight)
        #else
        self
        #endif
    }

    func plozzRestingCardShadow(isFocused: Bool) -> some View {
        modifier(RestingCardShadow(isFocused: isFocused))
    }

    func plozzCardArtworkClip<S: Shape>(_ shape: S) -> some View {
        modifier(CardArtworkClip(shape: shape))
    }

    func plozzNativeMediaButtonStyle() -> some View {
        modifier(NativeMediaButtonStyle())
    }

    func plozzCardFocusButtonStyle<Style: ButtonStyle>(
        _ fallback: Style, cornerRadius: CGFloat, contentSuppliesProjection: Bool = false
    ) -> some View {
        modifier(CardFocusButtonStyle(fallback: fallback, contentSuppliesProjection: contentSuppliesProjection))
    }
}

private struct CardFocusButtonStyle<Style: ButtonStyle>: ViewModifier {
    let fallback: Style
    let contentSuppliesProjection: Bool
    @Environment(\.plozzCardFocusStyle) private var style

    func body(content: Content) -> some View {
        #if os(tvOS)
        if style.usesSystemEffect {
            if contentSuppliesProjection {
                content.buttonStyle(.borderless)
                    .environment(\.plozzNativeFocusSurface, true)
            } else {
                content.buttonStyle(.card)
                    .environment(\.plozzNativeFocusSurface, true)
            }
        } else {
            content.buttonStyle(fallback).focusEffectDisabled()
        }
        #else
        content.buttonStyle(fallback)
        #endif
    }
}

private struct NativeMediaButtonStyle: ViewModifier {
    @Environment(\.plozzCardStyle) private var cardStyle

    func body(content: Content) -> some View {
        #if os(tvOS)
        if cardStyle == .borderless {
            content.buttonStyle(.borderless)
        } else {
            content.buttonStyle(.card)
        }
        #else
        content
        #endif
    }
}

private struct CardArtworkClip<S: Shape>: ViewModifier {
    let shape: S
    @Environment(\.plozzNativeFocusSurface) private var nativeSurface

    func body(content: Content) -> some View {
        #if os(tvOS)
        if nativeSurface {
            content
        } else {
            content.clipShape(shape)
        }
        #else
        content.clipShape(shape)
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
    @Environment(\.plozzNativeFocusSurface) private var nativeSurface

    func body(content: Content) -> some View {
        if nativeSurface {
            content
        } else {
            content.shadow(
                color: .black.opacity(isFocused ? 0.36 : 0.15),
                radius: isFocused ? 20 : 8,
                y: isFocused ? 10 : 4
            )
        }
    }
}

#if os(tvOS)
import UIKit

/// Geometry only: retain Z until ancestor perspective is applied when capturing
/// a native focused image for the separate detail-page transition.
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
            self = Point(
                x: x * transform.m11 + y * transform.m21 + z * transform.m31 + w * transform.m41,
                y: x * transform.m12 + y * transform.m22 + z * transform.m32 + w * transform.m42,
                z: x * transform.m13 + y * transform.m23 + z * transform.m33 + w * transform.m43,
                w: x * transform.m14 + y * transform.m24 + z * transform.m34 + w * transform.m44
            )
        }
    }
}
#endif
