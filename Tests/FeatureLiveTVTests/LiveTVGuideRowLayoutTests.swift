#if DEBUG && canImport(SwiftUI) && canImport(UIKit)
import CoreGraphics
import CoreUI
import FeatureLiveTVCore
import SwiftUI
import UIKit
import XCTest
@testable import FeatureLiveTV

@MainActor
final class LiveTVGuideRowLayoutTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testNarrowClippedProgramsDoNotStretchTheChannelRow() {
        let programs = [
            program("leading", from: -1_080, to: 660),
            program("regular", from: 660, to: 2_400),
            program("long", from: 2_400, to: 21_590),
            program("trailing", from: 21_590, to: 22_200)
        ]
        XCTAssertEqual(height(programs: programs), PrototypeLayout.rowHeight, accuracy: 0.5)
    }

    func testGuideAndChannelOnlyRowsHaveTheSameHeight() {
        let regular = height(programs: [program("regular", from: 0, to: 21_600)])
        let narrow = height(programs: [program("brief", from: 0, to: 30)])
        let withoutGuide = height(programs: [])
        XCTAssertEqual(regular, PrototypeLayout.rowHeight, accuracy: 0.5)
        XCTAssertEqual(narrow, regular, accuracy: 0.5)
        XCTAssertEqual(withoutGuide, regular, accuracy: 0.5)
    }

    func testRowHeightDoesNotDependOnTimestampWrappingOrLongTitles() {
        let longTitle = String(repeating: "A long programme title ", count: 12)
        let programs = [program(longTitle, from: -3_600, to: 60)]
        for locale in ["en_US", "fr_FR", "ar"] {
            XCTAssertEqual(
                height(programs: programs, locale: locale),
                PrototypeLayout.rowHeight,
                accuracy: 0.5
            )
        }
    }

    func testAccessibilityTextScalesAllGuideRowsTogether() {
        let regular = height(
            programs: [program("regular", from: 0, to: 21_600)],
            typeSize: .accessibility3
        )
        let narrow = height(
            programs: [program("brief", from: 0, to: 30)],
            typeSize: .accessibility3
        )
        let withoutGuide = height(programs: [], typeSize: .accessibility3)
        XCTAssertGreaterThanOrEqual(regular, PrototypeLayout.rowHeight)
        XCTAssertEqual(narrow, regular, accuracy: 0.5)
        XCTAssertEqual(withoutGuide, regular, accuracy: 0.5)
    }

    func testPreviewExtendsToTheScreenEdgeInsteadOfStackingSafeAreaMargins() {
        let layout = PrototypePreviewLayout(
            size: CGSize(width: 1_740, height: 960),
            safeAreaInsets: EdgeInsets(top: 60, leading: 90, bottom: 60, trailing: 90)
        )
        XCTAssertEqual(layout.bounds, CGRect(x: -90, y: -60, width: 1_920, height: 1_080))
        XCTAssertEqual(layout.videoFrame.maxX, layout.bounds.maxX, accuracy: 0.5)
        XCTAssertEqual(layout.videoFrame.minX, layout.bounds.minX, accuracy: 0.5)
        XCTAssertEqual(layout.videoFrame.minY, layout.bounds.minY, accuracy: 0.5)
        XCTAssertEqual(layout.videoFrame.width / layout.videoFrame.height, 16.0 / 9.0, accuracy: 0.001)
        #if os(tvOS)
        XCTAssertEqual(layout.contentFrame.minX - layout.bounds.minX, 32, accuracy: 0.5)
        XCTAssertEqual(layout.bounds.maxX - layout.contentFrame.maxX, 32, accuracy: 0.5)
        XCTAssertEqual(layout.bounds.maxY - layout.contentFrame.maxY, 20, accuracy: 0.5)
        #endif
    }

    func testPreviewFadeFinishesBeforeThePictureAndScreenEdges() {
        for size in [
            CGSize(width: 1_920, height: 1_080),
            CGSize(width: 1_024, height: 768),
            CGSize(width: 390, height: 844),
            CGSize(width: 844, height: 390)
        ] {
            let layout = PrototypePreviewLayout(size: size)
            let end = layout.bounds.minY + layout.fadeEnd
            XCTAssertGreaterThan(layout.fadeEnd, 0)
            XCTAssertLessThan(end, layout.videoFrame.maxY - 16)
            XCTAssertLessThan(end, layout.bounds.maxY - 16)
        }
    }

    func testGuideReachesTVBottomWithoutMovingSidebarControlsIntoOverscan() {
        let layout = PrototypePreviewLayout(
            size: CGSize(width: 1_740, height: 960),
            safeAreaInsets: EdgeInsets(top: 60, leading: 90, bottom: 60, trailing: 90)
        )
        #if os(tvOS)
        XCTAssertEqual(layout.contentFrame.maxY + layout.guideBottomExtension, layout.bounds.maxY)
        XCTAssertGreaterThan(layout.guideBottomExtension, 0)
        XCTAssertEqual(PrototypeLayout.guideShape.cornerRadii.bottomLeading, 0)
        XCTAssertEqual(PrototypeLayout.guideShape.cornerRadii.bottomTrailing, 0)
        #else
        XCTAssertEqual(layout.guideBottomExtension, 0)
        XCTAssertLessThan(layout.contentFrame.maxY, layout.bounds.maxY)
        #endif
    }

    func testGuideExtendsToTrailingScreenEdgeWithoutMovingItsLeadingControls() {
        for searching in [false, true] {
            for navigationInset: CGFloat in [0, 112] {
                let layout = PrototypePreviewLayout(
                    size: CGSize(width: 1_740, height: 960),
                    safeAreaInsets: EdgeInsets(top: 60, leading: 90, bottom: 60, trailing: 90),
                    navigationInset: navigationInset, isSearching: searching
                )
                #if os(tvOS)
                XCTAssertEqual(layout.contentFrame.maxX + layout.guideTrailingExtension, layout.bounds.maxX)
                XCTAssertEqual(
                    layout.contentFrame.minX - layout.bounds.minX,
                    (navigationInset > 0 ? 90 : 32) + navigationInset
                )
                XCTAssertEqual(PrototypeLayout.guideTrailingInset, 0)
                XCTAssertEqual(PrototypeLayout.guideShape.cornerRadii.topTrailing, 0)
                #else
                XCTAssertEqual(layout.guideTrailingExtension, 0)
                XCTAssertEqual(PrototypeLayout.guideTrailingInset, PrototypeLayout.guideInset)
                #endif
            }
        }
    }

    func testLogoOnlyStationColumnReservesALargerReadableMarkAndMoreTimelineSpace() {
        let size = UIHostingController(rootView: PrototypeStationMark(channel: LiveTVPrototypeModel().channels[0]))
            .sizeThatFits(in: CGSize(width: 500, height: 500))
        XCTAssertEqual(size.height, PrototypeLayout.stationSize, accuracy: 0.5)
        XCTAssertEqual(size.width, PrototypeLayout.stationSize * 1.75, accuracy: 0.5)
        XCTAssertEqual(PrototypeLayout.stationColumnWidth - size.width, PrototypeLayout.rowInset * 2, accuracy: 0.5)
        #if os(tvOS)
        XCTAssertGreaterThan(size.width, 126)
        XCTAssertGreaterThan(size.height, 72)
        XCTAssertLessThan(PrototypeLayout.stationColumnWidth, 280)
        #endif
    }

    func testSectionLabelsFitTheStationColumnInBothReadingDirections() {
        for direction in [LayoutDirection.leftToRight, .rightToLeft] {
            for section in [LiveTVGuideSection.recent, .favorites, .channels] {
                let label = PrototypeGuideSectionLabel(section: section)
                    .environment(\.layoutDirection, direction)
                    .dynamicTypeSize(.large)
                let size = UIHostingController(rootView: label)
                    .sizeThatFits(in: CGSize(width: PrototypeLayout.stationColumnWidth, height: 60))
                XCTAssertLessThanOrEqual(size.width, PrototypeLayout.stationColumnWidth + 0.5)
                XCTAssertLessThanOrEqual(size.height, 60)
            }
        }
    }

    func testGuideLogoBackingFillsTheFocusBoundsWithoutAnOuterGutter() throws {
        let width = Int(PrototypeLayout.stationColumnWidth)
        let height = Int(PrototypeLayout.rowHeight)
        let mark = PrototypeStationMark(
            channel: LiveTVPrototypeModel().channels[0],
            plateSize: CGSize(width: width, height: height),
            cornerRadius: PrototypeLayout.rowRadius
        )
        let renderer = ImageRenderer(content: mark)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        XCTAssertEqual(image.width, width)
        XCTAssertEqual(image.height, height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(
                data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        for (x, y) in [(width / 2, 1), (width / 2, height - 2), (1, height / 2), (width - 2, height / 2)] {
            XCTAssertGreaterThan(pixels[(y * width + x) * 4 + 3], 250)
        }
    }

    func testGuideLogoBackingMatchesScaledRows() {
        for height in [PrototypeLayout.rowHeight, PrototypeLayout.rowHeight * 2] {
            let mark = PrototypeStationMark(
                channel: LiveTVPrototypeModel().channels[0],
                plateSize: CGSize(width: PrototypeLayout.stationColumnWidth, height: height),
                cornerRadius: PrototypeLayout.rowRadius
            )
            let size = UIHostingController(rootView: mark).sizeThatFits(in: CGSize(width: 600, height: 600))
            XCTAssertEqual(size.width, PrototypeLayout.stationColumnWidth, accuracy: 0.5)
            XCTAssertEqual(size.height, height, accuracy: 0.5)
        }
    }

    func testLongChannelNamesWithoutListingsStayInsideTheRow() {
        let label = PrototypeGuideGap(
            channelName: String(repeating: "International channel ", count: 12),
            height: PrototypeLayout.rowHeight
        )
        let size = UIHostingController(rootView: label)
            .sizeThatFits(in: CGSize(width: 500, height: 600))
        XCTAssertEqual(size.height, PrototypeLayout.rowHeight, accuracy: 0.5)
        XCTAssertLessThanOrEqual(size.width, 500.5)
    }

    func testTVPreviewRemainsVisibleBehindTheUpperGuide() {
        let layout = PrototypePreviewLayout(size: CGSize(width: 1_920, height: 1_080))
        let guideTop = layout.contentFrame.minY + layout.heroHeight + PrototypeLayout.sectionGap * 2
            + PrototypeLayout.controlHeight + PrototypeLayout.controlInset * 2
        XCTAssertGreaterThan(
            layout.bounds.minY + layout.fadeEnd,
            guideTop + PrototypeLayout.rowHeight * 2
        )
    }

    func testGuideSurfaceNeverDisappearsBehindTheTimeHeader() throws {
        let samples = try alphaSamples(
            PrototypeGuideSurface()
                .environment(\.plozzReduceTransparency, false)
                .environment(\.themePalette, ThemePalette.dark),
            size: CGSize(width: 600, height: 400),
            points: [(300, 0), (300, 1), (300, 40), (300, 200), (300, 398)]
        )
        XCTAssertEqual(PrototypeLayout.minimumGuideOpacity, 0.05)
        XCTAssertTrue(samples.allSatisfy { $0 >= 12 })
        XCTAssertLessThan(try XCTUnwrap(samples.first), 25)
    }

    func testNowMarkerIsACompactPointerWithoutALineThroughTheRows() throws {
        let samples = try alphaSamples(
            PrototypeNowMarker(start: start, now: start.addingTimeInterval(1_800), timelineOffset: 50)
                .frame(maxHeight: .infinity, alignment: .top),
            size: CGSize(width: 600, height: 400),
            points: [(99, 4), (99, 43), (99, 60), (99, 199), (99, 398)]
        )
        XCTAssertGreaterThan(try XCTUnwrap(samples.first), 190)
        XCTAssertTrue(samples.dropFirst().allSatisfy { $0 == 0 })
        XCTAssertLessThan(PrototypeNowMarker.size.height, PrototypeLayout.gap)
    }

    func testBrowserNowMarkerSitsBelowTheRulerWithOrWithoutListings() throws {
        let channel = LiveTVPrototypeChannel(
            id: "station", number: 1, name: "Test station", category: "News",
            symbol: "tv", accent: 0, source: .iptv, tagline: ""
        )
        for programs in [[], [program("Test program", from: 0, to: 3_600)]] {
            let model = LiveTVPrototypeModel(now: start.addingTimeInterval(1_800), channels: [channel])
            try model.replacePrograms(programs)
            let browser = PrototypeBrowser(
                model: model, imports: LiveTVPrototypeImportModel(configuration: .init(playlists: [])),
                selectedID: .constant(nil), selectedRowID: .constant(nil),
                railActive: .constant(false), focusedProgram: .constant(nil), hasFocus: .constant(false),
                topRequest: 0, nowRequest: 0, guideOffset: .constant(0), timeAnchor: .constant(start),
                timelineOffset: .constant(0), restoreFocusRequest: 0, isPresented: true,
                isRestoringFocus: false, restoresPlaybackFocus: false, watchOrigin: nil,
                focusRestored: { _ in }, tune: { _ in }, details: { _ in },
                openControls: {}, openSources: {}, openGuideTime: {}, openToolbar: {},
                isLoading: false, loadFailed: false, reload: {}
            )
            .environment(\.plozzReduceTransparency, false)
            .environment(\.themePalette, ThemePalette.dark)
            let innerWidth: CGFloat = 1_000 - PrototypeLayout.guideInset - PrototypeLayout.guideTrailingInset
            let x = Int(PrototypeLayout.guideInset + PrototypeLayout.stationWidth(for: innerWidth)
                + PrototypeLayout.columnGap + PrototypeLayout.timelineWidth(for: innerWidth) / 4)
            let top = Int(PrototypeLayout.guideInset)
            let samples = try alphaSamples(
                browser, size: CGSize(width: 1_000, height: 400),
                points: [(x, top + 2), (x, top + 40),
                         (x, top + 44 + Int(PrototypeLayout.gap - PrototypeNowMarker.size.height) + 4)]
            )
            XCTAssertTrue(samples.prefix(2).allSatisfy { $0 < 80 }, "\(samples)")
            XCTAssertGreaterThan(try XCTUnwrap(samples.last), 190, "\(samples), listings: \(programs.count)")
        }
    }

    func testNowMarkerFollowsClockAndHorizontalOffsetWithoutClampingOffscreenTime() throws {
        for (nowOffset, scrollOffset, visibleX) in [
            (1_800.0, 0.0, 150.0),
            (3_600.0, 0.0, 300.0),
            (3_600.0, 150.0, 150.0),
            (-1.0, 0.0, -1.0),
            (7_201.0, 0.0, -1.0),
            (1_800.0, 200.0, -1.0)
        ] {
            let samples = try alphaSamples(
                PrototypeNowMarker(
                    start: start, now: start.addingTimeInterval(nowOffset), timelineOffset: scrollOffset
                ),
                size: CGSize(width: 600, height: PrototypeNowMarker.size.height),
                points: [(0, 4), (150, 4), (300, 4), (599, 4)]
            )
            XCTAssertEqual(
                samples.map { $0 > 190 }, [0.0, 150.0, 300.0, 599.0].map { $0 == visibleX },
                "time: \(nowOffset), scroll: \(scrollOffset), alpha: \(samples)"
            )
        }
    }

    func testNoGuideRowFillTracksVisibleTimeAndClampsInBothDirections() throws {
        let width: CGFloat = 1_000
        let timelineWidth = PrototypeLayout.timelineWidth(for: width)
        let timelineOrigin = width - timelineWidth
        let positions = [80.0, timelineWidth / 2, timelineWidth - 80]
        for direction in [LayoutDirection.leftToRight, .rightToLeft] {
            for nowOffset: TimeInterval in [-3_600, 1_800, 36_000] {
                for offset: CGFloat in [0, 120] {
                    let fillEnd = timelineWidth * nowOffset / 7_200 - offset
                    let samples = try alphaSamples(
                        GuideRowFixture(
                            programs: [], start: start, nowOffset: nowOffset,
                            width: width, timelineOffset: offset
                        )
                        .environment(\.layoutDirection, direction)
                        .environment(\.themePalette, ThemePalette.dark),
                        size: CGSize(width: width, height: PrototypeLayout.rowHeight),
                        points: positions.map { x in
                            let logicalX = timelineOrigin + x
                            return (
                                Int(direction == .leftToRight ? logicalX : width - logicalX - 1),
                                Int(PrototypeLayout.rowHeight - 20)
                            )
                        }
                    )
                    XCTAssertEqual(
                        samples.map { $0 > 0 }, positions.map { $0 < fillEnd },
                        "\(direction), time: \(nowOffset), scroll: \(offset), alpha: \(samples)"
                    )
                    XCTAssertTrue(samples.allSatisfy { $0 < 30 })
                }
            }
        }
    }

    func testNoGuideAndMissingListingFillEndsAtTheCurrentTime() async throws {
        let width: CGFloat = 1_000
        let timelineWidth = PrototypeLayout.timelineWidth(for: width)
        let lineX = width - timelineWidth + timelineWidth / 4
        for programs in [[], [program("Later", from: 3_600, to: 21_600)]] {
            let samples = try await hostedAlphaSamples(
                GuideRowFixture(programs: programs, start: start, nowOffset: 1_800, width: width)
                    .environment(\.themePalette, ThemePalette.dark),
                size: CGSize(width: width, height: PrototypeLayout.rowHeight),
                points: [(Int(lineX - 4), Int(PrototypeLayout.rowHeight - 20)),
                         (Int(lineX + 4), Int(PrototypeLayout.rowHeight - 20))]
            )
            XCTAssertEqual(samples.map { $0 > 0 }, [true, false], "\(samples), listings: \(programs.count)")
        }
    }

    func testCompactChannelOnlyRowsDoNotInventProgressWithoutATimeRuler() throws {
        let samples = try alphaSamples(
            GuideRowFixture(programs: [], start: start, nowOffset: 1_800, width: 600)
                .environment(\.themePalette, ThemePalette.dark),
            size: CGSize(width: 600, height: PrototypeLayout.rowHeight + PrototypeLayout.gap),
            points: [(400, Int(PrototypeLayout.rowHeight - 20))]
        )
        XCTAssertEqual(samples, [0])
    }

    func testElapsedProgramFillHasASubtleLeadingEdgeAndClampsToTheCell() throws {
        for (elapsed, expected) in [
            (-40.0, [false, false, false]),
            (80.0, [true, false, false]),
            (400.0, [true, true, true])
        ] {
            let samples = try alphaSamples(
                PrototypeElapsedProgramFill(elapsedWidth: elapsed)
                    .environment(\.themePalette, ThemePalette.dark),
                size: CGSize(width: 200, height: 100),
                points: [(40, 50), (100, 50), (180, 50)]
            )
            XCTAssertEqual(samples.map { $0 > 0 }, expected)
            XCTAssertTrue(samples.allSatisfy { $0 < 30 })
        }
    }

    func testElapsedFillAndNowMarkerFollowRightToLeftTimeDirection() throws {
        let fill = try alphaSamples(
            PrototypeElapsedProgramFill(elapsedWidth: 80)
                .environment(\.layoutDirection, .rightToLeft),
            size: CGSize(width: 200, height: 100),
            points: [(40, 50), (100, 50), (180, 50)]
        )
        XCTAssertEqual(fill.map { $0 > 0 }, [false, false, true])
        let marker = try alphaSamples(
            PrototypeNowMarker(start: start, now: start.addingTimeInterval(1_800), timelineOffset: 50)
                .environment(\.layoutDirection, .rightToLeft)
                .frame(maxHeight: .infinity, alignment: .top),
            size: CGSize(width: 600, height: 400),
            points: [(99, 4), (499, 4), (499, 60)]
        )
        XCTAssertEqual(marker.map { $0 > 0 }, [false, true, false])
    }

    func testAlphaSamplerReadsTopToBottomScreenCoordinates() throws {
        let samples = try alphaSamples(
            VStack(spacing: 0) {
                Color.black.opacity(0.2)
                Color.black.opacity(0.8)
            },
            size: CGSize(width: 100, height: 100),
            points: [(50, 10), (50, 90)]
        )
        XCTAssertEqual(Double(samples[0]), 51, accuracy: 1)
        XCTAssertEqual(Double(samples[1]), 204, accuracy: 1)
    }

    private func alphaSamples<V: View>(
        _ view: V, size: CGSize, points: [(Int, Int)]
    ) throws -> [UInt8] {
        let width = Int(size.width)
        let height = Int(size.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(
                data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ))
            var didRender = false
            UITraitCollection(accessibilityContrast: .normal).performAsCurrent {
                let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
                renderer.render(rasterizationScale: 1) { renderedSize, draw in
                    XCTAssertEqual(renderedSize, size)
                    draw(context)
                    didRender = true
                }
            }
            XCTAssertTrue(didRender)
        }
        return points.map { x, y in pixels[(y * width + x) * 4 + 3] }
    }

    private func hostedAlphaSamples<V: View>(
        _ view: V, size: CGSize, points: [(Int, Int)]
    ) async throws -> [UInt8] {
        let controller = UIHostingController(rootView: view.frame(width: size.width, height: size.height))
        controller.safeAreaRegions = []
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.backgroundColor = .clear
        window.rootViewController = controller
        controller.view.backgroundColor = .clear
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        controller.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            controller.view.layer.render(in: context.cgContext)
        }
        let pixels = try rgbaPixels(XCTUnwrap(image.cgImage))
        return points.map { x, y in pixels[(y * Int(size.width) + x) * 4 + 3] }
    }

    func testScrollFadesRampOnlyWhereContentExtendsPastTheViewport() {
        let atStart = PrototypeScrollFade(before: 0, after: 2_000)
        XCTAssertEqual(atStart.leading, 0)
        XCTAssertEqual(atStart.trailing, 1)
        let halfway = PrototypeScrollFade(before: 12, after: 12, distance: 24)
        XCTAssertEqual(halfway.leading, 0.5)
        XCTAssertEqual(halfway.trailing, 0.5)
        let atEnd = PrototypeScrollFade(before: 2_000, after: 0)
        XCTAssertEqual(atEnd.leading, 1)
        XCTAssertEqual(atEnd.trailing, 0)
        let fitting = PrototypeScrollFade(before: -10, after: -40)
        XCTAssertEqual(fitting.leading, 0)
        XCTAssertEqual(fitting.trailing, 0)
    }

    func testProgrammeSurfacesMatchTheFullStationPlateHeight() {
        for rowHeight in [PrototypeLayout.rowHeight, PrototypeLayout.rowHeight * 2] {
            let cellHeight = PrototypeLayout.programHeight(in: rowHeight)
            XCTAssertEqual(cellHeight, rowHeight)
            for selected in [false, true] {
                let button = Button {} label: {
                    PrototypeProgramLabel(program: program("Current show", from: 0, to: 3_600), now: start)
                        .frame(width: 400, height: cellHeight, alignment: .leading)
                }
                .buttonStyle(PrototypeButtonStyle(selected: selected, padded: false, surface: .program))
                let size = UIHostingController(rootView: button)
                    .sizeThatFits(in: CGSize(width: 600, height: 600))
                XCTAssertEqual(size.height, rowHeight, accuracy: 0.5)
            }
        }
        XCTAssertEqual(PrototypeLayout.programInset, 0)
        XCTAssertEqual(PrototypeLayout.programRadius, PrototypeLayout.rowRadius)
        XCTAssertGreaterThanOrEqual(PrototypeLayout.rowGap, 16)
    }

    func testNavigationRailInsetsContentWithoutShrinkingVideo() {
        let size = CGSize(width: 1_740, height: 960)
        let insets = EdgeInsets(top: 60, leading: 90, bottom: 60, trailing: 90)
        let plain = PrototypePreviewLayout(size: size, safeAreaInsets: insets)
        let rail = PrototypePreviewLayout(size: size, safeAreaInsets: insets, navigationInset: 112)
        XCTAssertEqual(rail.bounds, plain.bounds)
        XCTAssertEqual(rail.videoFrame, plain.videoFrame)
        #if os(tvOS)
        XCTAssertEqual(rail.contentFrame.minX - plain.contentFrame.minX, 112 + 90 - 32, accuracy: 0.5)
        #else
        XCTAssertEqual(rail.contentFrame.minX - plain.contentFrame.minX, 112, accuracy: 0.5)
        #endif
        XCTAssertEqual(rail.contentFrame.maxX, plain.contentFrame.maxX, accuracy: 0.5)
    }

    func testExtraLeadingClearanceOnlyAppliesToVisiblePinnedNavigation() {
        #if os(tvOS)
        for safeLeading: CGFloat in [0, 90] {
            let insets = EdgeInsets(top: 60, leading: safeLeading, bottom: 60, trailing: safeLeading)
            let normal = PrototypePreviewLayout(size: CGSize(width: 1_740, height: 960), safeAreaInsets: insets)
            let pinned = PrototypePreviewLayout(
                size: CGSize(width: 1_740, height: 960), safeAreaInsets: insets, navigationInset: 64
            )
            let hiddenForSearch = PrototypePreviewLayout(
                size: CGSize(width: 1_740, height: 960), safeAreaInsets: insets, isSearching: true
            )
            XCTAssertEqual(normal.contentFrame.minX - normal.bounds.minX, 32)
            XCTAssertGreaterThanOrEqual(
                pinned.contentFrame.minX - normal.contentFrame.minX,
                64 + PrototypeLayout.inset
            )
            XCTAssertEqual(pinned.contentFrame.minX - pinned.bounds.minX, max(64, safeLeading) + 64)
            XCTAssertEqual(pinned.contentFrame.maxX, normal.contentFrame.maxX)
            XCTAssertEqual(pinned.videoFrame, normal.videoFrame)
            XCTAssertEqual(hiddenForSearch.contentFrame, normal.contentFrame)
        }
        #endif
    }

    func testTVLayoutLeavesRoomForFourRoomyRows() {
        #if os(tvOS)
        let layout = PrototypePreviewLayout(
            size: CGSize(width: 1_740, height: 960),
            safeAreaInsets: EdgeInsets(top: 60, leading: 90, bottom: 60, trailing: 90)
        )
        let toolbarAndRuler: CGFloat = 44
        let spacing = PrototypeLayout.sectionGap + PrototypeLayout.guideInset * 2
            + PrototypeLayout.gap + PrototypeLayout.smallGap * 2
        let listHeight = layout.contentFrame.height - layout.heroHeight - toolbarAndRuler - spacing
        let visibleRows = listHeight / (PrototypeLayout.rowHeight + PrototypeLayout.rowGap)
        XCTAssertGreaterThanOrEqual(visibleRows, 4)
        XCTAssertLessThan(visibleRows, 5)
        XCTAssertGreaterThanOrEqual(PrototypeLayout.rowHeight, 100)
        #endif
    }

    func testWideGuideReservesSpaceForPinnedControlsWithoutShrinkingVideo() {
        for size in [CGSize(width: 1_920, height: 1_080), CGSize(width: 1_024, height: 768)] {
            let layout = PrototypePreviewLayout(size: size)
            XCTAssertGreaterThan(layout.sidebarWidth, 0)
            XCTAssertEqual(
                layout.sidebarWidth + PrototypeLayout.sectionGap + layout.guideWidth,
                layout.contentFrame.width, accuracy: 0.01
            )
            XCTAssertGreaterThanOrEqual(layout.guideWidth - PrototypeLayout.guideInset * 2, 650)
            XCTAssertEqual(layout.videoFrame.width, layout.bounds.width)
        }
    }

    func testCompactOrShortWindowsKeepPinnedHorizontalControls() {
        for size in [
            CGSize(width: 390, height: 844),
            CGSize(width: 700, height: 750),
            CGSize(width: 1_024, height: 500)
        ] {
            let layout = PrototypePreviewLayout(size: size)
            XCTAssertEqual(layout.sidebarWidth, 0)
            XCTAssertEqual(layout.guideWidth, layout.contentFrame.width)
        }
    }

    func testSearchTransformationKeepsVideoAnchoredAndGivesTheGuideMoreRoom() {
        for size in [CGSize(width: 1_920, height: 1_080), CGSize(width: 1_024, height: 768), CGSize(width: 390, height: 844)] {
            let browsing = PrototypePreviewLayout(size: size)
            let searching = PrototypePreviewLayout(size: size, isSearching: true)
            XCTAssertEqual(searching.videoFrame, browsing.videoFrame)
            XCTAssertEqual(searching.contentFrame, browsing.contentFrame)
            XCTAssertEqual(searching.fadeEnd, browsing.fadeEnd)
            XCTAssertLessThanOrEqual(searching.heroHeight, browsing.heroHeight)
            XCTAssertGreaterThan(searching.heroHeight, 0)
        }
    }

    func testSidebarFitsWithLongAndScrollableCategoryLists() {
        let widths: [CGFloat] = [224, 272]
        for width in widths {
            for direction in [LayoutDirection.leftToRight, .rightToLeft] {
                let fixture = SidebarFixture()
                    .environment(\.layoutDirection, direction)
                    .dynamicTypeSize(.large)
                let size = UIHostingController(rootView: fixture)
                    .sizeThatFits(in: CGSize(width: width, height: 600))
                XCTAssertLessThanOrEqual(size.width, width + 0.5)
                XCTAssertLessThanOrEqual(size.height, 600.5)
                XCTAssertGreaterThan(size.height, 400)
            }
        }
    }

    func testGuideAndLogoCornersStayConcentric() {
        XCTAssertEqual(PrototypeLayout.guideRadius, PrototypeLayout.rowRadius + PrototypeLayout.guideInset)
        XCTAssertEqual(PrototypeLayout.rowRadius, PrototypeLayout.logoRadius + PrototypeLayout.rowInset)
        XCTAssertEqual(PrototypeLayout.rowHeight, PrototypeLayout.stationSize + PrototypeLayout.rowInset * 2)
        XCTAssertEqual(PrototypeLayout.stationArtworkInset, PrototypeLayout.guideInset + 8)
        XCTAssertEqual(
            PrototypeLayout.controlGroupRadius,
            PrototypeLayout.controlRadius + PrototypeLayout.controlInset
        )
    }

    func testStationAndTimelineAlwaysShareTheSameAvailableWidth() {
        let widths: [CGFloat] = [650, 700, 1_100, 1_400, 1_832]
        for width in widths {
            XCTAssertEqual(
                PrototypeLayout.stationWidth(for: width)
                    + PrototypeLayout.columnGap + PrototypeLayout.timelineWidth(for: width),
                width, accuracy: 0.01
            )
        }
    }

    func testControlGroupFitsCompactAndWideLayoutsWithLongFilters() {
        let widths: [CGFloat] = [320, 390, 700, 1_440]
        for width in widths {
            let fixture = ToolbarFixture(compact: width < 650)
                .dynamicTypeSize(.large)
            let size = UIHostingController(rootView: fixture)
                .sizeThatFits(in: CGSize(width: width, height: 300))
            #if os(tvOS)
            if width < 650 || width >= 1_400 {
                XCTAssertLessThanOrEqual(size.width, width + 0.5)
            }
            #else
            XCTAssertLessThanOrEqual(size.width, width + 0.5)
            #endif
            XCTAssertGreaterThanOrEqual(size.height, PrototypeLayout.controlHeight)
        }
    }

    func testCompactAndAccessibilityLayoutsKeepTheGuideInBounds() {
        for size in [CGSize(width: 390, height: 750), CGSize(width: 700, height: 500)] {
            let layout = PrototypePreviewLayout(size: size, largeText: true)
            XCTAssertGreaterThan(layout.contentFrame.width, 0)
            XCTAssertGreaterThan(layout.contentFrame.height - layout.heroHeight, 200)
            XCTAssertLessThanOrEqual(layout.metadataWidth, layout.contentFrame.width)
            XCTAssertLessThanOrEqual(layout.contentFrame.maxY, layout.bounds.maxY)
        }
    }

    func testFocusedLogoHasContrastingEdgesOnBothWhiteAndBlackWithoutAGutter() throws {
        let width = Int(PrototypeLayout.stationColumnWidth)
        let height = Int(PrototypeLayout.rowHeight)
        for background in [Color.white, .black] {
            for lineWidth: CGFloat in [3.5, 4] {
                let shape = RoundedRectangle(cornerRadius: PrototypeLayout.rowRadius, style: .continuous)
                let renderer = ImageRenderer(content:
                    shape.fill(background)
                        .overlay { PrototypeFocusOutline(cornerRadius: PrototypeLayout.rowRadius, lineWidth: lineWidth) }
                        .frame(width: CGFloat(width), height: CGFloat(height))
                )
                renderer.scale = 1
                let image = try XCTUnwrap(renderer.cgImage)
                XCTAssertEqual(image.width, width)
                XCTAssertEqual(image.height, height)
                let pixels = try rgbaPixels(image)
                let outer = (height / 2 * width + 1) * 4
                let inner = (height / 2 * width + 5) * 4
                for component in 0..<3 {
                    XCTAssertGreaterThan(pixels[outer + component], 240)
                    XCTAssertLessThan(pixels[inner + component], 40)
                }
                XCTAssertEqual(pixels[outer + 3], 255)
                XCTAssertEqual(pixels[inner + 3], 255)
            }
        }
    }

    private func rgbaPixels(_ image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(
                data: bytes.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return pixels
    }

    func testEnlargedLogoKeepsItsFixedSlotWithMissingArtwork() {
        let channel = LiveTVPrototypeChannel(
            id: "missing-logo", number: 1, name: "Test station",
            category: "News", symbol: "tv", accent: 0, source: .iptv, tagline: ""
        )
        let size = UIHostingController(rootView: PrototypeStationMark(channel: channel, size: 64))
            .sizeThatFits(in: CGSize(width: 400, height: 400))
        XCTAssertEqual(size.width, 112, accuracy: 0.5)
        XCTAssertEqual(size.height, 64, accuracy: 0.5)
    }

    private func program(
        _ title: String,
        from: TimeInterval,
        to: TimeInterval
    ) -> LiveTVPrototypeProgram {
        LiveTVPrototypeProgram(
            id: title, channelID: "station", title: title, subtitle: "",
            start: start.addingTimeInterval(from), end: start.addingTimeInterval(to)
        )
    }

    private func height(
        programs: [LiveTVPrototypeProgram],
        locale: String = "en_US",
        typeSize: DynamicTypeSize = .large
    ) -> CGFloat {
        let view = GuideRowFixture(programs: programs, start: start)
            .environment(\.locale, Locale(identifier: locale))
            .dynamicTypeSize(typeSize)
        return UIHostingController(rootView: view)
            .sizeThatFits(in: CGSize(width: 1_400, height: 1_000))
            .height
    }
}

