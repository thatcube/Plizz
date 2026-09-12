import XCTest
@testable import CoreModels

/// The generic reorder-and-hide model shared by the metadata-provider priority
/// list and the navigation-library arrangement.
final class OrderedVisibilityListTests: XCTestCase {
    private typealias Sections = OrderedVisibilityList.Sections<String>

    func testHideMovesToAbsoluteBottomButFocusStaysAtTheVacatedPosition() throws {
        let start = Sections(enabled: ["home", "search", "library", "settings"], disabled: ["oldHidden"])
        let edit = try XCTUnwrap(OrderedVisibilityList.applying(.hide, to: "search", in: start))
        XCTAssertEqual(edit.sections.enabled, ["home", "library", "settings"])
        XCTAssertEqual(edit.sections.disabled, ["oldHidden", "search"])
        XCTAssertEqual(edit.focusTarget, "library")
    }

    func testHidingLastVisibleItemFocusesPreviousInsteadOfFollowingToHiddenSection() throws {
        let start = Sections(enabled: ["settings", "library"], disabled: ["hidden"])
        let edit = try XCTUnwrap(OrderedVisibilityList.applying(.hide, to: "library", in: start))
        XCTAssertEqual(edit.focusTarget, "settings")
        XCTAssertEqual(edit.sections.disabled, ["hidden", "library"])
    }

    func testRepeatedHidingStaysInPlaceAcrossALongList() throws {
        var sections = Sections(enabled: ["settings"] + (1...100).map(String.init), disabled: ["hidden"])
        for index in 1...100 {
            let edit = try XCTUnwrap(OrderedVisibilityList.applying(.hide, to: String(index), in: sections))
            XCTAssertEqual(edit.focusTarget, index == 100 ? "settings" : String(index + 1))
            XCTAssertEqual(edit.sections.disabled.last, String(index))
            sections = edit.sections
        }
        XCTAssertEqual(sections.enabled, ["settings"])
        XCTAssertEqual(sections.disabled.count, 101)
    }

    func testMenuMovesFollowItemAndNeverChangeVisibility() throws {
        let start = Sections(enabled: ["a", "b", "settings"], disabled: ["x", "y"])
        let up = try XCTUnwrap(OrderedVisibilityList.applying(.moveUp, to: "b", in: start))
        XCTAssertEqual(up.sections.enabled, ["b", "a", "settings"])
        XCTAssertEqual(up.focusTarget, "b")
        let down = try XCTUnwrap(OrderedVisibilityList.applying(.moveDown, to: "x", in: start))
        XCTAssertEqual(down.sections.disabled, ["y", "x"])
        XCTAssertEqual(down.focusTarget, "x")
        XCTAssertNil(OrderedVisibilityList.applying(.moveUp, to: "a", in: start))
        XCTAssertNil(OrderedVisibilityList.applying(.moveDown, to: "settings", in: start))
        XCTAssertNil(OrderedVisibilityList.applying(.moveUp, to: "x", in: start))
        XCTAssertNil(OrderedVisibilityList.applying(.moveDown, to: "y", in: start))
    }

    func testShowRestoresAtEndOfVisibleItemsAndFollowsIt() throws {
        let start = Sections(enabled: ["a", "settings"], disabled: ["x", "y"])
        let edit = try XCTUnwrap(OrderedVisibilityList.applying(.show, to: "y", in: start))
        XCTAssertEqual(edit.sections, Sections(enabled: ["a", "settings", "y"], disabled: ["x"]))
        XCTAssertEqual(edit.focusTarget, "y")
    }

    func testRequiredItemCanMoveButCannotBeHiddenThroughAnyInteraction() throws {
        let start = Sections(enabled: ["a", "settings"], disabled: ["x"])
        let required: Set<String> = ["settings"]
        XCTAssertNil(OrderedVisibilityList.applying(.hide, to: "settings", in: start, keepingEnabled: required))
        XCTAssertEqual(OrderedVisibilityList.stepped("settings", up: false, in: start, keepingEnabled: required), start)
        XCTAssertEqual(
            OrderedVisibilityList.moving(fromOffsets: [1], toOffset: 4, in: start, keepingEnabled: required),
            start
        )
        let moved = try XCTUnwrap(
            OrderedVisibilityList.applying(.moveUp, to: "settings", in: start, keepingEnabled: required)
        )
        XCTAssertEqual(moved.sections.enabled, ["settings", "a"])
        XCTAssertEqual(moved.focusTarget, "settings")
    }

