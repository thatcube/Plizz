#if DEBUG
import FeatureLiveTVCore
import SwiftUI
import XCTest
@testable import FeatureLiveTV

final class LiveTVMultiviewGeometryTests: XCTestCase {
    private let sizes = [
        CGSize(width: 1920, height: 1080), CGSize(width: 1760, height: 960),
        CGSize(width: 390, height: 844), CGSize(width: 844, height: 390),
        CGSize(width: 768, height: 1024), CGSize(width: 1440, height: 1080)
    ]

    func testSideBySideAndPortraitSlotsConsumeTheEntireCanvas() {
        let panes = [UUID(), UUID()]
        for size in sizes {
            let pictures = panes.map {
                LiveTVMultiviewGeometry.frame(
                    for: $0, panes: panes, primary: panes[0], layout: .sideBySide,
                    corner: .bottomTrailing, insetSize: .medium, expanded: nil, size: size
                )
            }
            XCTAssertTrue(pictures[0].intersection(pictures[1]).isEmpty)
            XCTAssertEqual(pictures[0].union(pictures[1]), CGRect(origin: .zero, size: size))
            for (id, picture) in zip(panes, pictures) {
                XCTAssertTrue(CGRect(origin: .zero, size: size).contains(picture))
                XCTAssertEqual(picture.width, size.width >= size.height ? size.width / 2 : size.width, accuracy: 0.001)
                XCTAssertEqual(picture.height, size.width >= size.height ? size.height : size.height / 2, accuracy: 0.001)
                XCTAssertEqual(LiveTVMultiviewGeometry.focusFrame(
                    for: id, panes: panes, primary: panes[0], layout: .sideBySide,
                    corner: .bottomTrailing, insetSize: .medium, expanded: nil, size: size,
                    chromeVisible: false
                ), LiveTVMultiviewGeometry.contentFrame(in: picture, aspectRatio: nil))
            }
            if size.width >= size.height {
                XCTAssertEqual(pictures[0].minX, 0, accuracy: 0.001)
                XCTAssertEqual(pictures[0].maxX, pictures[1].minX, accuracy: 0.001)
                XCTAssertEqual(pictures[1].maxX, size.width, accuracy: 0.001)
                XCTAssertEqual(pictures[0].minY, 0)
                XCTAssertEqual(pictures[1].maxY, size.height)
            } else {
                XCTAssertEqual(pictures[0].minY, 0, accuracy: 0.001)
                XCTAssertEqual(pictures[0].maxY, pictures[1].minY, accuracy: 0.001)
                XCTAssertEqual(pictures[1].maxY, size.height, accuracy: 0.001)
                XCTAssertEqual(pictures[0].minX, 0)
                XCTAssertEqual(pictures[1].maxX, size.width)
            }
        }
    }

    func testCornerPrimaryUsesFullCanvasWhileInsetKeepsPresentationAspect() {
        let panes = [UUID(), UUID()]
        for size in sizes {
            let canvas = CGRect(origin: .zero, size: size)
            for corner in LiveTVMultiviewCorner.allCases {
                for insetSize in LiveTVMultiviewInsetSize.allCases {
                    let main = LiveTVMultiviewGeometry.frame(
                        for: panes[0], panes: panes, primary: panes[0], layout: .corner,
                        corner: corner, insetSize: insetSize, expanded: nil, size: size
                    )
                    let inset = LiveTVMultiviewGeometry.frame(
                        for: panes[1], panes: panes, primary: panes[0], layout: .corner,
                        corner: corner, insetSize: insetSize, expanded: nil, size: size
                    )
                    XCTAssertEqual(main, canvas)
                    XCTAssertTrue(main.contains(inset))
                    let insetCanvasWidth = min(size.width, size.height * 16 / 9)
                    XCTAssertEqual(inset.width, insetCanvasWidth * CGFloat(insetSize.fraction), accuracy: 0.001)
                    XCTAssertEqual(inset.width / inset.height, 16 / 9, accuracy: 0.001)
                }
            }
        }
    }

