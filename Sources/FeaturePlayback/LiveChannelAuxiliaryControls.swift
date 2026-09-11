#if DEBUG && canImport(SwiftUI) && canImport(UIKit)
import CoreModels
import SwiftUI

struct LiveChannelTrackMenu: View {
    let model: LiveChannelPlayerModel
    @FocusState.Binding var focus: LiveChannelControl?
    let onPresentationChange: (Bool) -> Void
    @State private var isPresented = false

    var body: some View {
        #if os(iOS)
        Button {
            isPresented = true
        } label: {
            LiveChannelTrackButtonLabel()
        }
        .buttonStyle(InfoActionButtonStyle(prominent: false))
        .focused($focus, equals: .tracks)
        .accessibilityIdentifier("live-channel-tracks")
        .sheet(isPresented: $isPresented) {
            NavigationStack {
                List {
                    LiveChannelTrackSelection(model: model)
                }
                .navigationTitle("Audio & Subtitles")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { isPresented = false }
                    }
                }
            }
        }
        .onChange(of: isPresented) { _, presented in onPresentationChange(presented) }
        .onDisappear { onPresentationChange(false) }
        #else
        Menu {
            LiveChannelTrackSelection(model: model)
        } label: {
            LiveChannelTrackButtonLabel()
        }
        .buttonStyle(InfoActionButtonStyle(prominent: false))
        .focused($focus, equals: .tracks)
        .focusEffectDisabled()
        .accessibilityIdentifier("live-channel-tracks")
        #endif
    }
}

private struct LiveChannelTrackButtonLabel: View {
    var body: some View {
        Label("Audio & Subtitles", systemImage: "captions.bubble")
            .font(.body.weight(.semibold))
    }
}

private struct LiveChannelTrackSelection: View {
    let model: LiveChannelPlayerModel

    var body: some View {
        Section("Audio") {
            if model.audioTracks.isEmpty {
                Text("No alternate audio tracks")
            } else {
                ForEach(model.audioTracks) { track in
                    Button {
                        model.selectAudio(track)
                    } label: {
                        trackLabel(track, selected: model.selectedAudioID == track.id)
                    }
                }
            }
        }
        Section("Subtitles") {
            Button {
                model.selectSubtitle(nil)
            } label: {
                HStack {
                    Text("Off")
                    if model.selectedSubtitleID == nil { Image(systemName: "checkmark") }
                }
            }
            if model.subtitleTracks.isEmpty {
                Text("No subtitle tracks")
            } else {
                ForEach(model.subtitleTracks) { track in
                    Button {
                        model.selectSubtitle(track)
                    } label: {
                        trackLabel(track, selected: model.selectedSubtitleID == track.id)
                    }
                }
            }
        }
    }

    private func trackLabel(_ track: MediaTrack, selected: Bool) -> some View {
        HStack {
            Text(track.displayTitle)
            if selected { Image(systemName: "checkmark") }
        }
    }
}

struct LiveChannelSubtitleSurface: View {
    let model: LiveChannelPlayerModel

    var body: some View {
        GeometryReader { geometry in
            SubtitleOverlayView(
                primary: model.subtitles.primary,
                style: model.subtitles.style,
                isHDR: model.subtitles.isHDR,
                videoRect: SubtitleOverlayGeometry.aspectFitRect(
                    in: CGRect(origin: .zero, size: geometry.size),
                    aspectRatio: model.engine.videoAspectRatio.map { CGFloat($0) }
                )
            )
        }
    }
}

public struct LiveChannelNetworkStatus: View {
    let block: LiveTVNetworkBlock

    public init(block: LiveTVNetworkBlock) { self.block = block }

    public var body: some View {
        VStack(spacing: 12) {
            Label(title, systemImage: "wifi.slash")
                .font(.headline)
            Text(block.playbackMessage)
                .font(.subheadline)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.white)
        .padding(20)
        .frame(maxWidth: 420)
        .background(.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 20))
        .padding(16)
        .accessibilityElement(children: .combine)
    }

    private var title: LocalizedStringResource {
        switch block {
        case .checkingConnection: "Checking connection"
        case .offline: "You're offline"
        case .wifiRequired: "Waiting for Wi-Fi or Ethernet"
        case .lowDataMode: "Paused for Low Data Mode"
        }
    }

}
#endif
