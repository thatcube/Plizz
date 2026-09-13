import SwiftUI
import TVUIKit
import UIKit
@testable import CoreUI

struct NativePosterComparisonScreen: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> NativePosterComparisonController {
        NativePosterComparisonController()
    }
    func updateUIViewController(_ controller: NativePosterComparisonController, context: Context) {}
}

final class NativePosterComparisonController: UIViewController {
    private let rawPoster = TVPosterView(image: nil)
    private let normalizedPoster = TVPosterView(image: nil)
    private var adapter: UIHostingController<ComparisonAdapterPoster>?
    private let metadata = UILabel()
    private let size = CGSize(width: 400, height: 225)
    private var placedSize = CGSize.zero
    private var initializationReport = ""
    private var interopHosts: [UIHostingController<AnyView>] = []
    private let configurationPoster = TVPosterView(image: nil)
    private let controllerPoster = TVPosterView(image: nil)
    private var overlayController: UIHostingController<ComparisonSwiftUIOverlay>?

    override var preferredFocusEnvironments: [any UIFocusEnvironment] { [rawPoster] }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let image = NativeComparisonPattern.makeImage()
        rawPoster.image = image
        normalizedPoster.image = image.cgImage.map {
            UIImage(cgImage: $0, scale: 4, orientation: .up)
        }
        initializationReport = initializationDefaults(image: image)
        for poster in [rawPoster, normalizedPoster] {
            poster.contentSize = size
            let overlay = ComparisonUIKitOverlay()
            let container = poster.imageView.overlayContentView
            container.addSubview(overlay)
            overlay.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                overlay.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                overlay.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                overlay.topAnchor.constraint(equalTo: container.topAnchor),
                overlay.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            ])
            view.addSubview(poster)
        }
        let adapter = UIHostingController(rootView: ComparisonAdapterPoster(image: image))
        self.adapter = adapter
        addChild(adapter)
        view.addSubview(adapter.view)
        adapter.view.backgroundColor = .clear
        adapter.didMove(toParent: self)
        interopHosts = [
            UIHostingController(rootView: AnyView(BarePosterRepresentable(image: image))),
            UIHostingController(rootView: AnyView(FocusedBarePoster(image: image))),
            UIHostingController(rootView: AnyView(ContainedPosterRepresentable(image: image)))
        ]
        for host in interopHosts {
            addChild(host)
            view.addSubview(host.view)
            host.didMove(toParent: self)
        }
        for poster in [configurationPoster, controllerPoster] {
            poster.image = image
            poster.contentSize = size
            view.addSubview(poster)
        }
        let configuredOverlay = UIHostingConfiguration { ComparisonSwiftUIOverlay() }.margins(.all, 0).makeContentView()
        installOverlay(configuredOverlay, on: configurationPoster)
        let overlayController = UIHostingController(rootView: ComparisonSwiftUIOverlay())
        self.overlayController = overlayController
        addChild(overlayController)
        overlayController.view.backgroundColor = .clear
        installOverlay(overlayController.view, on: controllerPoster)
        overlayController.didMove(toParent: self)
        for (index, title) in ["Apple raw image", "Apple same point size", "Plozz adapter"].enumerated() {
            let label = UILabel()
            label.text = title
            label.textColor = .white
            label.font = .systemFont(ofSize: 28)
            label.frame = CGRect(x: 110 + index * 600, y: 200, width: 460, height: 50)
            view.addSubview(label)
        }
        metadata.accessibilityIdentifier = "native-comparison-metadata"
        metadata.textColor = .white
        metadata.font = .systemFont(ofSize: 12)
        metadata.numberOfLines = 0
        metadata.frame = CGRect(x: 70, y: 760, width: 1780, height: 250)
        view.addSubview(metadata)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if placedSize != view.bounds.size {
            placedSize = view.bounds.size
            rawPoster.frame = CGRect(x: 120, y: 330, width: 400, height: 225)
            normalizedPoster.frame = CGRect(x: 720, y: 330, width: 400, height: 225)
            adapter?.view.frame = CGRect(x: 1320, y: 330, width: 400, height: 225)
            for (index, host) in interopHosts.enumerated() {
                host.view.frame = CGRect(x: 100 + index * 600, y: 1200, width: 400, height: 225)
                host.view.layoutIfNeeded()
            }
            configurationPoster.frame = CGRect(x: 100, y: 1600, width: 400, height: 225)
            controllerPoster.frame = CGRect(x: 700, y: 1600, width: 400, height: 225)
        }
        updateMetadata()
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.updateMetadata() }
    }

    private func updateMetadata() {
        let posters = [rawPoster, normalizedPoster] + (adapter.flatMap { findPoster(in: $0.view) }.map { [$0] } ?? [])
        metadata.text = posters.enumerated().map { index, poster in
            "\(index): focused=\(poster.isFocused) image=\(String(describing: poster.image?.size))"
                + " scale=\(String(describing: poster.image?.scale)) content=\(poster.contentSize)"
                + " increase=\(poster.focusSizeIncrease)"
                + " adjusts=\(poster.imageView.adjustsImageWhenAncestorFocused)"
                + " imageBounds=\(poster.imageView.bounds) overlayBounds=\(poster.imageView.overlayContentView.bounds)"
        }.joined(separator: "\n") + "\n" + initializationReport + "\n" +
        zip(["plain UIViewRepresentable", "focused UIViewRepresentable", "container UIViewRepresentable"], interopHosts)
            .map { label, host in
                "\(label): increase=\(String(describing: findPoster(in: host.view)?.focusSizeIncrease))"
            }.joined(separator: "\n")
            + "\nUIKit poster + UIHostingConfiguration overlay: \(configurationPoster.focusSizeIncrease)"
            + "\nUIKit poster + UIHostingController overlay: \(controllerPoster.focusSizeIncrease)"
    }

    private func findPoster(in view: UIView) -> TVPosterView? {
        if let poster = view as? TVPosterView { return poster }
        return view.subviews.lazy.compactMap { self.findPoster(in: $0) }.first
    }

    private func initializationDefaults(image: UIImage) -> String {
        let early = TVPosterView(image: image)
        early.contentSize = size
        let late = TVPosterView(image: nil)
        late.contentSize = size
        late.image = image
        let subclass = EmptyPosterSubclass(image: image)
        subclass.contentSize = size
        let productionSubclass = NativeTVPoster<ComparisonSwiftUIOverlay>.Poster(image: image)
        productionSubclass.contentSize = size
        let lateProduction = NativeTVPoster<ComparisonSwiftUIOverlay>.Poster(image: nil)
        lateProduction.contentSize = size
        lateProduction.image = image
        let accessedEarly = TVPosterView(image: nil)
        _ = accessedEarly.imageView.overlayContentView
        accessedEarly.contentSize = size
        accessedEarly.image = image
        let sizedEarly = TVPosterView(image: nil)
        sizedEarly.contentSize = size
        _ = sizedEarly.intrinsicContentSize
        sizedEarly.image = image
        return [
            ("base image-first", early), ("base size-first", late),
            ("empty subclass", subclass), ("production subclass image-first", productionSubclass),
            ("production subclass size-first", lateProduction), ("image view accessed before image", accessedEarly),
            ("intrinsic size read before image", sizedEarly)
        ].map { label, poster in
            poster.frame = CGRect(origin: .zero, size: size)
            poster.layoutIfNeeded()
            return "\(label): increase=\(poster.focusSizeIncrease)"
        }.joined(separator: "\n")
    }

    private func installOverlay(_ overlay: UIView, on poster: TVPosterView) {
        let container = poster.imageView.overlayContentView
        container.addSubview(overlay)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: container.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }
}

