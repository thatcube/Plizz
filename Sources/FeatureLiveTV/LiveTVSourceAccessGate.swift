#if DEBUG
import CoreModels
import CoreUI
import Observation
import SwiftUI

struct LiveTVSourceAccessGate<Content: View>: View {
    let model: LiveTVSourceManagementModel
    @ViewBuilder let content: () -> Content
    @Environment(ProfilesModel.self) private var profiles: ProfilesModel?

    var body: some View {
        if let profiles {
            LiveTVProfileSourceAccessGate(model: model, profiles: profiles, content: content)
        } else {
            ContentUnavailableView(
                "Profile settings unavailable",
                systemImage: "lock",
                description: Text("Return to Live TV and reopen Sources.")
            )
        }
    }
}

private struct LiveTVProfileSourceAccessGate<Content: View>: View {
    let model: LiveTVSourceManagementModel
    @State private var access: LiveTVSourceManagementAccess
    @ViewBuilder let content: () -> Content
    @Environment(\.dismiss) private var dismiss

    init(
        model: LiveTVSourceManagementModel,
        profiles: ProfilesModel,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.model = model
        _access = State(initialValue: LiveTVSourceManagementAccess(profiles: profiles))
        self.content = content
    }

    var body: some View {
        Group {
            if access.canManage {
                content()
            } else {
                PINEntryScaffold(
                    title: KidsProfileCopy.parentalPINEnter,
                    name: Text(KidsProfileCopy.parentalPIN),
                    errorMessage: access.errorMessage,
                    onSubmit: { access.unlock($0) },
                    onCancel: { dismiss() }
                ) {
                    PINBadge {
                        Image(systemName: "figure.and.child.holdinghands")
                            .font(.system(size: PINLayout.badgeSize * 0.45, weight: .semibold))
                    }
                }
            }
        }
        .onAppear {
            model.authorizeMutations { [weak access] in access?.canManage ?? false }
        }
    }
}

@MainActor
@Observable
final class LiveTVSourceManagementAccess {
    private struct Scope: Equatable {
        let profileID: String
        let parentalPIN: ParentalPIN?
    }

    @ObservationIgnored private let profiles: ProfilesModel
    private let expectedProfileID: String
    private var unlockedScope: Scope?
    private(set) var errorMessage: LocalizedStringResource?

    init(profiles: ProfilesModel) {
        self.profiles = profiles
        expectedProfileID = profiles.activeProfileID
    }

    var canManage: Bool {
        guard profiles.activeProfileID == expectedProfileID else { return false }
        guard profiles.activeProfile.isKids, profiles.parentalPIN != nil else { return true }
        return unlockedScope == scope
    }

    func unlock(_ pin: String) {
        guard profiles.activeProfileID == expectedProfileID, profiles.matchesParentalPIN(pin) else {
            errorMessage = ProfileLockCopy.incorrectPIN
            return
        }
        unlockedScope = scope
        errorMessage = nil
    }

    func lock() {
        unlockedScope = nil
        errorMessage = nil
    }

    private var scope: Scope {
        Scope(profileID: profiles.activeProfileID, parentalPIN: profiles.parentalPIN)
    }
}
#endif
