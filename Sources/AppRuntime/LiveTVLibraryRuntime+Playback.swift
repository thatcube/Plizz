#if DEBUG && canImport(AVFoundation)
import CoreModels
import FeatureLiveTVCore
import FeaturePlayback
import Foundation

extension LiveTVLibraryRuntime {
    public func makeEngine(
        engine: any LiveChannelEngine,
        onCompleted: @escaping @MainActor @Sendable (MediaItem, UUID) throws -> Void
    ) -> LibraryLiveChannelEngine {
        // An authorized external player must retain its runtime after the guide leaves.
        LibraryLiveChannelEngine(engine: engine) { [self] id, expectedAuthorization, decoder in
            guard let runtimeAuthorization = authorizationID else {
                throw LibraryChannelError.authorizationChanged
            }
            let context = try service.playbackContext(catalogID: "library:\(id.uuidString)")
            guard context.channelID == id, context.profileID == profileID,
                  context.authorizationID == expectedAuthorization else {
                throw LibraryChannelError.authorizationChanged
            }
            let currentAuthorization: @MainActor @Sendable () -> String? = { [self] in
                guard authorizationID == runtimeAuthorization,
                      context.authorizationID == expectedAuthorization else { return nil }
                return expectedAuthorization
            }
            let session = LibraryChannelPlaybackSession(
                channelID: id,
                engine: decoder,
                schedule: { currentAuthorization() == nil ? nil : context.schedule() },
                provider: { item in
                    guard currentAuthorization() != nil else { return nil }
                    return context.provider(for: item)
                },
                authorization: currentAuthorization,
                historyAuthorization: { [history] in
                    guard currentAuthorization() != nil else { return nil }
                    return history.authorizationID
                },
                historyReporting: .externalCompletion { [history] scheduled, item, token in
                    try Task.checkCancellation()
                    guard currentAuthorization() != nil, history.authorizationID == token,
                          context.provider(for: scheduled) != nil else {
                        throw LibraryChannelError.authorizationChanged
                    }
                    try onCompleted(Self.completedItem(item, scheduled: scheduled), token)
                }
            )
            session.setTrackPreferences(
                audioLanguages: trackPreferences.audioLanguage.map { [$0] } ?? [],
                subtitleLanguages: trackPreferences.subtitleMode == .off
                    ? [] : trackPreferences.subtitleLanguage.map { [$0] } ?? []
            )
            return session
        }
    }

    static func completedItem(_ item: MediaItem, scheduled: LibraryChannelItem) throws -> MediaItem {
        guard item.id == scheduled.itemID, item.kind == scheduled.kind,
              item.sourceAccountID == nil || item.sourceAccountID == scheduled.library.accountID else {
            throw LibraryChannelError.mediaChanged
        }
        var completed = item
        completed.sourceAccountID = scheduled.library.accountID
        return completed
    }
}
#endif