    func testPhysicalBoundsRetainNegativeSafeAreaOriginForVideoAndOverlay() {
        let id = UUID()
        let layout = PrototypePreviewLayout(
            size: CGSize(width: 1760, height: 960),
            safeAreaInsets: EdgeInsets(top: 60, leading: 80, bottom: 60, trailing: 80)
        )
        let picture = LiveTVMultiviewGeometry.frame(
            for: id, panes: [id], primary: id, layout: .sideBySide,
            corner: .bottomTrailing, insetSize: .medium, expanded: nil, size: layout.bounds.size
        ).offsetBy(dx: layout.bounds.minX, dy: layout.bounds.minY)
        XCTAssertEqual(layout.bounds, CGRect(x: -80, y: -60, width: 1920, height: 1080))
        XCTAssertEqual(picture, layout.bounds)
        XCTAssertEqual(
            LiveTVMultiviewGeometry.viewport(in: layout.bounds.size)
                .offsetBy(dx: layout.bounds.minX, dy: layout.bounds.minY),
            picture
        )
    }

    func testOnlyVisibleChromeReservesFocusBandsNotVideoMargins() {
        for size in sizes {
            let canvas = CGRect(origin: .zero, size: size)
            let focusArea = LiveTVMultiviewGeometry.focusViewport(in: size, chromeVisible: true)
            XCTAssertEqual(LiveTVMultiviewGeometry.viewport(in: size), canvas)
            XCTAssertEqual(LiveTVMultiviewGeometry.focusViewport(in: size, chromeVisible: false), canvas)
            XCTAssertTrue(canvas.contains(focusArea))
            XCTAssertEqual(focusArea.minX, 0)
            XCTAssertEqual(focusArea.maxX, size.width)
            XCTAssertGreaterThan(focusArea.minY, canvas.minY)
            XCTAssertLessThan(focusArea.maxY, canvas.maxY)
            #if os(tvOS)
            if size.height >= 960 {
                let header = CGRect(x: 80, y: 60, width: size.width - 160, height: 74)
                let toolbar = CGRect(x: 80, y: size.height - 142, width: size.width - 160, height: 90)
                XCTAssertFalse(focusArea.intersects(header))
                XCTAssertFalse(focusArea.intersects(toolbar))
            }
            #endif
        }
    }

    func testCornerFocusAndCaptionRegionsRemainDisjointWithChromeShownOrHidden() {
        let panes = [UUID(), UUID()]
        for size in sizes {
            for primary in panes {
                let secondary = panes.first { $0 != primary }!
                for corner in LiveTVMultiviewCorner.allCases {
                    for insetSize in LiveTVMultiviewInsetSize.allCases {
                        let main = LiveTVMultiviewGeometry.frame(
                            for: primary, panes: panes, primary: primary, layout: .corner,
                            corner: corner, insetSize: insetSize, expanded: nil, size: size
                        )
                        let inset = LiveTVMultiviewGeometry.frame(
                            for: secondary, panes: panes, primary: primary, layout: .corner,
                            corner: corner, insetSize: insetSize, expanded: nil, size: size
                        )
                        for chromeVisible in [false, true] {
                            let mainFocus = LiveTVMultiviewGeometry.focusFrame(
                                for: primary, panes: panes, primary: primary, layout: .corner,
                                corner: corner, insetSize: insetSize, expanded: nil, size: size,
                                chromeVisible: chromeVisible
                            )
                            let insetFocus = LiveTVMultiviewGeometry.focusFrame(
                                for: secondary, panes: panes, primary: primary, layout: .corner,
                                corner: corner, insetSize: insetSize, expanded: nil, size: size,
                                chromeVisible: chromeVisible
                            )
                            let context = "\(size), \(corner), \(insetSize), chrome \(chromeVisible)"
                            XCTAssertGreaterThan(mainFocus.width, 0, context)
                            XCTAssertGreaterThan(mainFocus.height, 0, context)
                            XCTAssertGreaterThan(insetFocus.width, 0, context)
                            XCTAssertGreaterThan(insetFocus.height, 0, context)
                            XCTAssertTrue(main.insetBy(dx: -0.001, dy: -0.001).contains(mainFocus), context)
                            XCTAssertTrue(inset.insetBy(dx: -0.001, dy: -0.001).contains(insetFocus), context)
                            XCTAssertFalse(mainFocus.intersects(insetFocus), context)
                            XCTAssertLessThan(mainFocus.minY, insetFocus.maxY, context)
                            XCTAssertGreaterThan(mainFocus.maxY, insetFocus.minY, context)
                            if corner == .topLeading || corner == .bottomLeading {
                                XCTAssertEqual(mainFocus.minX - insetFocus.maxX, 16, accuracy: 0.001, context)
                            } else {
                                XCTAssertEqual(insetFocus.minX - mainFocus.maxX, 16, accuracy: 0.001, context)
                            }
                        }
                    }
                }
            }
        }
    }

