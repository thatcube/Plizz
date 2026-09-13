import SwiftUI
import UIKit
import CoreUI
import CoreModels

@main
struct FocusHostApp: App {
    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.arguments.contains("--production-home-fixture") {
                ProductionHomeFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--native-media-cell-comparison") {
                NativeMediaCellComparisonScreen()
            } else if ProcessInfo.processInfo.arguments.contains("--native-poster-comparison") {
                NativePosterComparisonScreen()
            } else if ProcessInfo.processInfo.arguments.contains("--focus-navigation-fixture") {
                SystemFocusNavigationFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--focus-style-fixture") {
                FocusStyleFixture()
            } else {
                Color.black
            }
        }
    }
}

private struct FocusStyleFixture: View {
    private var mode: String { ProcessInfo.processInfo.arguments.last ?? "" }

    private var artwork: some View {
        Color.red.frame(width: 240, height: 360)
            .clipShape(RoundedRectangle(cornerRadius: 28))
    }

    private var nativeImage: some View {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 360)).image {
            UIColor.red.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 240, height: 360))
        }
        return Image(uiImage: image).resizable().frame(width: 240, height: 360)
    }

    var body: some View {
        Group {
            if mode == "production" || mode == "production-circle" {
                ProductionFocusFixture(circular: mode == "production-circle")
            } else if mode == "uikit" || mode == "uikit-ancestor" {
                UIKitFocusReference(ownsFocus: mode == "uikit")
                    .frame(width: 240, height: 360)
                    .focusable(mode == "uikit-ancestor")
            } else if mode == "automatic" {
                Button {} label: {
                    nativeImage
                    Text("Focus reference")
                }
                .buttonStyle(.borderless)
            } else if mode == "card" {
                Button {} label: {
                    VStack {
                        nativeImage
                        Text("Focus reference")
                    }
                }

                .buttonStyle(.card)
            } else if mode == "native" {
                Button {} label: {
                    artwork.hoverEffect(.highlight)
                    Text("Focus reference")
                }
                .buttonStyle(.borderless)
            } else {
                VStack(spacing: 32) {
                    artwork.hoverEffect(mode == "highlight" ? .highlight : .lift)
                    Text("Focus reference")
                }
                .focusable()
                .focusEffectDisabled(false)
            }
        }
        .buttonBorderShape(.roundedRectangle(radius: 28))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
    }
}

private struct ProductionFocusFixture: View {
    let circular: Bool
    @PlozzCardFocus private var focused: Bool
    @State private var activations = 0

    var body: some View {
        let radius: CGFloat = circular ? 100 : 28
        VStack(spacing: 40) {
            Color.red
                .frame(width: circular ? 200 : 240, height: circular ? 200 : 360)
                .clipShape(RoundedRectangle(cornerRadius: radius))
                .plozzSystemCardProjection(cornerRadius: radius)
                .focusableCard(isFocused: $focused, cornerRadius: radius) { activations += 1 }
                .accessibilityLabel("System card")
                .contextMenu {
                    Button("Context action") { activations += 100 }
                }
            Text("Activated \(activations)")
        }
        .environment(\.plozzCardFocusStyle, .system)
    }
}

private struct UIKitFocusReference: UIViewRepresentable {
    var ownsFocus = true
    func makeUIView(context: Context) -> FocusContainer {
        let view = FocusContainer()
        view.ownsFocus = ownsFocus
        return view
    }
    func updateUIView(_ view: FocusContainer, context: Context) {}

    final class FocusContainer: UIView {
        let imageView = UIImageView()
        var ownsFocus = true
        override var canBecomeFocused: Bool { ownsFocus }

        override init(frame: CGRect) {
            super.init(frame: frame)
            let image = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 360)).image { _ in
                UIColor.red.setFill()
                UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: 240, height: 360), cornerRadius: 28).fill()
            }
            imageView.image = image
            imageView.adjustsImageWhenAncestorFocused = true
            imageView.masksFocusEffectToContents = true
            addSubview(imageView)
            isAccessibilityElement = true
            accessibilityLabel = "UIKit focus reference"
            accessibilityTraits = .button
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func layoutSubviews() {
            super.layoutSubviews()
            imageView.frame = bounds
        }
    }
}
