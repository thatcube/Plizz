#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import MetadataKit

public enum DetailBackdropArtwork {
    public static func fallback(
        for item: MediaItem, isDiscoveryItem: Bool
    ) -> (@Sendable () async -> URL?)? {
        guard ![.folder, .collection, .unknown].contains(item.kind) else { return nil }
        // Discovery enrichment owns its first backdrop; do not race a different chooser.
        guard !isDiscoveryItem || item.heroBackdropURL != nil || item.backdropURL != nil else { return nil }
        return {
            await ArtworkRouter.shared.heroArtworkURL(for: item, placement: .detailBackdrop) ?? item.posterURL
        }
    }
}

#if os(tvOS)
@MainActor
final class DetailBackdropArtworkRequest {
    let key: String
    let task: Task<FirstPaintArtwork?, Never>

    init?(item: MediaItem) {
        let references = item.artworkReferences(for: .detailBackdrop)
        guard !references.isEmpty else { return nil }
        let settings = MetadataProviderSettingsStore().load()
        key = ArtworkResolveKey.make(
            references: references, variant: .heroBackdrop, maxAspectRatio: 3,
            pinIdentity: "detail:\(item.id)",
            providerPolicyIdentity: ArtworkResolveKey.policyIdentity(settings)
        )
        let fallback = DetailBackdropArtwork.fallback(
            for: item, isDiscoveryItem: TitleClassifier.isDiscoveryRouting(item, identitySources: item.sources)
        )
        task = Task {
            await ArtworkFirstPaintResolver.resolve(
                references: references, variant: .heroPreview, maxAspectRatio: 3,
                asyncOnlineURL: fallback,
                maximumOnlineWait: ArtworkFirstPaintResolver.focalArtworkWait,
                prefersOnlineArtwork: settings.preferOnlineArtwork
            )
        }
    }

    deinit { task.cancel() }
}

private enum DetailBackdropCompositing {
    static let usesCachedScrim =
        ProcessInfo.processInfo.environment["PLZDETAIL_CACHED_SCRIM"] != "0"
}
#endif

/// The shared, full-bleed hero **backdrop** treatment: a wide landscape image
/// with a mode-appropriate legibility scrim and a bottom dissolve that melts the
/// artwork into the app background. Detail pages share Home's fixed legibility
/// shading while retaining their own dissolve geometry.
///
/// It is deliberately *purely visual and layout-neutral*: it renders as the host
/// view's `.background`, ignores the tvOS overscan safe area, and never reports a
/// size that would inflate its parent's layout width — matching how the detail
/// hero hosts its backdrop.
///
/// ### Background-video slot (phased trailer support)
/// The optional `backgroundVideo` view builder overlays the static image and
/// receives the exact same scrim + dissolve + clip treatment, so a muted looping
/// trailer can later be faded in on top of the still without any rework. It is an
/// `EmptyView` by default (today), so the image-only path is byte-for-byte the
/// same as the detail hero's original backdrop.
public struct HeroBackdropLayer<Video: View>: View {
    #if os(tvOS)
    @Environment(\.detailEntranceSession) private var detailEntrance
    @State private var artworkResolution = ArtworkResolutionState()
    #endif
    /// Ordered candidate backdrop URLs (first that loads and is wide enough wins).
    private let references: [ArtworkReference]
    /// Last-resort async art lookup (e.g. TMDb fanart) when none of `urls` load.
    private let asyncFallbackURL: (@Sendable () async -> URL?)?
    /// The backdrop's rendered height (the caller scales this by any hero-height
    /// fraction / bottom extension before passing it in).
    private let height: CGFloat
    /// Legibility scrim tone — dark in dark mode (for light content), light in
    /// light mode (for dark content). Geometry is identical; only the tone flips.
    private let scrimTone: Color
    /// Layout-neutral vertical translation used by a receding hero. Applied before
    /// overscan breakout so the full artwork layer moves as one screen-pinned image.
    private let verticalOffset: CGFloat
    /// Fraction of the height at which the bottom dissolve *begins* (the image is
    /// fully opaque above it and fades to transparent by the bottom edge). The
    /// item **detail** hero melts into the page early (`0.33`) because content
    /// scrolls up over it; the **Home** hero fills the screen, so it keeps the
    /// artwork opaque far lower and only feathers the very bottom into the
    /// Continue Watching panel.
    private let dissolveStart: CGFloat
    /// Whether this layer breaks out of the tvOS overscan safe area itself. `true`
    /// (the detail hero + the single-image case) makes it span the physical screen
    /// edge to edge. `false` is used when the caller lays several backdrops side by
    /// side (the Home hero filmstrip): each cell must stay at its exact frame width
    /// so the strip tiles correctly, and the *container* applies the overscan
    /// breakout once for the whole strip.
    private let ignoresOverscan: Bool
    /// Opacity of the still image beneath the video slot. Detail handoff sets
    /// this to zero while the shared trailer is already playing, letting the
    /// existing Home video remain visible through the navigation transition
    /// until the newly-mounted AVPlayerLayer presents its first frame.
    private let stillImageOpacity: Double
    private let pinIdentity: String?
    /// Overrides the platform default for embedding and controlled comparisons.
    /// Unsupported tones/directions still retain the original analytic shading.
    private let prefersCachedScrim: Bool?
    /// Overlaid on the still image; empty today, hosts a faded-in trailer later.
    private let backgroundVideo: () -> Video

