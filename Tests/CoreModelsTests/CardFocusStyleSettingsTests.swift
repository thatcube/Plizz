import XCTest
@testable import CoreModels

final class CardFocusStyleSettingsStoreTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "CardFocusStyleSettingsStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    /// New installs get the native treatment without visiting Settings.
    func testDefaultIsSystemWhenEmpty() {
        let store = CardFocusStyleSettingsStore(defaults: makeDefaults())
        XCTAssertEqual(store.load(), .system)
        XCTAssertEqual(CardFocusStyle.default, .system)
        XCTAssertEqual(CardFocusStyle.allCases, [.system, .highlight, .outlined])
    }

    func testOnlyTheOutlinedStyleDrawsAnOutline() {
        XCTAssertTrue(CardFocusStyle.outlined.drawsFocusOutline)
        XCTAssertFalse(CardFocusStyle.highlight.drawsFocusOutline)
        XCTAssertFalse(CardFocusStyle.system.drawsFocusOutline)
        XCTAssertTrue(CardFocusStyle.system.usesSystemEffect)
        XCTAssertFalse(CardFocusStyle.highlight.usesSystemEffect)
        XCTAssertFalse(CardFocusStyle.outlined.usesSystemEffect)
    }

    func testRoundTripForEveryStyle() {
        let defaults = makeDefaults()
        let store = CardFocusStyleSettingsStore(defaults: defaults)
        for style in CardFocusStyle.allCases {
            store.save(style)
            XCTAssertEqual(store.load(), style)
        }
    }

    func testCorruptValueFallsBackToDefault() {
        let defaults = makeDefaults()
        defaults.set("not-a-real-style", forKey: "com.plozz.cardFocusStyle")
        XCTAssertEqual(CardFocusStyleSettingsStore(defaults: defaults).load(), .default)
    }

    /// A non-primary profile writes to `"<key>.<namespace>"` and is isolated from
    /// both the primary profile and other namespaces.
    func testNamespaceIsolatesProfiles() {
        let defaults = makeDefaults()
        let primary = CardFocusStyleSettingsStore(defaults: defaults, namespace: nil)
        let alice = CardFocusStyleSettingsStore(defaults: defaults, namespace: "alice")

        primary.save(.highlight)
        alice.save(.outlined)

        XCTAssertEqual(primary.load(), .highlight)
        XCTAssertEqual(alice.load(), .outlined)
        XCTAssertEqual(
            defaults.string(forKey: "com.plozz.cardFocusStyle.alice"),
            CardFocusStyle.outlined.rawValue
        )
        XCTAssertEqual(
            defaults.string(forKey: "com.plozz.cardFocusStyle"),
            CardFocusStyle.highlight.rawValue
        )
    }

    /// The focus style rides on the shared card-presentation model, so editing it
    /// there is what has to persist.
    @MainActor
    func testCardStyleModelPersistsFocusStyleOnChange() {
        let defaults = makeDefaults()
        let model = CardStyleSettingsModel(
            store: CardStyleSettingsStore(defaults: defaults),
            focusStore: CardFocusStyleSettingsStore(defaults: defaults)
        )
        XCTAssertEqual(model.focusStyle, .system)
        model.focusStyle = .outlined
        XCTAssertEqual(CardFocusStyleSettingsStore(defaults: defaults).load(), .outlined)
        // The two preferences are stored separately and don't disturb each other.
        XCTAssertEqual(CardStyleSettingsStore(defaults: defaults).load(), model.style)
    }

    @MainActor
    func testUpgradePreservesBothCustomChoicesWithoutWritingAnImplicitDefault() {
        for namespace in [nil, "secondary"] {
            let defaults = makeDefaults()
            let key = SettingsKey.scoped("com.plozz.cardFocusStyle", namespace: namespace)
            let store = CardFocusStyleSettingsStore(defaults: defaults, namespace: namespace)
            let emptyModel = CardStyleSettingsModel(
                store: CardStyleSettingsStore(defaults: defaults, namespace: namespace), focusStore: store
            )
            XCTAssertEqual(emptyModel.focusStyle, .system)
            XCTAssertNil(defaults.string(forKey: key))
            for raw in ["highlight", "outlined"] {
                defaults.set(raw, forKey: key)
                let model = CardStyleSettingsModel(
                    store: CardStyleSettingsStore(defaults: defaults, namespace: namespace), focusStore: store
                )
                XCTAssertEqual(model.focusStyle.rawValue, raw)
                XCTAssertEqual(defaults.string(forKey: key), raw)
            }
        }
    }
}
