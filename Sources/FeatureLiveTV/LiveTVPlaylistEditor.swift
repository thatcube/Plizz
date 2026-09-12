#if DEBUG
import CoreUI
import CoreModels
import FeatureLiveTVCore
import Observation
import SwiftUI

struct LiveTVPlaylistEditor: View {
    @State private var model: LiveTVPlaylistEditorModel
    @State private var checkRequest: UUID?
    @Environment(\.dismiss) private var dismiss
    let isEditing: Bool
    let save: (LiveTVPlaylistEditorModel.ValidatedInput) throws -> Void

    init(
        name: String = "", playlistURL: URL? = nil, guideURLs: [URL] = [],
        isEditing: Bool = false,
        save: @escaping (LiveTVPlaylistEditorModel.ValidatedInput) throws -> Void
    ) {
        self.isEditing = isEditing
        self.save = save
        _model = State(initialValue: LiveTVPlaylistEditorModel(
            name: name, playlistURL: playlistURL, guideURLs: guideURLs
        ))
    }

    var body: some View {
        @Bindable var model = model
        LiveTVSettingsPage(title: "IPTV source") {
            SettingsSectionGroup("Playlist") {
                LiveTVAddressField(title: "Playlist or live HLS URL", text: $model.playlistAddress)
                    .accessibilityIdentifier("live-tv-playlist-url")
                TextField("Name (optional)", text: $model.name)
            }
            .disabled(model.isChecking)

            SettingsSectionGroup("Program guide") {
                ForEach($model.guideAddresses) { $guide in
                    HStack(spacing: 20) {
                        LiveTVAddressField(title: "XMLTV guide URL (optional)", text: $guide.address)
                        Button("Remove guide", systemImage: "minus.circle") {
                            let id = guide.id
                            model.guideAddresses.removeAll { $0.id == id }
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                    }
                    .contextMenu {
                        Button("Move guide earlier") { model.moveGuide(guide.id, by: -1) }
                            .disabled(model.guideAddresses.first?.id == guide.id)
                        Button("Move guide later") { model.moveGuide(guide.id, by: 1) }
                            .disabled(model.guideAddresses.last?.id == guide.id)
                    }
                }
                Button("Add another guide", systemImage: "plus") {
                    model.guideAddresses.append(.init())
                }
                .buttonStyle(SettingsFocusButtonStyle(size: .contained))
            } footer: {
                Text("Optional XMLTV or .xml.gz. List preferred guides first.")
            }
            .disabled(model.isChecking)

            SettingsSectionGroup {
                if model.usesUnencryptedAddresses {
                    Text("HTTP is unencrypted. Prefer HTTPS.")
                        .font(.caption)
                }
                if model.isChecking {
                    HStack(spacing: 16) {
                        ProgressView()
                        Text("Checking playlist")
                    }
                    .accessibilityElement(children: .combine)
                } else if let review = model.currentReview {
                    LiveTVPlaylistReviewSummary(channels: review.channelCount, skipped: review.skippedEntryCount)
                }
                Button {
                    if model.isChecking {
                        model.cancelCheck()
                        checkRequest = nil
                    } else if model.currentReview != nil {
                        if model.save(using: save) { dismiss() }
                    } else {
                        checkRequest = UUID()
                    }
                } label: {
                    if model.isChecking {
                        Label("Cancel check", systemImage: "xmark")
                    } else if model.currentReview != nil {
                        Label("Save source", systemImage: "checkmark")
                    } else if isEditing {
                        Label("Save changes", systemImage: "checkmark")
                    } else {
                        Label("Add source", systemImage: "plus")
                    }
                }
                .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                .accessibilityIdentifier("live-tv-playlist-action")
                if let issue = model.issue {
                    Label {
                        Text(issue.message)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            } footer: {
                Text("Checks the playlist, not individual streams.")
            }
        }
        .task(id: checkRequest) {
            guard let request = checkRequest else { return }
            await model.check()
            guard !Task.isCancelled, checkRequest == request else { return }
            checkRequest = nil
            if model.currentReview != nil, model.save(using: save) {
                dismiss()
            }
        }
        .onDisappear { model.cancelCheck() }
    }
}

private struct LiveTVAddressField: View {
    let title: LocalizedStringResource
    @Binding var text: String

    var body: some View {
        TextField(text: $text) { Text(title) }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .privacySensitive()
            #if os(iOS)
            .keyboardType(.URL)
            #endif
    }
}

private struct LiveTVPlaylistReviewSummary: View {
    let channels: Int
    let skipped: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Found \(channels) channels", systemImage: "checkmark.circle")
                .font(.headline)
            if skipped > 0 {
                Text("\(skipped) unsupported or duplicate entries skipped.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

@MainActor
@Observable
final class LiveTVPlaylistEditorModel {
    struct GuideAddress: Identifiable, Equatable {
        let id = UUID()
        var address = ""
    }

    struct ValidatedInput: Equatable {
        let name: String
        let playlistURL: URL
        let guideURLs: [URL]
    }

    struct Review: Equatable {
        let input: ValidatedInput
        let channelCount: Int
        let skippedEntryCount: Int
    }

    enum Issue: Error, Equatable {
        case invalidPlaylistAddress, invalidGuideAddress, noChannels, checkRequired, saveFailed, sourceChanged, accessDenied
        case download(LiveTVSourceImportError)
        case invalidName, invalidGuideList

        var message: LocalizedStringResource {
            switch self {
            case .invalidPlaylistAddress:
                "Enter a complete HTTP or HTTPS playlist URL, without a username or password before the hostname."
            case .invalidGuideAddress:
                "Each guide needs a complete HTTP or HTTPS URL, or you can leave it blank."
            case .invalidName:
                "Use a shorter source name."
            case .invalidGuideList:
                "Use no more than 32 different guide addresses. Remove duplicate guide links."
            case .noChannels:
                "This playlist has no supported HTTP or HTTPS channels. Check the link from your provider."
            case .checkRequired:
                "Check the updated playlist before saving."
            case .saveFailed:
                "Your source could not be saved. Your previous setup is unchanged. Please try again."
            case .sourceChanged:
                "This source changed while you were editing. Return to Sources and reopen it before saving."
            case .accessDenied:
                "Source management is locked. Reopen Sources and enter the Parental PIN before saving."
            case .download(let failure):
                failure.userDescription
            }
        }
    }

    var name: String
    var playlistAddress: String
    var guideAddresses: [GuideAddress]
    private(set) var isChecking = false
    private(set) var issue: Issue?
    private var review: Review?
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private let loader: any LiveTVSourceLoading

    init(
        name: String = "", playlistURL: URL? = nil, guideURLs: [URL] = [],
        loader: any LiveTVSourceLoading = LiveTVSourceLoader()
    ) {
        self.name = name
        self.playlistAddress = playlistURL?.absoluteString ?? ""
        self.guideAddresses = guideURLs.isEmpty ? [.init()] : guideURLs.map { .init(address: $0.absoluteString) }
        self.loader = loader
    }

    var currentReview: Review? {
        guard let review, let input = validatedInput,
              review.input.playlistURL == input.playlistURL else { return nil }
        return Review(input: input, channelCount: review.channelCount, skippedEntryCount: review.skippedEntryCount)
    }

    private var validatedInput: ValidatedInput? {
        guard case .success(let input) = validatedInputResult else { return nil }
        return input
    }

    var usesUnencryptedAddresses: Bool {
        ([playlistAddress] + guideAddresses.map(\.address)).contains {
            LiveTVPlaylistSource.sourceURL(from: $0)?.scheme?.lowercased() == "http"
        }
    }

    func moveGuide(_ id: UUID, by offset: Int) {
        guard let index = guideAddresses.firstIndex(where: { $0.id == id }),
              guideAddresses.indices.contains(index + offset) else { return }
        guideAddresses.swapAt(index, index + offset)
    }

    private var validatedInputResult: Result<ValidatedInput, Issue> {
        guard let playlistURL = LiveTVPlaylistSource.sourceURL(from: playlistAddress) else {
            return .failure(.invalidPlaylistAddress)
        }
        let addresses = guideAddresses.map(\.address).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let guides = addresses.compactMap { LiveTVPlaylistSource.sourceURL(from: $0) }
        guard guides.count == addresses.count else { return .failure(.invalidGuideAddress) }
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let input = ValidatedInput(
            name: label.isEmpty ? (playlistURL.host ?? "IPTV") : label,
            playlistURL: playlistURL, guideURLs: guides
        )
        do {
            try LiveTVPlaylistSource(
                id: "draft", name: input.name, playlistURL: playlistURL, guideURLs: guides
            ).validate()
            return .success(input)
        } catch LiveTVSourcesValidationError.invalidName {
            return .failure(.invalidName)
        } catch LiveTVSourcesValidationError.invalidGuideSources {
            return .failure(.invalidGuideList)
        } catch {
            return .failure(.invalidGuideAddress)
        }
    }

    func check() async {
        revision &+= 1
        let request = revision
        isChecking = false
        review = nil
        issue = nil
        let input: ValidatedInput
        switch validatedInputResult {
        case .success(let value):
            input = value
        case .failure(let failure):
            issue = failure
            return
        }
        isChecking = true
        defer { if request == revision { isChecking = false } }
        do {
            let imported = try await loader.loadPlaylist(from: input.playlistURL)
            guard !Task.isCancelled, request == revision, input == validatedInput else { return }
            guard !imported.channels.isEmpty else {
                issue = .noChannels
                return
            }
            review = Review(
                input: input, channelCount: imported.channels.count,
                skippedEntryCount: imported.skippedEntryCount
            )
        } catch is CancellationError {
            return
        } catch let failure as LiveTVSourceImportError {
            guard request == revision, !Task.isCancelled, failure != .cancelled else { return }
            issue = .download(failure)
        } catch {
            guard request == revision, !Task.isCancelled else { return }
            issue = .download(.downloadFailed)
        }
    }

    func cancelCheck() {
        revision &+= 1
        isChecking = false
    }

    func save(using persist: (ValidatedInput) throws -> Void) -> Bool {
        guard let review = currentReview else {
            issue = .checkRequired
            return false
        }
        do {
            try persist(review.input)
            issue = nil
            return true
        } catch LiveTVSourceManagementModel.MutationError.accessDenied {
            issue = .accessDenied
            return false
        } catch LiveTVSourceManagementModel.MutationError.changedSource {
            issue = .sourceChanged
            return false
        } catch {
            issue = .saveFailed
            return false
        }
    }

}
#endif
