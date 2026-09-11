#if canImport(SwiftUI) && canImport(UIKit)
import CoreModels
import SwiftUI
import UIKit

/// One cached logo and backing treatment for channel guides and live playback.
public struct ChannelLogoArtwork: View {
    private let name: String
    private let logoURL: URL?
    private let size: CGSize
    private let cornerRadius: CGFloat
    private let artworkInset: CGFloat
    @State private var loaded: LoadedLogo?

    public init(
        name: String,
        logoURL: URL?,
        size: CGSize,
        cornerRadius: CGFloat,
        artworkInset: CGFloat? = nil
    ) {
        self.name = name
        self.logoURL = logoURL
        self.size = size
        self.cornerRadius = cornerRadius
        self.artworkInset = artworkInset ?? size.height * 20 / 128
    }

    private var current: LoadedLogo? {
        if let loaded, loaded.url == logoURL { return loaded }
        guard let logoURL,
              let cached = HeroLogoMemo.value(for: HeroLogoMemo.key(for: [.remote(logoURL)])) else {
            return nil
        }
        return LoadedLogo(url: logoURL, processed: cached)
    }

    public var body: some View {
        ChannelLogoPlateContent(
            name: name, image: current?.image,
            plate: current?.plate ?? ChannelLogoPlate(tone: nil),
            size: size, cornerRadius: cornerRadius, artworkInset: artworkInset
        )
        .task(id: logoURL) {
            guard let logoURL else {
                loaded = nil
                return
            }
            let prepared = await HeroLogoPipeline.shared.preparedLogo(for: .remote(logoURL))
            guard !Task.isCancelled else { return }
            loaded = prepared.map {
                let processed = HeroLogoAnalysis.analyze($0, backgroundSample: nil)
                HeroLogoMemo.store(processed, for: HeroLogoMemo.key(for: [.remote(logoURL)]))
                return LoadedLogo(url: logoURL, processed: processed)
            }
        }
        .accessibilityHidden(true)
    }

    private struct LoadedLogo {
        let url: URL
        let image: UIImage
        let plate: ChannelLogoPlate

        init(url: URL, processed: ProcessedLogo) {
            self.url = url
            image = processed.image
            plate = ChannelLogoPlate(tone: processed.tone)
        }
    }
}

struct ChannelLogoPlate: Equatable {
    let red: Double
    let green: Double
    let blue: Double

    init(tone: ResolvedLogoTone?) {
        if let original = tone?.backgroundPlate {
            red = original.red
            green = original.green
            blue = original.blue
            return
        }

        // A small white wordmark still needs dark backing, regardless of the
        // larger coloured icon. Brand tint stays secondary to that contrast.
        let usesLightBacking = tone.map { $0.brightInk < 0.04 && $0.luminance < 0.70 } ?? false
        let base = usesLightBacking
            ? (red: 1.0, green: 1.0, blue: 1.0)
            : (red: 0.14, green: 0.15, blue: 0.17)
        let ink = (red: tone?.red ?? 0, green: tone?.green ?? 0, blue: tone?.blue ?? 0)
        let chroma = max(ink.red, ink.green, ink.blue) - min(ink.red, ink.green, ink.blue)
        let tint = chroma > 0.12 ? (usesLightBacking ? 0.08 : 0.12) : 0
        let mean = (ink.red + ink.green + ink.blue) / 3
        let muted = (
            red: mean + (ink.red - mean) * 0.45,
            green: mean + (ink.green - mean) * 0.45,
            blue: mean + (ink.blue - mean) * 0.45
        )
        red = max(usesLightBacking ? 0 : base.red, base.red + (muted.red - base.red) * tint)
        green = max(usesLightBacking ? 0 : base.green, base.green + (muted.green - base.green) * tint)
        blue = max(usesLightBacking ? 0 : base.blue, base.blue + (muted.blue - base.blue) * tint)
    }

    var color: Color { Color(red: red, green: green, blue: blue) }
    var isLight: Bool { 0.2126 * red + 0.7152 * green + 0.0722 * blue > 0.55 }
}

struct ChannelLogoPlateContent: View {
    let name: String
    let image: UIImage?
    let plate: ChannelLogoPlate
    let size: CGSize
    let cornerRadius: CGFloat
    let artworkInset: CGFloat
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .renderingMode(.original)
                    .resizable()
                    .scaledToFit()
            } else {
                Text(name)
                    .font(.system(size: size.height * 0.22, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(plate.isLight ? Color.black : Color.white)
            }
        }
        .frame(
            width: max(1, size.width - artworkInset * 2),
            height: max(1, size.height - artworkInset * 2)
        )
        .frame(width: size.width, height: size.height)
        .background(plate.color)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    (plate.isLight ? Color.black : Color.white)
                        .opacity(contrast == .increased ? 0.4 : 0.14),
                    lineWidth: contrast == .increased ? 2 : 1
                )
                .allowsHitTesting(false)
        }
    }
}
#endif
