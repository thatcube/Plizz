#if canImport(SwiftUI)
import SwiftUI

/// The shared page-level Settings heading. Add a subtitle only when the title
/// cannot communicate the scope of the page.
public struct SettingsPageHeader: View {
    private let title: Text
    private let subtitle: Text?

    public init(_ title: LocalizedStringResource, subtitle: LocalizedStringResource? = nil) {
        self.title = Text(title)
        self.subtitle = subtitle.map(Text.init)
    }

    public init(verbatim title: String, subtitle: LocalizedStringResource? = nil) { // l10n:content
        self.title = Text(verbatim: title)
        self.subtitle = subtitle.map(Text.init)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            title
                .font(.largeTitle.bold())
            if let subtitle {
                subtitle
                    .font(.subheadline)
                    .plozzForeground(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif
