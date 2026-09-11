#if DEBUG
import CoreModels
import Foundation
import XCTest
@testable import FeatureLiveTVCore

@MainActor
final class LiveTVPlaybackSourceAuthorityTests: XCTestCase {
    func testNativeSourceDisableRemovalAndAccountReplacementOverrideRetainedCatalog() throws {
        for kind: LiveTVPrototypeSource in [.plex, .jellyfin, .emby] {
            let fixture = try fixture()
            let configuration = LiveTVSourcesConfiguration(servers: [
                LiveTVServerSource(id: "server-source", name: "Server", accountID: "account")
            ])
            let channel = nativeChannel(kind: kind)
            try fixture.sources.save(configuration)
            XCTAssertTrue(fixture.authority.allows(channel, configuration: configuration))

            var edited = configuration
            edited.servers[0].isEnabled = false
            try fixture.sources.save(edited)
            XCTAssertFalse(fixture.authority.allows(channel, configuration: configuration))
            edited = configuration
            edited.servers[0].accountID = "replacement-account"
            try fixture.sources.save(edited)
            XCTAssertFalse(fixture.authority.allows(channel, configuration: configuration))
            try fixture.sources.save(.empty)
            XCTAssertFalse(fixture.authority.allows(channel, configuration: configuration))
        }
    }

    func testNativeSourceRequiresCurrentProfileAndReadableStorageWithoutIPTVApproval() throws {
        let fixture = try fixture()
        let configuration = LiveTVSourcesConfiguration(servers: [
            LiveTVServerSource(id: "server-source", name: "Server", accountID: "account")
        ])
        try fixture.sources.save(configuration)
        let channel = nativeChannel(kind: .plex)
        XCTAssertTrue(fixture.context.requiresApproval)
        XCTAssertTrue(fixture.authority.allows(channel, configuration: configuration))
        fixture.contextHolder.value = nil
        XCTAssertFalse(fixture.authority.allows(channel, configuration: configuration))
        fixture.contextHolder.value = fixture.context
        fixture.sources.rejectLoads()
        XCTAssertFalse(fixture.authority.allows(channel, configuration: configuration))
    }

    private func nativeChannel(kind: LiveTVPrototypeSource) -> LiveTVPrototypeChannel {
        LiveTVPrototypeChannel(
            id: "native-channel", number: 1, name: "Native channel", category: "Fixture",
            symbol: "tv", accent: 0, source: kind, tagline: "", configuredSourceID: "server-source"
        )
    }

    func testApprovalAndRevocationAreRecheckedWithoutAViewRefresh() throws {
        let fixture = try fixture()
        XCTAssertFalse(fixture.authority.allows(fixture.channel, configuration: fixture.configuration))
        try fixture.approvals.approve(
            source: fixture.configuration.playlists[0], context: fixture.context,
            permit: try XCTUnwrap(fixture.context.authorize(parentalPIN: "1234"))
        )
        XCTAssertTrue(fixture.authority.allows(fixture.channel, configuration: fixture.configuration))
        let filtered = try fixture.authority.authorization(configuration: fixture.configuration)
            .filtering(fixture.configuration)
        XCTAssertEqual(filtered.playlists, fixture.configuration.playlists)
        try fixture.approvals.revoke(sourceID: "source")
        XCTAssertFalse(fixture.authority.allows(fixture.channel, configuration: fixture.configuration))
        XCTAssertTrue(try fixture.authority.authorization(configuration: fixture.configuration)
            .filtering(fixture.configuration).playlists.isEmpty)
    }

    func testCurrentStoredSourceWinsOverAStaleCatalogSnapshot() throws {
        let fixture = try fixture()
        try fixture.approvals.approve(
            source: fixture.configuration.playlists[0], context: fixture.context,
            permit: try XCTUnwrap(fixture.context.authorize(parentalPIN: "1234"))
        )
        var edited = fixture.configuration
        edited.playlists[0].playlistURL = URL(string: "https://example.invalid/changed.m3u")!
        try fixture.sources.save(edited)
        XCTAssertFalse(fixture.authority.allows(fixture.channel, configuration: fixture.configuration))
    }

    func testMissingOrChangedProfileContextFailsClosed() throws {
        let fixture = try fixture()
        fixture.contextHolder.value = nil
        XCTAssertThrowsError(try fixture.authority.authorization(configuration: fixture.configuration))
        XCTAssertFalse(fixture.authority.allows(fixture.channel, configuration: fixture.configuration))
        fixture.contextHolder.value = LiveTVSourceApprovalContext(
            profile: Profile(id: "different-profile", name: "Different"),
            parentalPIN: nil, activeAccountIDs: []
        )
        XCTAssertThrowsError(try fixture.authority.authorization(configuration: fixture.configuration))
        XCTAssertFalse(fixture.authority.allows(fixture.channel, configuration: fixture.configuration))
    }

