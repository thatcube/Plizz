import SwiftUI
import TVUIKit
import UIKit

struct NativeMediaCellComparisonScreen: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> NativeMediaCellComparisonController {
        NativeMediaCellComparisonController()
    }
    func updateUIViewController(_ controller: NativeMediaCellComparisonController, context: Context) {}
}

final class NativeMediaCellComparisonController: UIViewController, UICollectionViewDataSource {
    private let poster = TVPosterView(image: nil)
    private let image = NativeComparisonPattern.makeImage()
    private let metadata = UILabel()
    private var placedSize = CGSize.zero
    private let collectionView: UICollectionView = {
        let layout = UICollectionViewFlowLayout()
        layout.itemSize = CGSize(width: 400, height: 225)
        layout.minimumLineSpacing = 80
        layout.minimumInteritemSpacing = 0
        layout.scrollDirection = .horizontal
        return UICollectionView(frame: .zero, collectionViewLayout: layout)
    }()
    private let registration = UICollectionView.CellRegistration<NativeComparisonMediaCell, UIImage> { cell, _, image in
        cell.artwork = image
    }

    override var preferredFocusEnvironments: [any UIFocusEnvironment] { [poster] }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        poster.image = image
        poster.contentSize = CGSize(width: 400, height: 225)
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
        collectionView.dataSource = self
        collectionView.backgroundColor = .clear
        collectionView.clipsToBounds = false
        view.addSubview(collectionView)
        for (index, title) in ["Bare TVPosterView", "TVMediaItemContentConfiguration", "Second media cell"].enumerated() {
            let label = UILabel()
            label.text = title
            label.font = .systemFont(ofSize: 22)
            label.textColor = .white
            label.frame = CGRect(x: 100 + index * 600, y: 210, width: 560, height: 50)
            view.addSubview(label)
        }
        metadata.accessibilityIdentifier = "native-comparison-metadata"
        metadata.textColor = .white
        metadata.numberOfLines = 0
        metadata.font = .systemFont(ofSize: 18)
        metadata.frame = CGRect(x: 80, y: 740, width: 1750, height: 260)
        view.addSubview(metadata)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if placedSize != view.bounds.size {
            placedSize = view.bounds.size
            poster.frame = CGRect(x: 120, y: 330, width: 400, height: 225)
            collectionView.frame = CGRect(x: 720, y: 330, width: 1000, height: 225)
            collectionView.layoutIfNeeded()
        }
        updateMetadata()
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { 2 }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: image)
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.updateMetadata() }
    }

    private func updateMetadata() {
        var rows = ["0: focused=\(poster.isFocused) TVPosterView increase=\(poster.focusSizeIncrease)"]
        for index in 0..<2 {
            let cell = collectionView.cellForItem(at: IndexPath(item: index, section: 0))
            let content = cell.flatMap { findMediaContent(in: $0) }
            rows.append("\(index + 1): focused=\(cell?.isFocused == true)"
                + " TVMediaItemContentView frame=\(String(describing: content?.frame))"
                + " focusedGuide=\(String(describing: content?.focusedFrameGuide.layoutFrame))")
        }
        metadata.text = rows.joined(separator: "\n")
    }

    private func findMediaContent(in view: UIView) -> TVMediaItemContentView? {
        if let content = view as? TVMediaItemContentView { return content }
        return view.subviews.lazy.compactMap { self.findMediaContent(in: $0) }.first
    }
}

private final class NativeComparisonMediaCell: UICollectionViewCell {
    var artwork: UIImage? {
        didSet { setNeedsUpdateConfiguration() }
    }
    private let markerOverlay = ComparisonUIKitOverlay()

    override func updateConfiguration(using state: UICellConfigurationState) {
        super.updateConfiguration(using: state)
        var content = TVMediaItemContentConfiguration.wideCell()
        content.image = artwork
        content.overlayView = markerOverlay
        contentConfiguration = content.updated(for: state)
    }
}