private struct GuideRowFixture: View {
    let programs: [LiveTVPrototypeProgram]
    let start: Date
    var nowOffset: TimeInterval = 2_500
    var width: CGFloat = 1_400
    var timelineOffset: CGFloat = 0
    @FocusState private var focus: PrototypeBrowseFocus?

    private let channel = LiveTVPrototypeChannel(
        id: "station", number: 28, name: "Test station", category: "Kids",
        symbol: "tv", accent: 0, source: .iptv, tagline: ""
    )

    var body: some View {
        PrototypeGuideRow(
            channel: channel, programs: programs, start: start,
            now: start.addingTimeInterval(nowOffset), width: width,
            timelineOffset: .constant(timelineOffset), focus: $focus, railActive: false,
            returnTarget: nil, favorite: false, playing: false,
            toggleFavorite: {}, tune: {}, details: { _ in },
            controls: {}, top: {}, goToNow: {}
        )
    }
}

private struct ToolbarFixture: View {
    let compact: Bool
    @State private var active = false
    private let model: LiveTVPrototypeModel = {
        let model = LiveTVPrototypeModel(now: Date(), scenario: .noGuide, channels: [])
        model.category = "Documentaries and international entertainment"
        return model
    }()

    var body: some View {
        PrototypeBrowseToolbar(
            model: model, active: $active, focusRequest: 0, compact: compact,
            search: {}, filters: {}
        )
    }
}

private struct SidebarFixture: View {
    @State private var active = false
    private let model = LiveTVPrototypeModel(
        now: Date(), scenario: .noGuide,
        channels: (1 ... 30).map { number in
            LiveTVPrototypeChannel(
                id: "sidebar-\(number)", number: number, name: "Channel \(number)",
                category: "Documentaries and entertainment \(number)",
                symbol: "tv", accent: 0, source: .iptv, tagline: ""
            )
        }
    )

    var body: some View {
        PrototypeBrowseSidebar(model: model, active: $active, focusRequest: 0, search: {}, enterGuide: {})
    }
}
#endif
