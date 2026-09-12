#if DEBUG
import CoreModels
import Foundation
import XCTest
@testable import FeatureLiveTV

@MainActor
final class LiveTVSourceApprovalModelTests: XCTestCase {
    func testExistingHouseholdPINApprovesWholeSourceAndRevokesIt() throws {
        let fixture = try makeFixture()
        fixture.model.beginApproval(source: fixture.source)
        XCTAssertFalse(fixture.model.approve(pin: "0000"))
        XCTAssertEqual(fixture.model.status(source: fixture.source), .needsApproval)
        XCTAssertTrue(fixture.model.approve(pin: "1234"))
        XCTAssertEqual(fixture.model.status(source: fixture.source), .approved)
        fixture.model.revoke(source: fixture.source)
        XCTAssertEqual(fixture.model.status(source: fixture.source), .needsApproval)
    }

    func testProfileSwitchWhilePINIsOpenCannotApproveEitherProfile() throws {
        let fixture = try makeFixture()
        fixture.model.beginApproval(source: fixture.source)
        let other = fixture.profiles.add(name: "Other", isKidsProfile: true)
        fixture.profiles.select(other.id)
        XCTAssertFalse(fixture.model.approve(pin: "1234"))
        XCTAssertEqual(fixture.model.status(source: fixture.source), .needsApproval)
    }

    func testSourceEditWhilePINIsOpenCannotAuthorizeReplacement() throws {
        let fixture = try makeFixture()
        fixture.model.beginApproval(source: fixture.source)
        var changed = fixture.source
        changed.playlistURL = URL(string: "https://other.test/list.m3u")!
        try fixture.store.save(.init(playlists: [changed]))
        XCTAssertFalse(fixture.model.approve(pin: "1234"))
        XCTAssertEqual(fixture.model.status(source: changed), .needsApproval)
    }

    func testParentalPINChangeAndCancelledPromptInvalidatePendingApproval() throws {
        let fixture = try makeFixture()
        fixture.model.beginApproval(source: fixture.source)
        fixture.profiles.setParentalPIN(try XCTUnwrap(ParentalPIN.make(pin: "5678", iterations: 1)))
        XCTAssertFalse(fixture.model.approve(pin: "5678"))
        fixture.model.beginApproval(source: fixture.source)
        fixture.model.cancelApproval()
        XCTAssertFalse(fixture.model.approve(pin: "5678"))
    }

    private func makeFixture() throws -> Fixture {
        let suite = "LiveTVSourceApprovalModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let profiles = ProfilesModel(store: ProfileStore(defaults: defaults))
        let child = profiles.add(name: "Child", isKidsProfile: true)
        profiles.select(child.id)
        profiles.setParentalPIN(try XCTUnwrap(ParentalPIN.make(pin: "1234", iterations: 1)))
        let source = LiveTVPlaylistSource(
            id: "source", name: "News", playlistURL: URL(string: "https://host.test/list.m3u")!
        )
        let store = ApprovalModelTestSources(configuration: .init(playlists: [source]))
        return Fixture(
            profiles: profiles, source: source, store: store,
            model: .init(profiles: profiles, sourceStore: store, defaults: defaults)
        )
    }

    private struct Fixture {
        let profiles: ProfilesModel
        let source: LiveTVPlaylistSource
        let store: ApprovalModelTestSources
        let model: LiveTVSourceApprovalModel
    }
}

private final class ApprovalModelTestSources: LiveTVSourcesStoring, @unchecked Sendable {
    private var configuration: LiveTVSourcesConfiguration
    private let lock = NSLock()
    init(configuration: LiveTVSourcesConfiguration) { self.configuration = configuration }

    func load() throws -> LiveTVSourcesConfiguration {
        lock.lock()
        defer { lock.unlock() }
        return configuration
    }

    func save(_ configuration: LiveTVSourcesConfiguration) throws {
        lock.lock()
        defer { lock.unlock() }
        self.configuration = configuration
    }
}
#endif
