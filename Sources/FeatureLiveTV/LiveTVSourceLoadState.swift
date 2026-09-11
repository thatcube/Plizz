#if DEBUG
import SwiftUI

struct LiveTVSourceLoadState: View {
    let issue: LiveTVSourceManagementModel.Issue?
    let applicationFailed: Bool
    let retry: () -> Void

    var body: some View {
        if issue != nil || applicationFailed {
            ContentUnavailableView {
                Label("Live TV sources unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                if let issue {
                    Text(issue.message)
                } else {
                    Text("Your saved setup couldn't be applied. Playback is stopped and your sources haven't been replaced.")
                }
            } actions: {
                Button("Retry", action: retry)
            }
        } else {
            ProgressView("Loading your Live TV setup")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
#endif
