import XCTest
@testable import CoreModels

final class LiveTVSourceApprovalTests: XCTestCase {
    func testLegacySourcesNeedExplicitChildApprovalButAdultsKeepAccess() throws {
        let defaults = makeDefaults()
        let pin = try XCTUnwrap(ParentalPIN.make(pin: "1234", iterations: 1))
        let child = makeProfile()
        let source = makeSource()
        let store = LiveTVSourceApprovalStore(defaults: defaults, profileID: child.id)
        let context = makeContext(child, pin)
        let config = LiveTVSourcesConfiguration(playlists: [source])
        XCTAssertEqual(try store.status(source: source, context: context), .needsApproval)
        XCTAssertFalse(try store.authorization(context: context, configuration: config).allowsPlaylist(source.id))
        var adult = child
        adult.isKidsProfile = false
        XCTAssertTrue(try store.authorization(
            context: makeContext(adult, pin), configuration: config
        ).allowsPlaylist(source.id))
    }

    func testSingleSourceApprovalCoversItsChannelsAndRevocationIsImmediate() throws {
        let defaults = makeDefaults()
        let profile = makeProfile()
        let context = makeContext(profile, try XCTUnwrap(ParentalPIN.make(pin: "1234", iterations: 1)))
        let source = makeSource()
        let other = makeSource(id: "other")
        let config = LiveTVSourcesConfiguration(playlists: [source, other])
        let store = LiveTVSourceApprovalStore(defaults: defaults, profileID: profile.id)
        XCTAssertNil(context.authorize(parentalPIN: "0000"))
        try store.approve(
            source: source, context: context,
            permit: try XCTUnwrap(context.authorize(parentalPIN: "1234"))
        )
        let allowed = try store.authorization(context: context, configuration: config)
        XCTAssertEqual(allowed.allowedPlaylistIDs, [source.id])
        XCTAssertEqual(allowed.filtering(config).playlists, [source])
        XCTAssertFalse(allowed.allowsPlaylist(nil))
        try store.revoke(sourceID: source.id)
        let revoked = try store.authorization(context: context, configuration: config)
        XCTAssertTrue(revoked.allowedPlaylistIDs.isEmpty)
        XCTAssertNotEqual(allowed.identity, revoked.identity)
    }

    func testPINIdentityMembershipAndSourceEditsInvalidateExistingGrant() throws {
        let profile = makeProfile()
        let pin = try XCTUnwrap(ParentalPIN.make(pin: "1234", iterations: 1))
        let context = makeContext(profile, pin)
        let source = makeSource()
        let store = LiveTVSourceApprovalStore(defaults: makeDefaults(), profileID: profile.id)
        let permit = try XCTUnwrap(context.authorize(parentalPIN: "1234"))
        try store.approve(source: source, context: context, permit: permit)
        var renamed = source
        renamed.name = "New display name"
        XCTAssertEqual(try store.status(source: renamed, context: context), .approved)
        var edited = source
        edited.playlistURL = URL(string: "https://example.test/changed-secret/catalog.m3u")!
        XCTAssertEqual(try store.status(source: edited, context: context), .needsApproval)
        edited = source
        edited.guideURLs = [URL(string: "https://example.test/guide.xml")!]
        XCTAssertEqual(try store.status(source: edited, context: context), .needsApproval)
        let changedPIN = makeContext(profile, try XCTUnwrap(ParentalPIN.make(pin: "5678", iterations: 1)))
        XCTAssertEqual(try store.status(source: source, context: changedPIN), .needsApproval)
        XCTAssertThrowsError(try store.approve(source: source, context: changedPIN, permit: permit))
        let changedMembership = LiveTVSourceApprovalContext(
            profile: profile, parentalPIN: pin, activeAccountIDs: ["new-account"]
        )
        XCTAssertEqual(try store.status(source: source, context: changedMembership), .needsApproval)
        var changedProfile = profile
        changedProfile.plexHomeUserBindings = ["plex": .init(homeUserID: "child-two", name: "Child")]
        let first = LiveTVSourceApprovalContext(profile: profile, parentalPIN: pin, activeAccountIDs: ["plex"])
        let second = LiveTVSourceApprovalContext(profile: changedProfile, parentalPIN: pin, activeAccountIDs: ["plex"])
        XCTAssertNotEqual(first.identity, second.identity)
    }

