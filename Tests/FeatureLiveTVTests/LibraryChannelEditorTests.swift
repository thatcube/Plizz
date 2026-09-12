#if DEBUG && canImport(SwiftUI)
import CoreModels
import FeatureLiveTVCore
import XCTest
@testable import FeatureLiveTV

@MainActor
final class LibraryChannelEditorTests: XCTestCase {
    private func editor(canManage: @escaping @MainActor () -> Bool = { true }) async throws -> LibraryChannelEditorModel {
        let service = LibraryChannelService(
            profileID: "profile", store: LibraryEditorDefinitions(),
            snapshotStore: LibraryChannelSnapshotStore(databaseURL: nil)
        )
        service.setContexts([LibraryChannelProviderContext(
            accountID: "account", authorizationID: "authorized",
            provider: LibraryEditorProvider(), allowedLibraryIDs: ["library"]
        )])
        try await service.load()
        let model = LibraryChannelEditorModel(service: service, editingChannelID: nil, canManage: canManage)
        model.recipe.name = "Movies"
        model.recipe.libraries = [.init(accountID: "account", libraryID: "library")]
        model.recipe.includesEpisodes = false
        return model
    }

    func testRecipeEditInvalidatesReviewedScheduleAndRequiresAnotherPreview() async throws {
        let model = try await editor()
        await model.preview()
        XCTAssertNotNil(model.currentPreview)
        model.includeTitles = "Different film"
        XCTAssertNil(model.currentPreview)
        let saved = await model.save()
        XCTAssertFalse(saved)
        XCTAssertTrue(model.service.definitions.isEmpty)
    }

    func testInvalidSeedCannotSaveAReviewedScheduleWithFallbackSeed() async throws {
        let model = try await editor()
        await model.preview()
        XCTAssertNotNil(model.currentPreview)
        model.seed = "not a seed"
        XCTAssertNil(model.currentPreview)
        await model.preview()
        XCTAssertEqual(model.issue, .invalidRecipe)
        let saved = await model.save()
        XCTAssertFalse(saved)
    }

    func testChangedAuthorizationInvalidatesEditorBeforeSave() async throws {
        let model = try await editor()
        await model.preview()
        XCTAssertNotNil(model.currentPreview)
        model.service.setContexts([])
        XCTAssertNil(model.currentPreview)
        let saved = await model.save()
        XCTAssertFalse(saved)
    }

    func testPreviewAndSavePublishARealDurableChannel() async throws {
        let model = try await editor()
        await model.preview()
        XCTAssertEqual(model.currentPreview?.matchingCount, 1)
        let saved = await model.save()
        XCTAssertTrue(saved)
        XCTAssertEqual(model.service.channels.first?.name, "Movies")
        XCTAssertTrue(model.service.channels.first?.id.hasPrefix("library:") == true)
        XCTAssertEqual(model.service.definitions.count, 1)
    }

    func testExplicitEditorEntryPreparesLibraryDiscovery() async throws {
        let model = try await editor()
        var requests = 0
        await model.load {
            requests += 1
            XCTAssertTrue(model.isWorking)
            try await model.service.loadLibraries()
        }
        XCTAssertEqual(requests, 1)
        XCTAssertFalse(model.isWorking)
        XCTAssertNil(model.issue)
    }

    func testExplicitDiscoveryErrorIsPresentedInEditorAndReleasesLoadingState() async throws {
        let model = try await editor()
        await model.load { throw LibraryChannelError.sourceUnavailable }
        XCTAssertEqual(model.issue, .sourceUnavailable)
        XCTAssertFalse(model.isWorking)
    }

    func testRevokedSourceManagementGrantPreventsCustomChannelPublication() async throws {
        var allowed = true
        let model = try await editor(canManage: { allowed })
        await model.preview()
        XCTAssertNotNil(model.currentPreview)
        allowed = false
        XCTAssertNil(model.currentPreview)
        let saved = await model.save()
        XCTAssertFalse(saved)
        XCTAssertEqual(model.issue, .authorizationChanged)
        XCTAssertTrue(model.service.definitions.isEmpty)
    }

    func testLockedEditorDoesNotDiscoverLibrariesOrPreview() async throws {
        let model = try await editor(canManage: { false })
        var discoveryCount = 0
        await model.load { discoveryCount += 1 }
        await model.preview()
        XCTAssertEqual(discoveryCount, 0)
        XCTAssertNil(model.currentPreview)
        XCTAssertEqual(model.issue, .authorizationChanged)
    }
}

private final class LibraryEditorDefinitions: LibraryChannelDefinitionStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [LibraryChannelDefinition] = []
    func load() throws -> [LibraryChannelDefinition] { lock.withLock { values } }
    func save(_ definitions: [LibraryChannelDefinition]) throws { lock.withLock { values = definitions } }
}

private struct LibraryEditorProvider: LibraryChannelCatalogProviding {
    let kind = ProviderKind.jellyfin
    let session = UserSession(
        server: MediaServer(id: "server", name: "Server", baseURL: URL(string: "https://server.invalid")!, provider: .jellyfin),
        userID: "user", userName: "User", deviceID: "device", accessToken: "fixture"
    )
    func libraryChannelItems(in libraryID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        var item = MediaItem(id: "movie", title: "Movie", kind: .movie, runtime: 1_000)
        item.libraryID = libraryID
        return MediaPage(items: [item], startIndex: page.startIndex, totalCount: 1)
    }
    func libraries() async throws -> [MediaLibrary] { [] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem { throw AppError.notFound }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage { throw AppError.notFound }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
#endif