    public init(
        urls: [URL],
        asyncFallbackURL: (@Sendable () async -> URL?)? = nil,
        height: CGFloat,
        scrimTone: Color,
        verticalOffset: CGFloat = 0,
        dissolveStart: CGFloat = 0.33,
        ignoresOverscan: Bool = true,
        stillImageOpacity: Double = 1,
        pinIdentity: String? = nil,
        prefersCachedScrim: Bool? = nil,
        @ViewBuilder backgroundVideo: @escaping () -> Video
    ) {
        self.references = urls.map(ArtworkReference.remote)
        self.asyncFallbackURL = asyncFallbackURL
        self.height = height
        self.scrimTone = scrimTone
        self.verticalOffset = verticalOffset
        self.dissolveStart = dissolveStart
        self.ignoresOverscan = ignoresOverscan
        self.stillImageOpacity = stillImageOpacity
        self.pinIdentity = pinIdentity
        self.prefersCachedScrim = prefersCachedScrim
        self.backgroundVideo = backgroundVideo
    }

    public init(
        references: [ArtworkReference],
        asyncFallbackURL: (@Sendable () async -> URL?)? = nil,
        height: CGFloat,
        scrimTone: Color,
        verticalOffset: CGFloat = 0,
        dissolveStart: CGFloat = 0.33,
        ignoresOverscan: Bool = true,
        stillImageOpacity: Double = 1,
        pinIdentity: String? = nil,
        prefersCachedScrim: Bool? = nil,
        @ViewBuilder backgroundVideo: @escaping () -> Video
    ) {
        self.references = references
        self.asyncFallbackURL = asyncFallbackURL
        self.height = height
        self.scrimTone = scrimTone
        self.verticalOffset = verticalOffset
        self.dissolveStart = dissolveStart
        self.ignoresOverscan = ignoresOverscan
        self.stillImageOpacity = stillImageOpacity
        self.pinIdentity = pinIdentity
        self.prefersCachedScrim = prefersCachedScrim
        self.backgroundVideo = backgroundVideo
    }

    public var body: some View {
        FallbackAsyncImage(
            references: references,
            maxAspectRatio: 3.0,
            variant: .heroBackdrop,
            // Put a real image up while the 2000px pass decodes. Home's hero has
            // always done this; the detail hero opened onto a scrim instead.
            previewVariant: .heroPreview,
            asyncFallbackURL: asyncFallbackURL,
            preferredArtworkWait: ArtworkFirstPaintResolver.focalArtworkWait,
            pinIdentity: pinIdentity,
            content: ArtworkFillImage.init,
            placeholder: { ambientPlaceholder }
        )
        #if os(tvOS)
        .environment(\.artworkResolutionState, artworkResolution)
        .onChange(of: artworkResolution.image, initial: true) { _, image in
            if stillImageOpacity > 0, let image { detailEntrance?.resolvedDestinationArtwork(image) }
        }
        .onChange(of: artworkResolution.isResolved, initial: true) { _, resolved in
            if stillImageOpacity > 0, resolved, artworkResolution.image == nil {
                detailEntrance?.destinationArtworkUnavailable()
            }
        }
        #endif
        .opacity(stillImageOpacity)
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .clipped()
        // Trailer slot: overlays the still (and so inherits the scrim + dissolve
        // below). Empty today — no layout or visual effect on the image-only path.
        .overlay { backgroundVideo() }
        .overlay(scrim)
        .mask(dissolveMask)
        .offset(y: verticalOffset)
        // Break out of the tvOS overscan safe area so the backdrop spans the full
        // screen edge to edge — across the top too, otherwise the top overscan
        // inset shows through as a black bar above the artwork. Skipped when the
        // caller tiles several cells (the Home hero filmstrip) and applies the
        // breakout once at the container instead.
        .modifier(OverscanBreakout(enabled: ignoresOverscan))
    }

