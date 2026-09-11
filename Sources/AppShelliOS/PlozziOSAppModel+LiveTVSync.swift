#if DEBUG && os(iOS)
import AppRuntime
import CoreModels
import CoreNetworking
import CoreUI
import FeatureSyncCloud
import FeatureLiveTV
import Foundation
import Observation
import SwiftUI

extension PlozziOSAppModel {
    static func makeLiveTVPortableSync(profiles: ProfilesModel) -> LiveTVPortableSyncBridge? {
        guard let directory = LiveTVPortableSyncBridge.storageDirectory() else { return nil }
        return LiveTVPortableSyncBridge.makeRuntime(profiles: profiles, directory: directory)
    }

    static func makeLiveTVSyncChannel(
        bridge: LiveTVPortableSyncBridge?, stateFileURL: URL
    ) -> CloudConfigSyncService.ChannelConfiguration {
        .init(
            schema: .liveTVStateV1, stateFileURL: stateFileURL,
            captureRecords: { [weak bridge] fallback in
                guard let bridge else { return fallback }
                return await bridge.capture(fallback: fallback)
            },
            applyRecords: { [weak bridge] changes in await bridge?.apply(changes) },
            onAccountSwitch: { [weak bridge] in
                if let bridge { await bridge.accountDidChange() }
                else { await MainActor.run { LiveTVPortableSyncPreferenceStore.accountDidChange() } }
            },
            isHydrated: { [weak bridge] in bridge != nil }
        )
    }

    func observeLiveTVPortableSync() {
        guard liveTVPortableSyncLifecycle == nil, let bridge = liveTVPortableSync else { return }
        liveTVPortableSyncLifecycle = LiveTVPortableSyncLifecycle(
            profiles: profiles, observesLibraryRuntime: true
        ) { [weak self] in
            self?.scheduleCloudPublish()
        }
        LiveTVPortableSyncPresentation.shared.connect(
            profiles: profiles, isAvailable: { [weak bridge] in bridge != nil },
            pendingSources: { [weak bridge] profiles in
                guard let bridge, let store = bridge.sourceSetupStore(profileID: profiles.activeProfileID) else {
                    return AnyView(EmptyView())
                }
                return AnyView(LiveTVPortablePendingSources(
                    directory: bridge.stateDirectory, sourceStore: store
                ))
            }
        ) { [weak bridge] in
            bridge?.statusSummary(profileID: $0)
        }
        observeLiveTVSyncAccountStatus()
    }

    private func observeLiveTVSyncAccountStatus() {
        let account = withObservationTracking {
            (cloudSyncStatus.phase == .signedOut, cloudSyncStatus.accountTag)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeLiveTVSyncAccountStatus() }
        }
        liveTVPortableSyncLifecycle?.accountStatusChanged(isSignedOut: account.0, accountTag: account.1) { [weak self] in
            self?.liveTVPortableSync?.accountDidChange()
        }
    }

    func removeLiveTVPortableProfile(_ profileID: String) {
        do { try liveTVPortableSync?.removeProfile(profileID) }
        catch { PlozzLog.sync.error("Live TV sync: profile removal could not be recorded") }
    }

    func resetLiveTVPortableSync() {
        if let bridge = liveTVPortableSync { bridge.accountDidChange() }
        else { LiveTVPortableSyncPreferenceStore.accountDidChange() }
    }
}
#endif
