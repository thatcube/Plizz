#if canImport(SwiftUI)
import SwiftUI
import CoreModels

/// Keeps sparse metadata inline and separates ratings only when the content needs it.
public struct AdaptiveMediaMetadataRow: View {
    private let facts: [String]
    private let ratings: [ExternalRating]
    private let badges: [MediaBadge]
    private let centered: Bool

    public init(
        facts: [String],
        ratings: [ExternalRating],
        badges: [MediaBadge],
        centered: Bool = false
    ) {
        self.facts = facts
        self.ratings = ratings
        self.badges = badges
        self.centered = centered
    }

    public var body: some View {
        if !facts.isEmpty || !ratings.isEmpty || !badges.isEmpty {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    MetadataFactsText(facts: facts)
                    ForEach(ratings) { rating in
                        RatingBadge(rating: rating)
                    }
                    ForEach(badges) { badge in
                        MetadataMediaBadgeChip(badge: badge)
                    }
                }
                .fixedSize(horizontal: true, vertical: false)

                VStack(alignment: centered ? .center : .leading, spacing: 8) {
                    if !facts.isEmpty || !badges.isEmpty {
                        MetadataFactsAndFormats(
                            facts: facts,
                            badges: badges,
                            centered: centered
                        )
                    }
                    if !ratings.isEmpty {
                        WrappingHStackLayout(
                            alignment: centered ? .center : .leading,
                            spacing: 12,
                            lineSpacing: 8,
                            balancesLastRow: true
                        ) {
                            ForEach(ratings) { rating in
                                RatingBadge(rating: rating)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
        }
    }
}

private struct MetadataFactsAndFormats: View {
    let facts: [String]
    let badges: [MediaBadge]
    let centered: Bool

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                MetadataFactsText(facts: facts)
                ForEach(badges) { badge in
                    MetadataMediaBadgeChip(badge: badge)
                }
            }
            .fixedSize(horizontal: true, vertical: false)

            VStack(alignment: centered ? .center : .leading, spacing: 8) {
                MetadataFactsText(facts: facts, wraps: true)
                    .multilineTextAlignment(centered ? .center : .leading)
                if !badges.isEmpty {
                    WrappingHStackLayout(
                        alignment: centered ? .center : .leading,
                        spacing: 12,
                        lineSpacing: 8,
                        balancesLastRow: true
                    ) {
                        ForEach(badges) { badge in
                            MetadataMediaBadgeChip(badge: badge)
                        }
                    }
                }
            }
        }
    }
}

private struct MetadataFactsText: View {
    let facts: [String]
    var wraps = false

    var body: some View {
        if !facts.isEmpty {
            Text(facts.joined(separator: "  \u{00B7}  "))
                .font(.subheadline.weight(.medium))
                .plozzForeground(.primary)
                .lineLimit(wraps ? nil : 1)
                .fixedSize(horizontal: !wraps, vertical: true)
        }
    }
}
#endif
