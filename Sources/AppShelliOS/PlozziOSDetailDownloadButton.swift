#if os(iOS)
import CoreModels
import MediaDownloads
import SwiftUI

/// The single-item counterpart of the season manager, always hosted in the detail toolbar.
struct PlozziOSDetailDownloadButton: View {
    @Environment(PlozziOSAppModel.self) private var appModel
    @State private var downloadRecord: DownloadedMediaRecord?
    @State private var downloadError: String?
    @State private var showsDownloadConfirmation = false

    let downloadItem: MediaItem
    let selectedSource: MediaSourceRef?
    let selectedVersion: MediaVersion?

    var body: some View {
        Button {
            Task { await performDownloadAction() }
        } label: {
            Image(systemName: downloadActionSymbol)
        }
        .accessibilityLabel(downloadActionTitle)
        .task {
            downloadRecord = await appModel.downloads.record(forSelectedVersionOf: downloadItem)
            if let provider = appModel.provider(for: downloadItem) {
                await appModel.downloads.refreshReducedQualitySupport(
                    for: downloadItem,
                    provider: provider
                )
            }
        }
        .alert(
            "Download Failed",
            isPresented: Binding(
                get: { downloadError != nil },
                set: { if !$0 { downloadError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(verbatim: downloadError ?? "")
        }
        .confirmationDialog(
            (currentDownloadRecord?.status == .completed
                ? Text("Change Offline Copy of ")
                : Text("Download "))
                + Text(verbatim: downloadItem.title)
                + Text(verbatim: "?"),
            isPresented: $showsDownloadConfirmation,
            titleVisibility: .visible
        ) {
            Button(
                currentDownloadRecord?.status == .completed
                    ? "Use Original"
                    : "Download Original"
            ) {
                Task { await startDownload(quality: .original) }
            }
            if appModel.downloads.supportsReducedQuality(for: downloadItem) {
                Button("Download 1080p • 20 Mbps") {
                    Task { await startDownload(quality: .hd1080) }
                }
                Button("Download 720p • 4 Mbps") {
                    Task { await startDownload(quality: .hd720) }
                }
                Button("Download 480p • 1.5 Mbps") {
                    Task { await startDownload(quality: .sd480) }
                }
                if let custom = appModel.downloads.customDownloadQuality,
                   let title = appModel.downloads.customDownloadQualityTitle {
                    Button(title) {
                        Task { await startDownload(quality: custom) }
                    }
                }
            }
            if currentDownloadRecord?.status == .completed {
                Button("Remove Download", role: .destructive) {
                    Task { await removeDownload() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            downloadConfirmationMessage
        }
    }

    private var downloadActionTitle: LocalizedStringResource {
        switch currentDownloadRecord?.status {
        case .queued, .preparing, .downloading: return MediaItemAction.pauseDownload.title
        case .paused, .failed: return MediaItemAction.resumeDownload.title
        case .completed: return MediaItemAction.removeDownload.title
        case nil: return MediaItemAction.startDownload.title
        }
    }

    private var downloadActionSymbol: String {
        switch currentDownloadRecord?.status {
        case .queued, .preparing, .downloading: return "pause.circle"
        case .paused, .failed: return "arrow.clockwise.circle"
        case .completed: return "trash"
        case nil: return "arrow.down.circle"
        }
    }

    private func performDownloadAction() async {
        switch currentDownloadRecord?.status {
        case .queued, .preparing, .downloading:
            await pauseDownload()
        case .paused, .failed:
            await resumeDownload()
        case .completed:
            showsDownloadConfirmation = true
        case nil:
            if appModel.downloads.asksBeforeDownloading {
                showsDownloadConfirmation = true
            } else {
                await startDownload()
            }
        }
    }

    private var currentDownloadRecord: DownloadedMediaRecord? {
        guard let downloadRecord else { return nil }
        return appModel.downloads.records.first {
            $0.identityKey == downloadRecord.identityKey
        } ?? downloadRecord
    }

    private func startDownload(quality: DownloadQuality? = nil) async {
        do {
            guard let provider = appModel.provider(for: downloadItem) else {
                downloadError = String(localized: "The selected server is no longer available.") // l10n:content — alert storage requires resolved text
                return
            }
            downloadRecord = try await appModel.downloads.enqueue(
                item: downloadItem,
                provider: provider,
                quality: quality
            )
        } catch {
            downloadError = error.localizedDescription
        }
    }

    private var downloadConfirmationMessage: Text {
        let source = selectedSource.map {
            Text(verbatim: $0.displayName)
        } ?? Text("Selected server")
        let size = selectedVersion?.sizeBytes.map {
            Text(verbatim: $0.formatted(.byteCount(style: .file)))
        } ?? Text("Size unavailable")
        return source
            + Text(verbatim: " • ")
            + size
            + Text(verbatim: ". ")
            + Text("Reduced qualities are transcoded by your media server.")
    }

    private func pauseDownload() async {
        guard let record = currentDownloadRecord else { return }
        await appModel.downloads.pause(record)
        downloadRecord = appModel.downloads.records.first { $0.identityKey == record.identityKey }
    }

    private func resumeDownload() async {
        guard let record = currentDownloadRecord else { return }
        await appModel.downloads.resume(record)
        downloadRecord = appModel.downloads.records.first { $0.identityKey == record.identityKey }
    }

    private func removeDownload() async {
        guard let record = currentDownloadRecord else { return }
        await appModel.downloads.remove(record)
        downloadRecord = nil
    }
}
#endif