    func testRecordedOwnerCanUseRootReceiptsWithoutDonatingThemToAnotherNamespace() throws {
        let fixture = try fixture(profileID: "recorded-owner", namespace: nil)
        let source = fixture.configuration.playlists[0]
        try fixture.approvals.approve(
            source: source, context: fixture.context,
            permit: try XCTUnwrap(fixture.context.authorize(parentalPIN: "1234"))
        )
        XCTAssertTrue(fixture.authority.allows(fixture.channel, configuration: fixture.configuration))
        let separateNamespace = LiveTVSourceApprovalStore(
            defaults: fixture.defaults, profileID: fixture.context.profileID,
            namespace: fixture.context.profileID
        )
        XCTAssertEqual(
            try separateNamespace.status(source: source, context: fixture.context),
            .needsApproval
        )
    }

    func testSentinelProfileCanUseItsOwnNamespaceWithoutInheritingRootReceipts() throws {
        let fixture = try fixture(
            profileID: ProfileStore.defaultProfileID, namespace: ProfileStore.defaultProfileID
        )
        let source = fixture.configuration.playlists[0]
        let rootNamespace = LiveTVSourceApprovalStore(
            defaults: fixture.defaults, profileID: fixture.context.profileID, namespace: nil
        )
        try rootNamespace.approve(
            source: source, context: fixture.context,
            permit: try XCTUnwrap(fixture.context.authorize(parentalPIN: "1234"))
        )
        XCTAssertFalse(fixture.authority.allows(fixture.channel, configuration: fixture.configuration))
        try fixture.approvals.approve(
            source: source, context: fixture.context,
            permit: try XCTUnwrap(fixture.context.authorize(parentalPIN: "1234"))
        )
        XCTAssertTrue(fixture.authority.allows(fixture.channel, configuration: fixture.configuration))
    }

    private func fixture(
        profileID: String = "profile", namespace: String? = "profile"
    ) throws -> AuthorityFixture {
        let suite = "LiveTVPlaybackSourceAuthorityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        var profile = Profile(id: profileID, name: "Child")
        profile.isKidsProfile = true
        let context = LiveTVSourceApprovalContext(
            profile: profile, parentalPIN: try XCTUnwrap(ParentalPIN.make(pin: "1234", iterations: 1)),
            activeAccountIDs: []
        )
        let holder = AuthorityContextHolder(value: context)
        let configuration = LiveTVSourcesConfiguration(playlists: [
            LiveTVPlaylistSource(
                id: "source", name: "Fixture", playlistURL: URL(string: "https://example.invalid/fixture.m3u")!
            )
        ])
        let sources = AuthoritySourceStore(configuration: configuration)
        let approvals = LiveTVSourceApprovalStore(
            defaults: defaults, profileID: profile.id, namespace: namespace
        )
        return AuthorityFixture(
            defaults: defaults,
            configuration: configuration, context: context, contextHolder: holder,
            sources: sources, approvals: approvals,
            authority: LiveTVPlaybackSourceAuthority(
                profileID: profile.id, approvals: approvals, sourceStore: sources, context: { holder.value }
            ),
            channel: LiveTVPrototypeChannel(
                id: "channel", number: 1, name: "Fixture channel", category: "Fixture",
                symbol: "tv", accent: 0, source: .iptv, tagline: "",
                streamURL: URL(string: "https://example.invalid/channel.m3u8")!, configuredSourceID: "source"
            )
        )
    }
}

private struct AuthorityFixture {
    let defaults: UserDefaults
    let configuration: LiveTVSourcesConfiguration
    let context: LiveTVSourceApprovalContext
    let contextHolder: AuthorityContextHolder
    let sources: AuthoritySourceStore
    let approvals: LiveTVSourceApprovalStore
    let authority: LiveTVPlaybackSourceAuthority
    let channel: LiveTVPrototypeChannel
}

@MainActor
private final class AuthorityContextHolder {
    var value: LiveTVSourceApprovalContext?
    init(value: LiveTVSourceApprovalContext?) { self.value = value }
}

private final class AuthoritySourceStore: LiveTVSourcesStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var configuration: LiveTVSourcesConfiguration
    private var failsLoading = false
    init(configuration: LiveTVSourcesConfiguration) { self.configuration = configuration }
    func rejectLoads() { lock.withLock { failsLoading = true } }
    func load() throws -> LiveTVSourcesConfiguration {
        try lock.withLock {
            if failsLoading { throw AppError.serverUnreachable }
            return configuration
        }
    }
    func save(_ configuration: LiveTVSourcesConfiguration) throws {
        lock.withLock { self.configuration = configuration }
    }
}
#endif