    func testSingleAndExpandedPlayersReceiveFullCanvasAndHiddenChromeFocusRegion() {
        let panes = [UUID(), UUID()]
        for size in sizes {
            let canvas = CGRect(origin: .zero, size: size)
            for layout in LiveTVMultiviewLayout.allCases {
                XCTAssertEqual(LiveTVMultiviewGeometry.frame(
                    for: panes[0], panes: [panes[0]], primary: panes[0], layout: layout,
                    corner: .bottomTrailing, insetSize: .large, expanded: nil, size: size
                ), canvas)
                for expanded in panes {
                    let picture = LiveTVMultiviewGeometry.frame(
                        for: expanded, panes: panes, primary: panes[0], layout: layout,
                        corner: .bottomTrailing, insetSize: .large, expanded: expanded, size: size
                    )
                    XCTAssertEqual(picture, canvas)
                    XCTAssertEqual(LiveTVMultiviewGeometry.focusFrame(
                        for: expanded, panes: panes, primary: panes[0], layout: layout,
                        corner: .bottomTrailing, insetSize: .large, expanded: expanded, size: size,
                        chromeVisible: false
                    ), LiveTVMultiviewGeometry.contentFrame(in: picture, aspectRatio: nil))
                }
            }
        }
    }

    func testChromeEditingLatchSurvivesNativeMenuActivityUntilPaneFocus() {
        var chrome = LiveTVMultiviewChromeState()
        chrome.activity(at: 1)
        XCTAssertTrue(chrome.canAutoHide(blocked: false))
        chrome.editing(at: 2)
        chrome.activity(at: 20)
        XCTAssertTrue(chrome.isVisible)
        XCTAssertTrue(chrome.isEditing)
        XCTAssertFalse(chrome.canAutoHide(blocked: false))
        chrome.watching(at: 21)
        XCTAssertFalse(chrome.isEditing)
        XCTAssertTrue(chrome.canAutoHide(blocked: false))
        XCTAssertEqual(chrome.inactivity.remainingDelay(startedAt: 21, now: 24), 1)
        chrome.hide()
        XCTAssertFalse(chrome.isVisible)
        XCTAssertFalse(chrome.isEditing)
        XCTAssertFalse(chrome.canAutoHide(blocked: false))
        chrome.activity(at: 30)
        XCTAssertTrue(chrome.isVisible)
    }

    func testVoiceOverPickerAndErrorBlockingPreventsChromeAutoHide() {
        var chrome = LiveTVMultiviewChromeState()
        chrome.watching(at: 1)
        XCTAssertFalse(chrome.canAutoHide(blocked: true))
        XCTAssertTrue(chrome.canAutoHide(blocked: false))
        chrome.editing(at: 2)
        XCTAssertFalse(chrome.canAutoHide(blocked: true))
        XCTAssertFalse(chrome.canAutoHide(blocked: false))
    }

    func testNativeMenuFocusActivityDoesNotPublishAnyStateChangesWhileEditing() {
        var chrome = LiveTVMultiviewChromeState()
        chrome.editing(at: 1)
        let pinned = chrome
        for event in 2...1_000 {
            chrome.activity(at: TimeInterval(event))
            chrome.editing(at: TimeInterval(event))
            XCTAssertEqual(chrome, pinned, "Native menu focus must not redraw its own anchor")
        }
        chrome.watching(at: 1_001)
        XCTAssertEqual(chrome.inactivity.lastInteractionAt, 1_001)
        XCTAssertTrue(chrome.canAutoHide(blocked: false))
    }

