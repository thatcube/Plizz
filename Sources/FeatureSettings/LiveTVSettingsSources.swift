#if DEBUG && canImport(SwiftUI)
import Observation
import SwiftUI

@MainActor
@Observable
public final class LiveTVSettingsSources {
    @ObservationIgnored private let makeContent: () -> AnyView

    public init(content: @escaping () -> AnyView) {
        makeContent = content
    }

    public func content() -> AnyView { makeContent() }
}
#endif