    func testMenuActionsRejectStaleItemsAndPreserveAnAllHiddenGenericList() throws {
        let start = Sections(enabled: ["a"], disabled: ["x"])
        for action in [OrderedVisibilityList.Action.hide, .show, .moveUp, .moveDown] {
            XCTAssertNil(OrderedVisibilityList.applying(action, to: "missing", in: start))
        }
        let edit = try XCTUnwrap(OrderedVisibilityList.applying(.hide, to: "a", in: start))
        XCTAssertEqual(edit.sections, Sections(enabled: [], disabled: ["x", "a"]))
        XCTAssertEqual(edit.focusTarget, "x")
    }

    // MARK: stepped (the tvOS lift-and-step interaction)

    func testStepUpRaisesPriority() {
        let start = Sections(enabled: ["a", "b", "c"], disabled: [])
        XCTAssertEqual(
            OrderedVisibilityList.stepped("c", up: true, in: start),
            Sections(enabled: ["a", "c", "b"], disabled: [])
        )
    }

    func testStepAtTheVeryTopOrBottomIsANoOp() {
        let start = Sections(enabled: ["a", "b"], disabled: ["z"])
        XCTAssertEqual(OrderedVisibilityList.stepped("a", up: true, in: start), start)
        XCTAssertEqual(OrderedVisibilityList.stepped("z", up: false, in: start), start)
    }

    func testSteppingDownAcrossTheDividerDisablesAtTheTopOfDisabled() {
        let start = Sections(enabled: ["a", "b"], disabled: ["z"])
        XCTAssertEqual(
            OrderedVisibilityList.stepped("b", up: false, in: start),
            Sections(enabled: ["a"], disabled: ["b", "z"])
        )
    }

    func testSteppingUpAcrossTheDividerEnablesAtTheBottomOfEnabled() {
        let start = Sections(enabled: ["a"], disabled: ["z", "y"])
        XCTAssertEqual(
            OrderedVisibilityList.stepped("z", up: true, in: start),
            Sections(enabled: ["a", "z"], disabled: ["y"])
        )
    }

    func testSteppingAnUnknownElementIsANoOp() {
        let start = Sections(enabled: ["a"], disabled: [])
        XCTAssertEqual(OrderedVisibilityList.stepped("nope", up: true, in: start), start)
    }

    // MARK: moving (the iOS drag interaction)

    func testDraggingAcrossTheDividerDisables() {
        let start = Sections(enabled: ["a", "b"], disabled: ["z"])
        // Flattened: [a, b, divider, z]; drop "a" at the end.
        let moved = OrderedVisibilityList.moving(fromOffsets: [0], toOffset: 4, in: start)
        XCTAssertEqual(moved, Sections(enabled: ["b"], disabled: ["z", "a"]))
    }

    func testDraggingTheDividerItselfIsRejected() {
        let start = Sections(enabled: ["a", "b"], disabled: ["z"])
        XCTAssertEqual(OrderedVisibilityList.moving(fromOffsets: [2], toOffset: 0, in: start), start)
    }

    func testDraggingIntoTheEmptyDisabledPlaceholderDisables() {
        let start = Sections(enabled: ["a", "b"], disabled: [])
        // Flattened: [a, b, divider, placeholder]; drop "b" at the very end.
        let moved = OrderedVisibilityList.moving(fromOffsets: [1], toOffset: 4, in: start)
        XCTAssertEqual(moved, Sections(enabled: ["a"], disabled: ["b"]))
    }

    // MARK: resolving

    func testResolvingAppendsUnknownElementsEnabledAndDropsStaleOnes() {
        let resolved = OrderedVisibilityList.resolving(
            available: ["a", "b", "c"],
            order: ["c", "gone", "a"],
            hidden: ["b", "alsoGone"]
        )
        XCTAssertEqual(resolved.enabled, ["c", "a"])
        XCTAssertEqual(resolved.disabled, ["b"])
    }

    func testResolvingIgnoresDuplicatesInThePersistedOrder() {
        let resolved = OrderedVisibilityList.resolving(
            available: ["a", "b"],
            order: ["b", "b", "a"],
            hidden: []
        )
        XCTAssertEqual(resolved.enabled, ["b", "a"])
    }

    // MARK: listItems

    func testListItemsInsertAPlaceholderOnlyWhenNothingIsDisabled() {
        XCTAssertEqual(
            OrderedVisibilityList.listItems(for: Sections(enabled: ["a"], disabled: [])),
            [.element("a"), .divider, .disabledPlaceholder]
        )
        XCTAssertEqual(
            OrderedVisibilityList.listItems(for: Sections(enabled: ["a"], disabled: ["z"])),
            [.element("a"), .divider, .element("z")]
        )
    }
}
