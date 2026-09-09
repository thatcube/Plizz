import SwiftUI
import CoreModels

/// One line at every width. Detailed formats yield to an explicit disclosure,
/// never a smaller font or a second row.
public struct DetailHeaderMetadataRow: View {
    private let ratings: [ExternalRating]
    private let badges: [MediaBadge]
    @State private var showsDetails = false

    public init(ratings: [ExternalRating], badges: [MediaBadge]) {
        self.ratings = ratings
        self.badges = badges
    }

    public var body: some View {
        if !ratings.isEmpty || !badges.isEmpty {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    ForEach(ratings) { RatingBadge(rating: $0) }
                    if !badges.isEmpty {
                        Button { showsDetails = true } label: {
                            HStack(spacing: 10) {
                                ForEach(badges) { badge in
                                    MetadataMediaBadgeChip(badge: badge)
                                }
                            }
                        }
                        .accessibilityLabel("Picture & sound")
                        .accessibilityValue(badges.map(\.accessibilityText).joined(separator: ", "))
                    }
                }
                .fixedSize(horizontal: true, vertical: true)

                HStack(spacing: 12) {
                    ForEach(ratings) { RatingBadge(rating: $0) }
                    if !badges.isEmpty {
                        Button { showsDetails = true } label: {
                            Label("Formats", systemImage: "info.circle")
                                .font(.subheadline.weight(.medium))
                        }
                    }
                }
                .fixedSize(horizontal: true, vertical: true)

                Button { showsDetails = true } label: {
                    Text(detailsTitle)
                        .font(.subheadline.weight(.medium))
                }
                .fixedSize(horizontal: true, vertical: true)

                Button { showsDetails = true } label: {
                    Image(systemName: "info.circle")
                        .font(.body)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(Text(detailsTitle))
            }
            .lineLimit(1)
            .buttonStyle(.plain)
            .plozzForeground(.primary)
            .frame(maxWidth: .infinity, alignment: .center)
            .sheet(isPresented: $showsDetails) {
                NavigationStack {
                    List {
                        if !ratings.isEmpty {
                            Section("Ratings") {
                                ForEach(ratings) { rating in
                                    HStack {
                                        Text(verbatim: rating.source.displayName)
                                        Spacer()
                                        RatingBadge(rating: rating)
                                    }
                                }
                            }
                        }
                        if !badges.isEmpty {
                            Section("Picture & sound") {
                                ForEach(badges) { badge in
                                    MediaBadgeChip(badge: badge)
                                }
                            }
                        }
                    }
                    .lineLimit(nil)
                    .navigationTitle(Text(detailsTitle))
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showsDetails = false }
                        }
                    }
                }
            }
        }
    }

    private var detailsTitle: LocalizedStringResource {
        if ratings.isEmpty { return "Picture & sound" }
        if badges.isEmpty { return "Ratings" }
        return "Ratings & formats"
    }
}
