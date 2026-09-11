#if DEBUG && os(tvOS)
import CoreUI
import FeatureLiveTVCore
import Observation
import SwiftUI
import UIKit

@MainActor
final class PrototypeGuideScrollController {
    fileprivate weak var collection: UICollectionView?
    fileprivate var indices: [LiveTVGuideRowID: Int] = [:]

    func scrollTo(_ row: LiveTVGuideRowID, anchor: UnitPoint) {
        guard let collection, let index = indices[row] else { return }
        collection.layoutIfNeeded()
        collection.scrollToItem(
            at: IndexPath(item: index, section: 0),
            at: anchor == .top ? .top : .centeredVertically, animated: false)
    }
}

/// UIKit recycles real visible rows instead of creating SwiftUI's catalog-wide
/// virtual focus fillers. The guide's existing row content still owns its controls.
struct PrototypeNativeGuideList<Revision: Equatable, Content: View>: UIViewControllerRepresentable {
    let rows: [LiveTVGuideRowID]
    let scrollController: PrototypeGuideScrollController
    let scrolled: (LiveTVGuideRowID?, CGFloat) -> Void
    let revision: (LiveTVGuideRowID) -> Revision
    @ViewBuilder let content: (LiveTVGuideRowID) -> Content

    struct RowEnvironment: Equatable {
        let palette: ThemePalette
        let reduceTransparency: Bool
        let colorScheme: ColorScheme
        let contrast: ColorSchemeContrast
        let direction: LayoutDirection
        let dynamicType: DynamicTypeSize
        let locale: Locale
        let calendar: Calendar
        let timeZone: TimeZone
        let isEnabled: Bool

        init(_ environment: EnvironmentValues) {
            palette = environment.themePalette
            reduceTransparency = environment.plozzReduceTransparency
            colorScheme = environment.colorScheme
            contrast = environment.colorSchemeContrast
            direction = environment.layoutDirection
            dynamicType = environment.dynamicTypeSize
            locale = environment.locale
            calendar = environment.calendar
            timeZone = environment.timeZone
            isEnabled = environment.isEnabled
        }
    }

    @MainActor
    @Observable
    final class RowState {
        let id: LiveTVGuideRowID
        var content: Content
        var environment: RowEnvironment
        @ObservationIgnored var revision: Revision

        init(id: LiveTVGuideRowID, content: Content, environment: RowEnvironment, revision: Revision) {
            self.id = id
            self.content = content
            self.environment = environment
            self.revision = revision
        }
    }

    struct HostedRow: View {
        let state: RowState

        var body: some View {
            // Preserve presentation values without copying another hosting
            // controller's private focus/scroll environment into this row.
            state.content.id(state.id)
                .environment(\.themePalette, state.environment.palette)
                .environment(\.plozzReduceTransparency, state.environment.reduceTransparency)
                .environment(\.colorScheme, state.environment.colorScheme)
                .environment(\.layoutDirection, state.environment.direction)
                .environment(\.dynamicTypeSize, state.environment.dynamicType)
                .environment(\.locale, state.environment.locale)
                .environment(\.calendar, state.environment.calendar)
                .environment(\.timeZone, state.environment.timeZone)
                .environment(\.isEnabled, state.environment.isEnabled)
        }
    }

    func makeUIViewController(context: Context) -> Controller {
        let controller = Controller()
        controller.parentView = self
        controller.swiftUIEnvironment = context.environment
        controller.loadViewIfNeeded()
        return controller
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.update(self, environment: context.environment)
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.collectionView.delegate = nil
        controller.collectionView.dataSource = nil
        controller.parentView?.scrollController.collection = nil
        controller.parentView = nil
        controller.swiftUIEnvironment = nil
        for child in controller.children {
            child.willMove(toParent: nil)
            child.removeFromParent()
        }
    }

    final class Controller: UICollectionViewController {
        var parentView: PrototypeNativeGuideList?
        var swiftUIEnvironment: EnvironmentValues?
        private var rowIDs: [LiveTVGuideRowID] = []
        private var scrollReportScheduled = false