    /// Legibility scrim: a seamless edge vignette (same darkening on every side)
    /// plus a faint all-over wash, so the title/logo/overview read clearly against
    /// the artwork while the darkening blends evenly across the whole hero instead
    /// of pooling on one side — matching the Home hero. Lives *under* the dissolve
    /// mask so it fades away with the image and never tints the revealed background.
    @ViewBuilder
    private var scrim: some View {
        if usesCachedScrim {
            HeroLegibilityTexture(tone: scrimTone)
        } else {
            analyticScrim
        }
    }

    private var usesCachedScrim: Bool {
        if let prefersCachedScrim { return prefersCachedScrim }
        #if os(tvOS)
        return DetailBackdropCompositing.usesCachedScrim
        #else
        return false
        #endif
    }

    private var analyticScrim: some View {
        // TEST: top and trailing dropped. Detail-page content runs along the
        // LEFT and fades out at the BOTTOM, so those two edges are the only ones
        // doing legibility work; darkening the other two only costs contrast on
        // the part of the artwork the viewer is actually looking at.
        HeroLegibilityScrim(
            tone: scrimTone,
            edgePeak: 0.55,
            edges: [.leading, .bottom],
            // Keep the top-left clean: nothing is drawn over it, so darkening it
            // only flattens the artwork. The wash arrives where the content is.
            sideDarkeningStart: 0.34
        )
    }

    /// Dissolves the backdrop's own alpha to transparent over the lower portion
    /// (top third stays a clean image) so the real app background shows straight
    /// through — a perfectly seamless transition with no second colour to mismatch.
    private var dissolveMask: some View {
        LinearGradient(
            stops: [
                .init(color: .white, location: 0.0),
                .init(color: .white, location: dissolveStart),
                .init(color: .clear, location: 1.0)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// Never put the outgoing thumbnail back under the incoming detail artwork.
    private var ambientPlaceholder: some View {
        LinearGradient(
            colors: [
                scrimTone.opacity(0.28),
                scrimTone.opacity(0.10)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

/// Applies the tvOS overscan breakout only when `enabled`, so the same backdrop
/// view can either span the physical screen (detail hero / single image) or stay
/// within its given frame (a cell in the Home hero filmstrip).
private struct OverscanBreakout: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled {
            content.ignoresSafeArea(edges: [.top, .horizontal])
        } else {
            content
        }
    }
}

public extension HeroBackdropLayer where Video == EmptyView {
    /// Image-only backdrop (no trailer slot) — the default today.
    init(
        urls: [URL],
        asyncFallbackURL: (@Sendable () async -> URL?)? = nil,
        height: CGFloat,
        scrimTone: Color,
        verticalOffset: CGFloat = 0,
        dissolveStart: CGFloat = 0.33,
        ignoresOverscan: Bool = true,
        stillImageOpacity: Double = 1,
        prefersCachedScrim: Bool? = nil
    ) {
        self.init(
            urls: urls,
            asyncFallbackURL: asyncFallbackURL,
            height: height,
            scrimTone: scrimTone,
            verticalOffset: verticalOffset,
            dissolveStart: dissolveStart,
            ignoresOverscan: ignoresOverscan,
            stillImageOpacity: stillImageOpacity,
            prefersCachedScrim: prefersCachedScrim,
            backgroundVideo: { EmptyView() }
        )
    }

    init(
        references: [ArtworkReference],
        asyncFallbackURL: (@Sendable () async -> URL?)? = nil,
        height: CGFloat,
        scrimTone: Color,
        verticalOffset: CGFloat = 0,
        dissolveStart: CGFloat = 0.33,
        ignoresOverscan: Bool = true,
        stillImageOpacity: Double = 1,
        prefersCachedScrim: Bool? = nil
    ) {
        self.init(
            references: references,
            asyncFallbackURL: asyncFallbackURL,
            height: height,
            scrimTone: scrimTone,
            verticalOffset: verticalOffset,
            dissolveStart: dissolveStart,
            ignoresOverscan: ignoresOverscan,
            stillImageOpacity: stillImageOpacity,
            prefersCachedScrim: prefersCachedScrim,
            backgroundVideo: { EmptyView() }
        )
    }
}
#endif
