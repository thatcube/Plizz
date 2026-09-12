#if DEBUG
import CoreUI
import SwiftUI

struct LiveTVSettingsPage<Content: View>: View {
    let title: LocalizedStringResource
    @ViewBuilder let content: () -> Content

    var body: some View {
        #if os(tvOS)
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SettingsPageHeader(title)
                content()
            }
            .frame(maxWidth: PlozzTheme.Metrics.settingsContentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
            .padding(.vertical, 24)
        }
        .scrollClipDisabled()
        .background { SettingsPageBackground() }
        #else
        SettingsPageList {
            content()
        }
        .navigationTitle(Text(title))
        #endif
    }
}
#endif
