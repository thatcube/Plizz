import CoreModels
import Foundation
import Observation
import SwiftUI

/// Leaf-only presentation for the application's single multiplexed cloud service.
/// The profile-model identity prevents another household/preview from borrowing
/// availability. This holds neither transport nor source credentials.
@MainActor
@Observable
public final class LiveTVPortableSyncPresentation {
    public static let shared = LiveTVPortableSyncPresentation()
    private var revision = 0
    @ObservationIgnored private weak var profiles: ProfilesModel?
    @ObservationIgnored private var availability: @MainActor () -> Bool = { false }
    @ObservationIgnored private var status: @MainActor (String) -> LocalizedStringResource? = { _ in nil }
    @ObservationIgnored private var makePendingSources: @MainActor (ProfilesModel) -> AnyView = { _ in AnyView(EmptyView()) }

    public init() {}

    public func connect(
        profiles: ProfilesModel,
        isAvailable: @escaping @MainActor () -> Bool = { true },
        pendingSources: @escaping @MainActor (ProfilesModel) -> AnyView = { _ in AnyView(EmptyView()) },
        status: @escaping @MainActor (String) -> LocalizedStringResource?
    ) {
        self.profiles = profiles
        availability = isAvailable
        makePendingSources = pendingSources
        self.status = status
        revision &+= 1
    }

    public func isAvailable(profiles: ProfilesModel) -> Bool {
        _ = revision
        return self.profiles === profiles && availability()
    }

    public func summary(profileID: String) -> LocalizedStringResource? {
        _ = revision
        return status(profileID)
    }

    public func pendingSources(profiles: ProfilesModel) -> AnyView {
        guard isAvailable(profiles: profiles) else { return AnyView(EmptyView()) }
        return makePendingSources(profiles)
    }
}

/// A leaf slot keeps FeatureLiveTV out of FeatureSettings/CoreUI dependencies.
public struct LiveTVPortableSyncPendingSettings: View {
    @Environment(ProfilesModel.self) private var profiles: ProfilesModel?

    public init() {}

    public var body: some View {
        if let profiles {
            LiveTVPortableSyncPresentation.shared.pendingSources(profiles: profiles)
                .id(profiles.activeProfileID)
        }
    }
}
