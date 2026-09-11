#if DEBUG && canImport(SwiftUI) && canImport(UIKit)
import CoreModels
import SwiftUI

/// Shell-owned native presentation controls for an already-retained engine.
@MainActor
public struct LiveChannelPresentationContext {
    public let engine: any LiveChannelEngine
    public let sessionID: UUID?
    public let permitsExternalPresentation: Bool
    public let isVisible: Bool
    public let showsControls: Bool
    public let intendsPlayback: Bool
    public let hasSelectedSubtitle: Bool
    public let continuationChanged: @MainActor (Bool) -> Void
    public let restoreUI: @MainActor () async -> Bool
    public let registerInvalidation: @MainActor (@escaping @MainActor () -> Void) -> Void
    public let stopPlayback: @MainActor () -> Void
}
#endif