        init() {
            let size = NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1),
                heightDimension: .estimated(PrototypeLayout.rowHeight + PrototypeLayout.rowGap))
            let group = NSCollectionLayoutGroup.horizontal(
                layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)])
            let section = NSCollectionLayoutSection(group: group)
            section.contentInsets.top = PrototypeLayout.smallGap
            let configuration = UICollectionViewCompositionalLayoutConfiguration()
            configuration.contentInsetsReference = .none
            super.init(collectionViewLayout: UICollectionViewCompositionalLayout(
                section: section, configuration: configuration))
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .clear
            collectionView.backgroundColor = .clear
            collectionView.showsVerticalScrollIndicator = false
            collectionView.allowsSelection = false
            // Remembering a cell redirects directional moves to its first
            // descendant, instead of preserving the guide's content column.
            collectionView.remembersLastFocusedIndexPath = false
            collectionView.contentInsetAdjustmentBehavior = .never
            collectionView.register(Cell.self, forCellWithReuseIdentifier: "guide-row")
            if let parentView, let swiftUIEnvironment { update(parentView, environment: swiftUIEnvironment) }
        }

        func update(_ parent: PrototypeNativeGuideList, environment: EnvironmentValues) {
            parentView = parent
            swiftUIEnvironment = environment
            parent.scrollController.collection = collectionView
            if rowIDs != parent.rows {
                rowIDs = parent.rows
                parent.scrollController.indices = Dictionary(uniqueKeysWithValues: rowIDs.enumerated().map { ($0.element, $0.offset) })
                collectionView.reloadData()
            } else {
                for case let cell as Cell in collectionView.visibleCells {
                    guard let path = collectionView.indexPath(for: cell), rowIDs.indices.contains(path.item) else { continue }
                    configure(cell, row: rowIDs[path.item])
                }
            }
            reportScroll()
        }

        override func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { rowIDs.count }

        override func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            guard let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "guide-row", for: indexPath) as? Cell else {
                preconditionFailure("Expected native guide row cell")
            }
            configure(cell, row: rowIDs[indexPath.item])
            return cell
        }

        override func collectionView(
            _ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath
        ) {
            guard let host = (cell as? Cell)?.host, host.parent == nil else { return }
            addChild(host)
            host.didMove(toParent: self)
        }

        override func collectionView(
            _ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath
        ) {
            guard let host = (cell as? Cell)?.host, host.parent === self else { return }
            host.willMove(toParent: nil)
            host.removeFromParent()
        }

        override func scrollViewDidScroll(_ scrollView: UIScrollView) { reportScroll() }

        private func configure(_ cell: Cell, row: LiveTVGuideRowID) {
            guard let parentView, let swiftUIEnvironment else { return }
            let revision = parentView.revision(row)
            let environment = RowEnvironment(swiftUIEnvironment)
            if let state = cell.rowState, state.id == row {
                if state.revision != revision {
                    state.revision = revision
                    state.content = parentView.content(row)
                    cell.measuredSize = nil
                }
                if state.environment != environment { cell.measuredSize = nil }
                state.environment = environment
            } else {
                let state = RowState(
                    id: row, content: parentView.content(row), environment: environment, revision: revision)
                if let host = cell.host {
                    host.rootView = HostedRow(state: state)
                } else {
                    let host = UIHostingController(rootView: HostedRow(state: state))
                    // Overscan insets change as a cell scrolls across screen
                    // edges; they must not resize or shift guide controls.
                    host.safeAreaRegions = []
                    host.sizingOptions = [.intrinsicContentSize]
                    host.view.backgroundColor = .clear
                    host.view.translatesAutoresizingMaskIntoConstraints = false
                    cell.contentView.addSubview(host.view)
                    NSLayoutConstraint.activate([
                        host.view.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor),
                        host.view.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor),
                        host.view.topAnchor.constraint(equalTo: cell.contentView.topAnchor),
                        host.view.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor)
                    ])
                    cell.host = host
                }
                cell.rowState = state
                cell.measuredSize = nil
            }
        }

        private func reportScroll() {
            guard !scrollReportScheduled else { return }
            scrollReportScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scrollReportScheduled = false
                guard let parentView = self.parentView else { return }
                let first = self.collectionView.indexPathsForVisibleItems.map(\.item).min()
                let row = first.flatMap { self.rowIDs.indices.contains($0) ? self.rowIDs[$0] : nil }
                parentView.scrolled(row, self.collectionView.contentOffset.y + self.collectionView.adjustedContentInset.top)
            }
        }
    }

    final class Cell: UICollectionViewCell {
        var host: UIHostingController<HostedRow>?
        var rowState: RowState?
        var measuredSize: CGSize?
        override var canBecomeFocused: Bool { false }

        override func preferredLayoutAttributesFitting(_ layoutAttributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
            if let measuredSize, measuredSize.width == layoutAttributes.size.width {
                layoutAttributes.size = measuredSize
                return layoutAttributes
            }
            let attributes = super.preferredLayoutAttributesFitting(layoutAttributes)
            if let host {
                attributes.size.height = ceil(host.sizeThatFits(in: CGSize(
                    width: layoutAttributes.size.width, height: .greatestFiniteMagnitude)).height)
                measuredSize = attributes.size
            }
            return attributes
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            contentView.backgroundColor = .clear
            preservesSuperviewLayoutMargins = false
            insetsLayoutMarginsFromSafeArea = false
            layoutMargins = .zero
            contentView.preservesSuperviewLayoutMargins = false
            contentView.layoutMargins = .zero
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }
}
#endif
