#if DEBUG
import CoreModels
import Foundation

protocol LiveTVAutomaticChannelsStoring: Sendable {
    func isEnabled() throws -> Bool
    func setEnabled(_ enabled: Bool) throws
}

final class LiveTVAutomaticChannelsStore: LiveTVAutomaticChannelsStoring, @unchecked Sendable {
    private let secureStore: any SecureStoring
    private let key: String

    init(secureStore: any SecureStoring, namespace: String?) {
        self.secureStore = secureStore
        key = SettingsKey.scoped("com.plozz.liveTV.automaticChannels", namespace: namespace)
    }

    func isEnabled() throws -> Bool {
        switch try secureStore.readString(for: key) {
        case nil, "0": false
        case "1": true
        default: throw LibraryChannelError.storageFailed
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        try secureStore.setString(enabled ? "1" : "0", for: key)
    }
}

final class LiveTVMemoryAutomaticChannelsStore: LiveTVAutomaticChannelsStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = false

    func isEnabled() throws -> Bool { lock.withLock { enabled } }
    func setEnabled(_ enabled: Bool) throws { lock.withLock { self.enabled = enabled } }
}
#endif
