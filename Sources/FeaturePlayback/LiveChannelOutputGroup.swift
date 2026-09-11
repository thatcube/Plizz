#if canImport(AVFoundation)
import Foundation

/// Coordinates process-wide output policy without transferring or rebuilding players.
@MainActor
public final class LiveChannelOutputGroup {
    private var engines: [UUID: any LiveChannelEngine] = [:]
    private var audibleID: UUID?
    private var displayOwnerID: UUID?

    public init() {}

    public func register(_ engine: any LiveChannelEngine, id: UUID, audible: Bool) {
        if let previous = engines[id], previous !== engine {
            previous.configureLiveOutput(.init(
                isAudible: false, sharesAudioSession: true, suppressesDisplayMatching: true
            ))
        }
        engine.configureLiveOutput(.init(
            isAudible: false, sharesAudioSession: true,
            suppressesDisplayMatching: displayOwnerID != nil
        ))
        engines[id] = engine
        if displayOwnerID == nil { displayOwnerID = id }
        if audible { selectAudio(id) } else { applyPolicies() }
    }

    public func setAudible(
        _ audible: Bool, id: UUID, engine expectedEngine: (any LiveChannelEngine)? = nil
    ) {
        guard let engine = engines[id],
              expectedEngine == nil || expectedEngine === engine else { return }
        if audible {
            selectAudio(id)
        } else if audibleID == id {
            audibleID = nil
            applyPolicies()
        }
    }

    /// Call before the departing engine stops. Only the last stop may reset shared output.
    public func unregister(_ id: UUID, engine expectedEngine: (any LiveChannelEngine)? = nil) {
        guard let engine = engines[id],
              expectedEngine == nil || expectedEngine === engine else { return }
        engines.removeValue(forKey: id)
        if audibleID == id { audibleID = nil }
        if displayOwnerID == id {
            displayOwnerID = engines.keys.sorted { $0.uuidString < $1.uuidString }.first
        }
        engine.configureLiveOutput(.init(
            isAudible: false,
            sharesAudioSession: !engines.isEmpty,
            suppressesDisplayMatching: !engines.isEmpty
        ))
        applyPolicies()
    }

    private func selectAudio(_ id: UUID) {
        // Mute the former owner synchronously before making another stream audible.
        audibleID = nil
        applyPolicies()
        audibleID = id
        applyPolicies()
    }

    private func applyPolicies() {
        for (id, engine) in engines {
            engine.configureLiveOutput(.init(
                isAudible: id == audibleID,
                sharesAudioSession: true,
                suppressesDisplayMatching: id != displayOwnerID
            ))
        }
    }
}
#endif
