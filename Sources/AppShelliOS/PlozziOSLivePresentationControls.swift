#if DEBUG && os(iOS)
import AVKit
import FeaturePlayback
import SwiftUI

/// This node stays mounted when controls hide; it never creates a player.
struct PlozziOSLivePresentationControls: View {
    let context: LiveChannelPresentationContext
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var pictureInPicture = PlozziOSPictureInPictureController()

    var body: some View {
        HStack(spacing: 12) {
            if context.permitsExternalPresentation {
                if pictureInPicture.isAvailable || pictureInPicture.continuesPlayback {
                    Button {
                        pictureInPicture.toggle()
                    } label: {
                        Label("Picture in Picture", systemImage: "pip.enter")
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityIdentifier("live-channel-pip")
                    .accessibilityValue(pictureInPicture.isStarting ? "Starting" :
                        pictureInPicture.isActive ? "Active" : "Inactive")
                }
                if nativePlayerAvailable {
                    LiveAirPlayRoutePicker()
                        .frame(width: 44, height: 44)
                        .accessibilityLabel("AirPlay")
                        .accessibilityValue(pictureInPicture.isAirPlayActive ? "Connected" : "Not connected")
                        .accessibilityIdentifier("live-channel-airplay")
                }
                Button(action: context.stopPlayback) {
                    Label("Stop playback", systemImage: "stop.fill")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .labelStyle(.iconOnly)
                .accessibilityIdentifier("live-channel-stop")
            }
        }
        .foregroundStyle(.white)
        .background(.black.opacity(0.6), in: Capsule())
        .opacity(context.showsControls ? 1 : 0)
        .allowsHitTesting(context.showsControls)
        .accessibilityHidden(!context.showsControls)
        .onAppear(perform: attach)
        .onChange(of: context.permitsExternalPresentation) { _, _ in
            attach()
        }
        .onChange(of: context.isVisible) { _, _ in
            updateCallbacks()
        }
        .onChange(of: context.sessionID) { _, _ in
            updateCallbacks()
        }
        .onChange(of: context.hasSelectedSubtitle) { _, selected in
            pictureInPicture.usesNativeSubtitles = selected
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .inactive, context.permitsExternalPresentation,
                  context.intendsPlayback, pictureInPicture.isAvailable,
                  !pictureInPicture.continuesPlayback else { return }
            pictureInPicture.toggle()
        }
        .onDisappear {
            pictureInPicture.detach(preservingActivePresentation: true)
        }
    }

    private var nativePlayerAvailable: Bool {
        (context.engine as? any PictureInPicturePresentingEngine)?
            .pictureInPicturePlayerLayer()?.player != nil
    }

    private func attach() {
        guard let engine = context.engine as? any PictureInPicturePresentingEngine else { return }
        updateCallbacks()
        pictureInPicture.attach(engine: engine)
        context.registerInvalidation { [pictureInPicture] in pictureInPicture.detach() }
    }

    private func updateCallbacks() {
        pictureInPicture.allowsAutomaticStart = context.permitsExternalPresentation
        pictureInPicture.permitsExternalPresentation = context.permitsExternalPresentation
        pictureInPicture.usesNativeSubtitles = context.hasSelectedSubtitle
        pictureInPicture.onContinuationChanged = context.continuationChanged
        pictureInPicture.restoreUI = context.restoreUI
    }
}

private struct LiveAirPlayRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = true
        picker.tintColor = .white
        picker.activeTintColor = .systemBlue
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
#endif
