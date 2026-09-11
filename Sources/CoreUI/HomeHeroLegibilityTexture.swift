#if canImport(SwiftUI)
import SwiftUI

/// Pre-rendered alpha for Home's fixed legibility treatment. Only the image
/// shading is baked; the theme's opaque black/white tone stays live.
public struct HomeHeroLegibilityTexture: View {
    private let tone: Color

    public init(tone: Color) {
        self.tone = tone
    }

    @ViewBuilder
    public var body: some View {
        if tone == .black || tone == .white {
            Image("HomeHeroLegibility", bundle: .module)
                .resizable()
                .renderingMode(.template)
                .foregroundStyle(tone)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        } else {
            HeroLegibilityScrim(
                tone: tone, edgePeak: 0.55,
                edges: [.leading, .bottom], sideDarkeningStart: 0.34
            )
        }
    }
}
#endif