    func testThreeAndFourChannelGridsCoverCanvasWithoutOverlap() {
        for count in 3...4 {
            let panes = (0..<count).map { _ in UUID() }
            for size in sizes {
                let frames = panes.map {
                    LiveTVMultiviewGeometry.frame(
                        for: $0, panes: panes, primary: panes[0], layout: .sideBySide,
                        corner: .bottomTrailing, insetSize: .medium, expanded: nil, size: size)
                }
                XCTAssertEqual(frames.reduce(CGRect.null) { $0.union($1) }, CGRect(origin: .zero, size: size))
                for index in frames.indices {
                    XCTAssertGreaterThan(frames[index].width, 0)
                    for other in frames.indices where other > index {
                        XCTAssertFalse(frames[index].intersects(frames[other]))
                    }
                }
            }
        }
    }

    func testFourCornerPicturesAndFocusTargetsStayReachableWithoutOverlapping() {
        let panes = (0..<4).map { _ in UUID() }
        for size in sizes {
            for corner in LiveTVMultiviewCorner.allCases {
                for editing in [true, false] {
                    let frames = panes.map {
                        LiveTVMultiviewGeometry.frame(
                            for: $0, panes: panes, primary: panes[0], layout: .corner,
                            corner: corner, insetSize: .large, expanded: nil, size: size, isEditing: editing)
                    }
                    let focus = panes.map {
                        LiveTVMultiviewGeometry.focusFrame(
                            for: $0, panes: panes, primary: panes[0], layout: .corner,
                            corner: corner, insetSize: .large, expanded: nil, size: size,
                            chromeVisible: false, isEditing: editing)
                    }
                    for index in focus.indices {
                        XCTAssertFalse(focus[index].isEmpty)
                        XCTAssertTrue(frames[index].insetBy(dx: -0.01, dy: -0.01).contains(focus[index]))
                        for other in focus.indices where other > index {
                            XCTAssertFalse(focus[index].intersects(focus[other]))
                        }
                    }
                }
            }
        }
    }

    func testSetupFocusHugsActualVideoAspectInsteadOfTheFullScreenSlot() {
        let panes = [UUID(), UUID()]
        let size = CGSize(width: 1920, height: 1080)
        for ratio in [CGFloat(4) / 3, CGFloat(16) / 9, CGFloat(21) / 9] {
            let frame = LiveTVMultiviewGeometry.frame(
                for: panes[0], panes: panes, primary: panes[0], layout: .sideBySide,
                corner: .bottomTrailing, insetSize: .medium, expanded: nil, size: size,
                isEditing: true, aspectRatio: ratio)
            let focus = LiveTVMultiviewGeometry.focusFrame(
                for: panes[0], panes: panes, primary: panes[0], layout: .sideBySide,
                corner: .bottomTrailing, insetSize: .medium, expanded: nil, size: size,
                chromeVisible: true, isEditing: true, aspectRatio: ratio)
            XCTAssertEqual(frame.width / frame.height, ratio, accuracy: 0.001)
            XCTAssertEqual(focus.minX, frame.minX, accuracy: 0.001)
            XCTAssertEqual(focus.minY, frame.minY, accuracy: 0.001)
            XCTAssertEqual(focus.width, frame.width, accuracy: 0.001)
            XCTAssertEqual(focus.height, frame.height, accuracy: 0.001)
            XCTAssertGreaterThan(frame.minX, 0)
            XCTAssertGreaterThan(frame.minY, 0)
            XCTAssertLessThan(frame.maxY, size.height)
        }
    }

    func testChannelShelvesUseRecentOrderAndExcludeMissingOrDuplicateRecords() {
        let channels = (1...4).map {
            LiveTVPrototypeChannel(
                id: "channel-\($0)", number: $0, name: "Channel \($0)", category: "Sports",
                symbol: "tv", accent: 0, source: .iptv, tagline: "")
        }
        let sections = LiveTVMultiviewChannelSections(
            channels: channels + [channels[0]], favoriteIDs: ["channel-2", "hidden"],
            recentChannelIDs: ["channel-3", "missing", "channel-1", "channel-3"])
        XCTAssertEqual(sections.recent.map(\.id), ["channel-3", "channel-1"])
        XCTAssertEqual(sections.favorites.map(\.id), ["channel-2"])
        XCTAssertEqual(sections.all.map(\.id), channels.map(\.id))
    }
}
#endif
