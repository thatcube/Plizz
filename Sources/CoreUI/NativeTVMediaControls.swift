#if os(tvOS)
import CoreModels
import CoreNetworking
import Observation
import SwiftUI
import TVUIKit
import UIKit

@MainActor @Observable
final class NativePosterArtworkState {
    var image: UIImage?
}

private struct NativePosterArtworkStateKey: EnvironmentKey {
    static let defaultValue: NativePosterArtworkState? = nil
}

extension EnvironmentValues {
    var nativePosterArtworkState: NativePosterArtworkState? {
        get { self[NativePosterArtworkStateKey.self] }
        set { self[NativePosterArtworkStateKey.self] = newValue }
    }
}

enum NativePosterText {
    case content(String)
    case localized(LocalizedStringResource)

    func resolve(locale: Locale) -> String {
        switch self {
        case .content(let value): return value
        case .localized(var value):
            value.locale = locale
            return String(localized: value)
        }
    }
}

@MainActor
final class NativeTVMediaCoordinator {
    var focus: PlozzCardFocus.Binding
    var action: () -> Void
    private var lastRequest = false

    init(focus: PlozzCardFocus.Binding, action: @escaping () -> Void) {
        self.focus = focus
        self.action = action
    }

    func update(focus: PlozzCardFocus.Binding, action: @escaping () -> Void, view: TVLockupView) {
        self.focus = focus
        self.action = action
        let requested = focus.focusState.wrappedValue
        defer { lastRequest = requested }
        guard requested, !lastRequest, view.window != nil, view.isEnabled, !view.isFocused else { return }
        let system = UIFocusSystem.focusSystem(for: view)
        system?.requestFocusUpdate(to: view)
        system?.updateFocusIfNeeded()
    }

    func observe(_ focused: Bool) {
        if focus.observed.wrappedValue != focused { focus.observed.wrappedValue = focused }
    }

    func activate() { action() }
}

struct NativeTVCard<Content: View>: UIViewRepresentable {
    let content: Content
    let focus: PlozzCardFocus.Binding
    let isEnabled: Bool
    let action: () -> Void

    func makeCoordinator() -> NativeTVMediaCoordinator {
        NativeTVMediaCoordinator(focus: focus, action: action)
    }

    func makeUIView(context: Context) -> Card {
        let view = Card()
        let host = configuration(in: context).makeContentView()
        view.hostedContent = host
        view.contentView.addSubview(host)
        host.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: view.contentView.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: view.contentView.trailingAnchor),
            host.topAnchor.constraint(equalTo: view.contentView.topAnchor),
            host.bottomAnchor.constraint(equalTo: view.contentView.bottomAnchor)
        ])
        view.onFocus = { [weak coordinator = context.coordinator] in coordinator?.observe($0) }
        view.addAction(UIAction { [weak coordinator = context.coordinator] _ in coordinator?.activate() },
                       for: .primaryActionTriggered)
        return view
    }

    func updateUIView(_ view: Card, context: Context) {
        view.hostedContent?.configuration = configuration(in: context)
        view.isEnabled = isEnabled && context.environment.isEnabled
        context.coordinator.update(focus: focus, action: action, view: view)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: Card, context: Context) -> CGSize? {
        guard let content = uiView.hostedContent else { return nil }
        let size = content.sizeThatFits(CGSize(
            width: proposal.width ?? UIView.layoutFittingExpandedSize.width,
            height: proposal.height ?? UIView.layoutFittingExpandedSize.height
        ))
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return nil }
        if uiView.contentSize != size { uiView.contentSize = size }
        return uiView.intrinsicContentSize
    }

    private func configuration(in context: Context) -> any UIContentConfiguration {
        UIHostingConfiguration {
            content
                .environment(\.self, context.environment)
                .environment(\.plozzNativeFocusSurface, true)
        }
        .margins(.all, 0)
    }

    final class Card: TVCardView {
        var hostedContent: (UIView & UIContentView)?
        var onFocus: ((Bool) -> Void)?

        override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
            super.didUpdateFocus(in: context, with: coordinator)
            onFocus?(isFocused)
        }
    }
}

enum NativePosterImageTreatment: Equatable {
    case original, blurred, extended
}

struct NativeTVPoster<Overlay: View>: UIViewRepresentable {
    let image: UIImage?
    let treatment: NativePosterImageTreatment
    let aspectRatio: CGFloat
    let fallbackWidth: CGFloat
    let title: NativePosterText?
    let subtitle: String?
    let overlay: Overlay
    let focus: PlozzCardFocus.Binding
    let source: DetailTransitionSourceReference
    let action: () -> Void

    @MainActor
    final class Coordinator {
        let focus: NativeTVMediaCoordinator
        var original: UIImage?
        var treatment = NativePosterImageTreatment.original
        var imageSize = CGSize.zero
        var imageScale: CGFloat = 1
        var prepared: UIImage?
        private var placeholder: UIImage?
        private var placeholderSize = CGSize.zero
        private var placeholderScale: CGFloat = 1

        init(focus: PlozzCardFocus.Binding, action: @escaping () -> Void) {
            self.focus = NativeTVMediaCoordinator(focus: focus, action: action)
        }

