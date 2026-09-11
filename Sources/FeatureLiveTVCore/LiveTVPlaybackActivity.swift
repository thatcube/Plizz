/// Visibility may yield to one authorized external presentation, never to a
/// profile or network-policy failure.
public struct LiveTVPlaybackActivity: Equatable, Sendable {
    public let isPlaybackActive: Bool
    public let acceptsInteraction: Bool

    public init(
        isDestinationActive: Bool,
        isSceneActive: Bool,
        isInBackground: Bool,
        isAuthorized: Bool,
        allowsPlayback: Bool,
        hasAuthorizedExternalPresentation: Bool
    ) {
        let permitted = isAuthorized && allowsPlayback
        isPlaybackActive = permitted
            && ((isDestinationActive && !isInBackground) || hasAuthorizedExternalPresentation)
        acceptsInteraction = permitted && isDestinationActive && isSceneActive && !isInBackground
    }

    public func countsAsWatching(
        isUserRequested: Bool, isPictureVisible: Bool, isExternallyPresented: Bool
    ) -> Bool {
        isPlaybackActive && isUserRequested
            && (isExternallyPresented || (acceptsInteraction && isPictureVisible))
    }
}