private final class EmptyPosterSubclass: TVPosterView {}

private struct BarePosterRepresentable: UIViewRepresentable {
    let image: UIImage
    func makeUIView(context: Context) -> TVPosterView {
        let view = TVPosterView(image: image)
        view.contentSize = CGSize(width: 400, height: 225)
        return view
    }
    func updateUIView(_ view: TVPosterView, context: Context) {}
}

private struct FocusedBarePoster: View {
    let image: UIImage
    @FocusState private var focused: Bool
    var body: some View { BarePosterRepresentable(image: image).focused($focused) }
}

private struct ContainedPosterRepresentable: UIViewRepresentable {
    let image: UIImage
    func makeUIView(context: Context) -> Container {
        let view = Container()
        view.poster.image = image
        view.poster.contentSize = CGSize(width: 400, height: 225)
        view.addSubview(view.poster)
        return view
    }
    func updateUIView(_ view: Container, context: Context) {}

    final class Container: UIView {
        let poster = TVPosterView(image: nil)
        override var preferredFocusEnvironments: [any UIFocusEnvironment] { [poster] }
        override func layoutSubviews() {
            super.layoutSubviews()
            poster.frame = bounds
        }
    }
}

final class ComparisonUIKitOverlay: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ rect: CGRect) {
        UIColor.yellow.setFill()
        for x in [bounds.width * 0.25, bounds.width * 0.75] {
            UIBezierPath(rect: CGRect(x: x - 5, y: bounds.height * 0.7, width: 10, height: 25)).fill()
        }
    }
}

enum NativeComparisonPattern {
    @MainActor
    static func makeImage() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: 1600, height: 900), format: format).image {
            UIColor(red: 0.05, green: 0.15, blue: 0.6, alpha: 1).setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 1600, height: 900))
            UIColor.green.setStroke()
            let edge = UIBezierPath(rect: CGRect(x: 12, y: 12, width: 1576, height: 876))
            edge.lineWidth = 16
            edge.stroke()
            UIColor.red.setFill()
            for x in [CGFloat(400), CGFloat(1200)] {
                $0.fill(CGRect(x: x - 20, y: 270, width: 40, height: 120))
            }
        }
    }
}

private struct ComparisonSwiftUIOverlay: View {
    var body: some View {
        GeometryReader { geometry in
            ForEach([0.25, 0.75], id: \.self) { fraction in
                Color(uiColor: .yellow)
                    .frame(width: 10, height: 25)
                    .position(x: geometry.size.width * fraction, y: geometry.size.height * 0.7 + 12.5)
            }
        }
        .allowsHitTesting(false)
    }
}

struct ComparisonAdapterPoster: View {
    let image: UIImage
    @PlozzCardFocus private var focused: Bool
    @State private var source = DetailTransitionSourceReference()
    @State private var loadedImage: UIImage?

    var body: some View {
        NativeTVPoster(
            image: loadedImage, treatment: .original, aspectRatio: 16 / 9,
            fallbackWidth: 400, title: nil, subtitle: nil,
            overlay: ComparisonSwiftUIOverlay(), focus: $focused, source: source, action: {}
        )
        .focused($focused.focusState)
        .environment(\.plozzCardFocusStyle, .system)
        .frame(width: 400, height: 225)
        .task {
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            loadedImage = image
        }
    }
}