    func testWithoutHouseholdPINChildCannotApproveAndDisabledNeverAllowed() throws {
        let profile = makeProfile()
        let context = makeContext(profile, nil)
        let store = LiveTVSourceApprovalStore(defaults: makeDefaults(), profileID: profile.id)
        var source = makeSource()
        XCTAssertEqual(try store.status(source: source, context: context), .parentalPINRequired)
        XCTAssertNil(context.authorize(parentalPIN: "1234"))
        source.isEnabled = false
        XCTAssertEqual(try store.status(source: source, context: context), .disabled)
        var adult = profile
        adult.isKidsProfile = false
        XCTAssertTrue(try store.authorization(
            context: makeContext(adult, nil),
            configuration: .init(playlists: [source])
        ).allowedPlaylistIDs.isEmpty)
    }

    func testProfileNamespacesAndCorruptDataFailClosedWithoutChangingSourcesOrFavorites() throws {
        let defaults = makeDefaults()
        let child = makeProfile()
        let source = makeSource()
        let pin = try XCTUnwrap(ParentalPIN.make(pin: "1234", iterations: 1))
        let context = makeContext(child, pin)
        let store = LiveTVSourceApprovalStore(defaults: defaults, profileID: child.id)
        try store.approve(
            source: source, context: context,
            permit: try XCTUnwrap(context.authorize(parentalPIN: "1234"))
        )
        let other = Profile(id: "other", name: "Other", isKidsProfile: true)
        let otherStore = LiveTVSourceApprovalStore(defaults: defaults, profileID: other.id)
        XCTAssertEqual(try otherStore.status(source: source, context: makeContext(other, pin)), .needsApproval)
        XCTAssertThrowsError(try otherStore.status(source: source, context: context))
        let preferences = LiveTVPreferencesStore(defaults: defaults, namespace: child.id)
        try preferences.save(.init(favoriteIDs: ["favorite"]))
        let key = SettingsKey.scoped("com.plozz.liveTV.sourceApprovals.v1", namespace: child.id)
        let receipt = try XCTUnwrap(defaults.data(forKey: key))
        XCTAssertFalse(String(decoding: receipt, as: UTF8.self).contains("secret"))
        defaults.set(Data("corrupt".utf8), forKey: key)
        XCTAssertThrowsError(try store.authorization(
            context: context, configuration: .init(playlists: [source])
        ))
        XCTAssertTrue(store.authorizationFailClosed(
            context: context, configuration: .init(playlists: [source])
        ).allowedPlaylistIDs.isEmpty)
        XCTAssertThrowsError(try store.approve(
            source: source, context: context,
            permit: try XCTUnwrap(context.authorize(parentalPIN: "1234"))
        ))
        XCTAssertEqual(try preferences.load().favoriteIDs, ["favorite"])
        XCTAssertEqual(defaults.data(forKey: key), Data("corrupt".utf8))
    }

    func testSourceStoreWrapperPreventsOldGrantReturningAfterAddressRevertOrIDReuse() throws {
        let profile = makeProfile()
        let context = makeContext(profile, try XCTUnwrap(ParentalPIN.make(pin: "1234", iterations: 1)))
        let source = makeSource()
        let approvals = LiveTVSourceApprovalStore(defaults: makeDefaults(), profileID: profile.id)
        let underlying = ApprovalTestSources(.init(playlists: [source]))
        let store = LiveTVApprovalAwareSourcesStore(underlying: underlying, approvals: approvals)
        let permit = try XCTUnwrap(context.authorize(parentalPIN: "1234"))
        try approvals.approve(source: source, context: context, permit: permit)
        var changed = source
        changed.playlistURL = URL(string: "https://different.test/list.m3u")!
        try store.save(.init(playlists: [changed]))
        try store.save(.init(playlists: [source]))
        XCTAssertEqual(try approvals.status(source: source, context: context), .needsApproval)
        try approvals.approve(source: source, context: context, permit: permit)
        try store.save(.empty)
        try store.save(.init(playlists: [source]))
        XCTAssertEqual(try approvals.status(source: source, context: context), .needsApproval)
    }

    private func makeProfile() -> Profile {
        Profile(id: "child", name: "Child", isKidsProfile: true)
    }

    private final class ApprovalTestSources: LiveTVSourcesStoring, @unchecked Sendable {
        private var configuration: LiveTVSourcesConfiguration
        private let lock = NSLock()
        init(_ configuration: LiveTVSourcesConfiguration) { self.configuration = configuration }
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

    private func makeContext(_ profile: Profile, _ pin: ParentalPIN?) -> LiveTVSourceApprovalContext {
        LiveTVSourceApprovalContext(profile: profile, parentalPIN: pin, activeAccountIDs: [])
    }

    private func makeSource(id: String = "source") -> LiveTVPlaylistSource {
        LiveTVPlaylistSource(
            id: id, name: "News", playlistURL: URL(string: "https://example.test/secret/list.m3u")!
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "LiveTVSourceApprovalTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }
}