        func presentationImage(_ image: UIImage?, treatment: NativePosterImageTreatment, size: CGSize, scale: CGFloat) -> UIImage {
            if let prepared = prepare(image, treatment: treatment, size: size, scale: scale) { return prepared }
            if let placeholder, placeholderSize == size, placeholderScale == scale { return placeholder }
            let format = UIGraphicsImageRendererFormat()
            format.scale = scale
            format.opaque = true
            let loadingImage = UIGraphicsImageRenderer(size: size, format: format).image {
                UIColor.secondarySystemBackground.setFill()
                $0.fill(CGRect(origin: .zero, size: size))
            }
            placeholder = loadingImage
            placeholderSize = size
            placeholderScale = scale
            return loadingImage
        }

        func prepare(_ image: UIImage?, treatment: NativePosterImageTreatment, size: CGSize, scale: CGFloat) -> UIImage? {
            guard let image else { return nil }
            if original === image, self.treatment == treatment, imageSize == size, imageScale == scale { return prepared }
            original = image
            self.treatment = treatment
            imageSize = size
            imageScale = scale
            if treatment == .original, let pixels = image.cgImage {
                prepared = UIImage(
                    cgImage: pixels,
                    scale: image.size.width * image.scale / size.width,
                    orientation: image.imageOrientation
                )
                return prepared
            }
            // TVPosterView derives native focus growth from image.size in points,
            // not the cached bitmap's pixel dimensions.
            let renderer = ImageRenderer(content: Group {
                if treatment == .extended {
                    ExtendedArtworkFill(image: Image(uiImage: image))
                } else {
                    Image(uiImage: image).resizable().scaledToFill()
                        .blur(radius: treatment == .blurred ? 28 : 0)
                }
            }.frame(width: size.width, height: size.height).clipped())
            renderer.scale = scale
            renderer.isOpaque = true
            prepared = renderer.uiImage
            if prepared == nil {
                PlozzLog.app.error("Unable to prepare native poster artwork; keeping the protected placeholder")
            }
            return prepared
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(focus: focus, action: action) }

    func makeUIView(context: Context) -> Poster {
        let size = CGSize(width: fallbackWidth, height: fallbackWidth / aspectRatio)
        let initialImage = context.coordinator.presentationImage(
            image, treatment: treatment, size: size, scale: context.environment.displayScale
        )
        // Materializing imageView with a nil image freezes TVUIKit's native
        // focus expansion at zero, even after an image arrives.
        let view = Poster(image: initialImage)
        view.contentSize = size
        view.hostedOverlay = overlayConfiguration(in: context).makeContentView()
        if let overlay = view.hostedOverlay {
            let container = view.imageView.overlayContentView
            container.addSubview(overlay)
            overlay.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                overlay.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                overlay.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                overlay.topAnchor.constraint(equalTo: container.topAnchor),
                overlay.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            ])
        }
        view.onFocus = { [weak coordinator = context.coordinator] in coordinator?.focus.observe($0) }
        view.addAction(UIAction { [weak coordinator = context.coordinator] _ in coordinator?.focus.activate() },
                       for: .primaryActionTriggered)
        return view
    }

    func updateUIView(_ view: Poster, context: Context) {
        if view.contentSize.width <= 0 {
            view.contentSize = CGSize(width: fallbackWidth, height: fallbackWidth / aspectRatio)
        }
        let resolvedTitle = title?.resolve(locale: context.environment.locale)
        if view.title != resolvedTitle { view.title = resolvedTitle }
        if view.subtitle != subtitle { view.subtitle = subtitle }
        view.hostedOverlay?.configuration = overlayConfiguration(in: context)
        let prepared = context.coordinator.presentationImage(
            image, treatment: treatment, size: view.contentSize, scale: context.environment.displayScale
        )
        if view.image !== prepared { view.image = prepared }
        view.isEnabled = context.environment.isEnabled
        source.nativeArtworkView = view.imageView
        context.coordinator.focus.update(focus: focus, action: action, view: view)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: Poster, context: Context) -> CGSize? {
        let width = proposal.width ?? fallbackWidth
        guard width.isFinite, width > 0 else { return nil }
        let size = CGSize(width: width, height: width / aspectRatio)
        if uiView.contentSize != size { uiView.contentSize = size }
        let prepared = context.coordinator.presentationImage(
            image, treatment: treatment, size: size, scale: context.environment.displayScale
        )
        if uiView.image !== prepared { uiView.image = prepared }
        return uiView.intrinsicContentSize
    }

    private func overlayConfiguration(in context: Context) -> any UIContentConfiguration {
        UIHostingConfiguration {
            overlay
                .environment(\.self, context.environment)
                .environment(\.plozzNativeFocusSurface, true)
        }
        .margins(.all, 0)
    }

    final class Poster: TVPosterView {
        var hostedOverlay: (UIView & UIContentView)?
        var onFocus: ((Bool) -> Void)?

        override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
            super.didUpdateFocus(in: context, with: coordinator)
            onFocus?(isFocused)
        }
    }
}

struct NativeTVCardButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        LabelBody(configuration: configuration)
    }

    private struct LabelBody: View {
        let configuration: PrimitiveButtonStyleConfiguration
        @PlozzCardFocus private var focus: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            NativeTVCard(content: configuration.label, focus: $focus, isEnabled: isEnabled, action: configuration.trigger)
                .focused($focus.focusState)
        }
    }
}
#endif
