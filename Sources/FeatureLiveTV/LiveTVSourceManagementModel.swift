#if DEBUG
import CoreModels
import FeatureLiveTVCore
import Foundation
import Observation

@MainActor
@Observable
final class LiveTVSourceManagementModel {
    enum Issue: Equatable {
        case load, save, changedSource, accessDenied, importedFileRemoval

        var message: LocalizedStringResource {
            switch self {
            case .load:
                "Your saved Live TV sources couldn't be read. They haven't been replaced. Retry before making changes."
            case .save:
                "Your source changes couldn't be saved. Your previous setup is unchanged."
            case .changedSource:
                "This source changed while you were editing. Reopen it to use the latest settings."
            case .accessDenied:
                "Source management is locked. Reopen Sources and enter the Parental PIN before making changes."
            case .importedFileRemoval:
                "The source was removed, but its encrypted local playlist copy couldn't be removed. Retry to finish removing it."
            }
        }
    }

    enum MutationError: Error {
        case notLoaded, changedSource, accessDenied
    }

    private(set) var configuration = LiveTVSourcesConfiguration.empty
    private(set) var hasLoaded = false
    private(set) var loadIssue: Issue?
    private(set) var mutationRevision = 0
    var mutationIssue: Issue?
    @ObservationIgnored private let store: any LiveTVSourcesStoring
    @ObservationIgnored private var canMutate: () -> Bool

    init(store: any LiveTVSourcesStoring, canMutate: @escaping () -> Bool) {
        self.store = store
        self.canMutate = canMutate
    }

    func authorizeMutations(_ authorization: @escaping () -> Bool) { canMutate = authorization }

    var sourceStoreForApproval: any LiveTVSourcesStoring { store }

    func ensureCanMutate() throws {
        guard hasLoaded else { throw MutationError.notLoaded }
        guard canMutate() else { throw MutationError.accessDenied }
    }

    func reload() {
        do {
            configuration = try store.load()
            hasLoaded = true
            loadIssue = nil
        } catch {
            hasLoaded = false
            loadIssue = .load
        }
    }

    func savePlaylist(
        input: LiveTVPlaylistEditorModel.ValidatedInput,
        replacing original: LiveTVPlaylistSource? = nil
    ) throws {
        try mutate { configuration in
            if let original {
                guard let index = configuration.playlists.firstIndex(where: { $0.id == original.id }),
                      configuration.playlists[index] == original else {
                    throw MutationError.changedSource
                }
                configuration.playlists[index] = LiveTVPlaylistSource(
                    id: original.id, name: input.name, playlistURL: input.playlistURL,
                    guideURLs: input.guideURLs, isEnabled: original.isEnabled,
                    guideSourceIDs: input.guideURLs.enumerated().map { offset, url in
                        if let previous = original.guideURLs.firstIndex(of: url),
                           original.guideSourceIDs.indices.contains(previous) {
                            return original.guideSourceIDs[previous]
                        }
                        if input.guideURLs.count == original.guideURLs.count,
                           original.guideSourceIDs.indices.contains(offset),
                           !input.guideURLs.contains(original.guideURLs[offset]),
                           LiveTVPlaylistSource.guideURLsShareIdentity(url, original.guideURLs[offset]) {
                            return original.guideSourceIDs[offset]
                        }
                        return UUID().uuidString
                    },
                    discoversPlaylistGuides: original.discoversPlaylistGuides,
                    guideLookbackDays: original.guideLookbackDays,
                    guideLookaheadDays: original.guideLookaheadDays
                )
            } else {
                configuration.playlists.append(LiveTVPlaylistSource(
                    name: input.name, playlistURL: input.playlistURL, guideURLs: input.guideURLs
                ))
            }
        }
    }

    func saveImportedPlaylist(_ source: LiveTVPlaylistSource, replacing original: LiveTVPlaylistSource? = nil) throws {
        guard source.importedPlaylistID != nil else { throw MutationError.changedSource }
        try mutate { configuration in
            if let original {
                guard let index = configuration.playlists.firstIndex(where: { $0.id == original.id }),
                      configuration.playlists[index] == original, source.playlistURL == original.playlistURL else {
                    throw MutationError.changedSource
                }
                configuration.playlists[index] = source
            } else {
                guard !configuration.playlists.contains(where: { $0.id == source.id }) else {
                    throw MutationError.changedSource
                }
                configuration.playlists.append(source)
            }
        }
    }

    func setGuidePolicy(_ id: String, discovers: Bool? = nil, lookbackDays: Int? = nil, lookaheadDays: Int? = nil) {
        perform {
            try mutate { configuration in
                guard let index = configuration.playlists.firstIndex(where: { $0.id == id }) else {
                    throw MutationError.changedSource
                }
                if let discovers { configuration.playlists[index].discoversPlaylistGuides = discovers }
                if let lookbackDays { configuration.playlists[index].guideLookbackDays = lookbackDays }
                if let lookaheadDays { configuration.playlists[index].guideLookaheadDays = lookaheadDays }
            }
        }
    }

    func setPlaylistEnabled(_ id: String, enabled: Bool) {
        perform {
            try mutate { configuration in
                guard let index = configuration.playlists.firstIndex(where: { $0.id == id }) else {
                    throw MutationError.changedSource
                }

                configuration.playlists[index].isEnabled = enabled
            }
        }
    }

    func removePlaylist(_ id: String) {
        perform {
            try mutate { configuration in
                configuration.playlists.removeAll { $0.id == id }
            }
        }
    }

    func addServer(_ choice: LiveTVServerChoice) throws {
        try mutate { configuration in
            if let index = configuration.servers.firstIndex(where: { $0.accountID == choice.id }) {
                configuration.servers[index].isEnabled = true
            } else {
                configuration.servers.append(LiveTVServerSource(name: choice.name, accountID: choice.id))
            }
        }
    }

    func setServerEnabled(_ id: String, enabled: Bool) {
        perform {
            try mutate { configuration in
                guard let index = configuration.servers.firstIndex(where: { $0.id == id }) else {
                    throw MutationError.changedSource
                }
                configuration.servers[index].isEnabled = enabled
            }
        }
    }

    func removeServer(_ id: String) {
        perform {
            try mutate { configuration in
                configuration.servers.removeAll { $0.id == id }
            }
        }
    }

    func renameServer(_ original: LiveTVServerSource, name: String) throws {
        try mutate { configuration in
            guard let index = configuration.servers.firstIndex(where: { $0.id == original.id }),
                  configuration.servers[index] == original else {
                throw MutationError.changedSource
            }
            configuration.servers[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func mutate(_ update: (inout LiveTVSourcesConfiguration) throws -> Void) throws {
        guard hasLoaded else { throw MutationError.notLoaded }
        guard canMutate() else { throw MutationError.accessDenied }
        // Apply only this action to the latest document, retaining edits from another scene.
        var latest = try store.load()
        try update(&latest)
        try store.save(latest)
        configuration = latest
        mutationIssue = nil
        mutationRevision &+= 1
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
        } catch MutationError.accessDenied {
            mutationIssue = .accessDenied
        } catch MutationError.changedSource {
            mutationIssue = .changedSource
        } catch {
            mutationIssue = .save
        }
    }
}
#endif
