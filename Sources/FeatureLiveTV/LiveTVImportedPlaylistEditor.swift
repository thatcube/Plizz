#if DEBUG
import CoreModels
import CoreUI
import FeatureLiveTVCore
import SwiftUI
#if os(iOS)
import UniformTypeIdentifiers
#endif

struct LiveTVImportedPlaylistEditor: View {
    let sources: LiveTVSourceManagementModel
    let imports: LiveTVPrototypeImportModel?
    let original: LiveTVPlaylistSource?
    let didConfigurePlaylist: () -> Void
    let didImportPlaylist: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var guides: [LiveTVPlaylistEditorModel.GuideAddress]
    @State private var baseAddress = ""
    @State private var fileURL: URL?
    @State private var choosingFile = false
    @State private var saveRequest: UUID?
    @State private var saving = false
    @State private var issue: LocalizedStringResource?

    init(
        sources: LiveTVSourceManagementModel, imports: LiveTVPrototypeImportModel?,
        original: LiveTVPlaylistSource? = nil, didConfigurePlaylist: @escaping () -> Void,
        didImportPlaylist: @escaping (String) -> Void = { _ in }
    ) {
        self.sources = sources
        self.imports = imports
        self.original = original
        self.didConfigurePlaylist = didConfigurePlaylist
        self.didImportPlaylist = didImportPlaylist
        _name = State(initialValue: original?.name ?? "")
        _guides = State(initialValue: (original?.guideURLs ?? []).map { .init(address: $0.absoluteString) })
    }

    var body: some View {
        LiveTVSettingsPage(title: "Imported playlist") {
            SettingsSectionGroup("Playlist") {
                TextField("Name (optional)", text: $name)
                if original == nil {
                    #if os(iOS)
                    Button(fileURL == nil ? "Choose M3U file" : "Choose another file") { choosingFile = true }
                        .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                    #endif
                    if fileURL != nil { Label("Playlist selected", systemImage: "doc") }
                    TextField("Base URL for relative addresses (optional)", text: $baseAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .privacySensitive()
                }
                Text("The imported copy is encrypted on this device. It is not uploaded or kept in the guide cache.")
                    .font(.caption)
            }
            .disabled(saving)
            SettingsSectionGroup("Program guide") {
                ForEach($guides) { $guide in
                    HStack {
                        TextField("XMLTV guide URL (optional)", text: $guide.address)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .privacySensitive()
                        Button("Remove guide", systemImage: "minus.circle") {
                            guides.removeAll { $0.id == guide.id }
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                    }
                }
                Button("Add another guide", systemImage: "plus") { guides.append(.init()) }
                    .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                    .disabled(guides.count >= 32)
            } footer: {
                Text("List preferred guides first. Relative addresses require the provider's HTTP or HTTPS base URL.")
            }
            .disabled(saving)
            SettingsSectionGroup {
                if saving { ProgressView("Importing playlist") }
                Button(original == nil ? "Import playlist" : "Save source") { saveRequest = UUID() }
                    .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                    .disabled(saving || (original == nil && fileURL == nil))
                if let issue { Text(issue) }
            }
        }
        #if os(iOS)
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.data]) { result in
            do { fileURL = try result.get() }
            catch { issue = "The selected file couldn't be opened." }
        }
        #endif
        .task(id: saveRequest) {
            guard let request = saveRequest else { return }
            await save(request: request)
        }
    }

    @MainActor
    private func save(request: UUID) async {
        saving = true
        issue = nil
        defer { saving = false }
        var importedID: UUID?
        var committed = false
        do {
            try sources.ensureCanMutate()
            let urls = try guides.compactMap { entry -> URL? in
                let value = entry.address.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { return nil }
                guard let url = LiveTVPlaylistSource.sourceURL(from: value) else {
                    throw LiveTVSourcesValidationError.invalidGuideURL
                }
                return url
            }
            let displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            var source: LiveTVPlaylistSource
            if let original {
                source = original
                source.name = displayName.isEmpty ? "Imported playlist" : displayName
                source.guideURLs = urls
            } else {
                guard let imports, let fileURL,
                      let locator = URL(string: "plozz-playlist://" + request.uuidString.lowercased()) else {
                    throw LiveTVSourceImportError.invalidPlaylist
                }
                let address = baseAddress.trimmingCharacters(in: .whitespacesAndNewlines)
                let baseURL = address.isEmpty ? nil : LiveTVPlaylistSource.sourceURL(from: address)
                guard address.isEmpty || baseURL != nil else {
                    throw LiveTVSourcesValidationError.invalidPlaylistURL
                }
                importedID = request
                _ = try await imports.importPlaylistFile(at: fileURL, id: request, baseURL: baseURL)
                try Task.checkCancellation()
                source = LiveTVPlaylistSource(
                    id: request.uuidString.lowercased(), name: displayName.isEmpty ? "Imported playlist" : displayName,
                    playlistURL: locator, guideURLs: urls
                )
            }
            try sources.saveImportedPlaylist(source, replacing: original)
            committed = true
            didConfigurePlaylist()
            if original == nil { didImportPlaylist(source.id) }
            dismiss()
        } catch {
            if !Task.isCancelled {
                issue = (error as? LiveTVSourceImportError)?.userDescription
                    ?? "The playlist couldn't be saved. Check its addresses and source-management permission."
            }
            if let importedID, !committed, let imports {
                do { try await imports.removeImportedPlaylistFile(id: importedID) }
                catch { issue = "The source wasn't saved, but its encrypted local copy couldn't be removed." }
            }
        }
    }
}
#endif
