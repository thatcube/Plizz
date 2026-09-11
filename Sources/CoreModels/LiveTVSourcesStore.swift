import Foundation

public protocol LiveTVSourcesStoring: Sendable {
    func load() throws -> LiveTVSourcesConfiguration
    func save(_ configuration: LiveTVSourcesConfiguration) throws
}

public enum LiveTVSourcesStoreError: Error, Equatable, Sendable, LocalizedError {
    case loadFailed, invalidStoredValue, unsupportedVersion, saveFailed

    public var errorDescription: String? {
        switch self {
        case .loadFailed: "Your Live TV sources couldn't be loaded. Your saved sources have not been changed."
        case .invalidStoredValue: "Your saved Live TV sources couldn't be read. They have not been replaced."
        case .unsupportedVersion: "These Live TV sources were saved by a newer version of Plozz."
        case .saveFailed: "Your Live TV sources couldn't be saved. Try again."
        }
    }
}

/// Playlist and guide addresses may include query credentials. Never persist them in UserDefaults.
public final class LiveTVSourcesStore: LiveTVSourcesStoring, @unchecked Sendable {
    public static let baseKey = "com.plozz.liveTV.sources"
    private let secureStore: any SecureStoring
    private let key: String
    private let lock = NSLock()

    public init(secureStore: any SecureStoring, namespace: String? = nil) {
        self.secureStore = secureStore
        key = SettingsKey.scoped(Self.baseKey, namespace: namespace)
    }

    public func load() throws -> LiveTVSourcesConfiguration {
        lock.lock()
        defer { lock.unlock() }
        return try loadLocked()
    }

    public func save(_ configuration: LiveTVSourcesConfiguration) throws {
        try configuration.validate()
        let value: String
        do {
            let data = try JSONEncoder().encode(configuration)
            guard let string = String(data: data, encoding: .utf8) else {
                throw LiveTVSourcesStoreError.saveFailed
            }
            value = string
        } catch {
            throw LiveTVSourcesStoreError.saveFailed
        }
        lock.lock()
        defer { lock.unlock() }
        // Refuse a write even when a caller skipped load or the secure store became unreadable.
        _ = try loadLocked()
        do {
            try secureStore.setString(value, for: key)
        } catch {
            throw LiveTVSourcesStoreError.saveFailed
        }
    }

    private func loadLocked() throws -> LiveTVSourcesConfiguration {
        let value: String?
        do {
            value = try secureStore.readString(for: key)
        } catch {
            throw LiveTVSourcesStoreError.loadFailed
        }
        guard let value else { return .empty }
        do {
            let configuration = try JSONDecoder().decode(
                LiveTVSourcesConfiguration.self, from: Data(value.utf8)
            )
            try configuration.validate()
            return configuration
        } catch LiveTVSourcesStoreError.unsupportedVersion {
            throw LiveTVSourcesStoreError.unsupportedVersion
        } catch {
            throw LiveTVSourcesStoreError.invalidStoredValue
        }
    }
}
