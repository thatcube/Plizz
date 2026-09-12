#if DEBUG
import CoreUI
import FeatureLiveTVCore
import SwiftUI

struct LiveTVIdentityReviewView: View {
    let imports: LiveTVPrototypeImportModel
    let sourceID: String
    let authorize: () throws -> Void
    @State private var pending: Selection?
    @State private var failed = false
    @State private var saving = false

    private struct Selection { let channelID: String; let previousID: String }

    var body: some View {
        LiveTVSettingsPage(title: "Review channel identities") {
            ForEach(imports.identityReviews[sourceID] ?? []) { review in
                SettingsSectionGroup(verbatim: review.name) {
                    Text("This entry could not be safely linked to a saved channel. It remains a separate playable entry.")
                    ForEach(review.candidateIDs, id: \.self) { previous in
                        Button {
                            pending = Selection(channelID: review.channelID, previousID: previous)
                        } label: {
                            Text("Restore \(imports.identityCandidateName(previous))")
                        }
                        .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                        .disabled(saving)
                    }
                }
            }
            if failed {
                SettingsSectionGroup {
                    Text("This identity couldn't be restored. A saved channel cannot be replaced while it is still present.")
                }
            }
        }
        .confirmationDialog("Confirm the same station and feed?", isPresented: Binding(
            get: { pending != nil }, set: { if !$0 { pending = nil } }
        ), titleVisibility: .visible) {
            if let selection = pending {
                Button("Restore saved identity") {
                    pending = nil
                    saving = true
                    Task { @MainActor in
                        defer { saving = false }
                        do {
                            try authorize()
                            try await imports.confirmIdentity(
                                sourceID: sourceID, channelID: selection.channelID, previousChannelID: selection.previousID
                            )
                            failed = false
                        } catch { failed = true }
                    }
                }
            }
        } message: {
            Text("Only confirm when this is the same station and regional feed. Saved favorites, hidden state and guide corrections will use this entry.")
        }
    }
}
#endif
