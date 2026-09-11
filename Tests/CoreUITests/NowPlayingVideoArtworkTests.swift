#if canImport(UIKit)
import CoreModels
import CoreText
import MediaPlayer
import UIKit
import XCTest
@testable import CoreUI

@MainActor
final class NowPlayingVideoArtworkTests: XCTestCase {
    private let backdrop = URL(string: "https://example.test/backdrop.jpg")!
    private let poster = URL(string: "https://example.test/poster.jpg")!

    func testBackdropPublishesBeforeLogoAndComposesAtRequestedSizes() async throws {
        let background = image(.blue, size: CGSize(width: 320, height: 180))
        let logo = preparedLogo(.black, monochrome: true)
        var updates: [MPMediaItemArtwork] = []
        await NowPlayingVideoArtwork.load(
            for: movie(),
            imageLoader: { _ in background },
            logoLoader: { _ in
                XCTAssertEqual(updates.count, 1, "Publish plain artwork before awaiting the logo")
                return logo
            },
            onUpdate: { updates.append($0) }
        )
        XCTAssertEqual(updates.count, 2)
        let artwork = try XCTUnwrap(updates.last)
        XCTAssertEqual(artwork.bounds.size, CGSize(width: 180, height: 180))
        XCTAssertEqual(updates.first?.bounds, artwork.bounds, "A late logo must not change the artwork shape")
        for size in [CGSize(width: 180, height: 180), CGSize(width: 160, height: 90),
                     CGSize(width: 40, height: 40)] {
            let result = try XCTUnwrap(artwork.image(at: size))
            XCTAssertEqual(result.size, size)
            XCTAssertEqual(try pixel(result, at: CGPoint(x: size.width / 2, y: size.height / 2)),
                           [255, 255, 255], "Monochrome ink becomes white, not a black block")
            let corner = try pixel(result, at: CGPoint(x: 1, y: 1))
            XCTAssertEqual(corner[0], 0)
            XCTAssertEqual(corner[1], 0)
            XCTAssertGreaterThan(corner[2], 150)
            XCTAssertLessThan(corner[2], 200, "Only a restrained backdrop dim")
            let attachment = XCTAttachment(image: result)
            attachment.name = "Now Playing \(Int(size.width))x\(Int(size.height))"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testMissingLogoLeavesBackdropUnchanged() async throws {
        let background = image(.blue, size: CGSize(width: 320, height: 180))
        var updates: [MPMediaItemArtwork] = []
        await NowPlayingVideoArtwork.load(
            for: movie(), imageLoader: { _ in background }, logoLoader: { _ in nil },
            onUpdate: { updates.append($0) }
        )
        XCTAssertEqual(updates.count, 1)
        let result = try XCTUnwrap(updates.first?.image(at: background.size))
        XCTAssertEqual(try pixel(result, at: CGPoint(x: 160, y: 90)), [0, 0, 255])
    }

    func testFailedBackdropFallsBackToAnUnbrandedPosterEvenWhenPosterIsWide() async throws {
        let background = image(.blue, size: CGSize(width: 320, height: 180))
        var attempted: [ArtworkReference] = []
        var updates: [MPMediaItemArtwork] = []
        await NowPlayingVideoArtwork.load(
            for: movie(),
            imageLoader: { reference in
                attempted.append(reference)
                return reference == .remote(self.poster) ? background : nil
            },
            logoLoader: { _ in
                XCTFail("A fallback poster must not load or receive another title")
                return self.preparedLogo(.red)
            },
            onUpdate: { updates.append($0) }
        )
        XCTAssertEqual(attempted, [.remote(backdrop), .remote(poster)])
        XCTAssertEqual(updates.count, 1)
        let result = try XCTUnwrap(updates.first?.image(at: background.size))
        XCTAssertEqual(try pixel(result, at: CGPoint(x: 160, y: 90)), [0, 0, 255])
    }

    func testSameURLInBackdropAndPosterSlotsRemainsUnbranded() async {
        var item = movie()
        item.backdropURL = poster
        var loads = 0
        await NowPlayingVideoArtwork.load(
            for: item,
            imageLoader: { _ in
                loads += 1
                return self.image(.blue, size: CGSize(width: 320, height: 180))
            },
            logoLoader: { _ in XCTFail("Poster provenance wins over its backdrop alias"); return nil },
            onUpdate: { _ in }
        )
        XCTAssertEqual(loads, 1)
    }

    func testPortraitBackdropAndKnownTitledArtDoNotReceiveLogos() async {
        for (size, suppressesLogo) in [(CGSize(width: 120, height: 180), false),
                                       (CGSize(width: 320, height: 180), true)] {
            await NowPlayingVideoArtwork.load(
                for: movie(), suppressesLogo: suppressesLogo,
                imageLoader: { _ in self.image(.blue, size: size) },
                logoLoader: { _ in XCTFail("Title-bearing art must remain untouched"); return nil },
                onUpdate: { _ in }
            )
        }
    }

    func testTextlessChoiceKeepsSpoilerSafeSeriesFallbacks() async {
        let clean = URL(string: "https://example.test/textless.jpg")!
        let spoiler = URL(string: "https://example.test/episode-still.jpg")!
        var item = MediaItem(id: "episode", title: "Episode", kind: .episode,
                             posterURL: spoiler, backdropURL: spoiler)
        item.fallbackArtworkURL = backdrop
        item.seriesPosterURL = poster
        XCTAssertEqual(NowPlayingVideoArtwork.references(for: item), [.remote(backdrop), .remote(poster)])
        var attempted: [ArtworkReference] = []
        await NowPlayingVideoArtwork.load(
            for: item, textlessBackdrop: clean,
            imageLoader: { reference in attempted.append(reference); return nil },
            logoLoader: { _ in XCTFail("No image loaded"); return nil },
            onUpdate: { _ in XCTFail("No image loaded") }
        )
        XCTAssertEqual(attempted, [.remote(clean), .remote(backdrop), .remote(poster)])
    }

    func testLogoKeepsAspectRatioAndSafeInsetsAcrossSystemShapes() {
        for canvas in [CGSize(width: 1200, height: 675), CGSize(width: 600, height: 600),
                       CGSize(width: 40, height: 40), CGSize(width: 32, height: 32),
                       CGSize(width: 100, height: 160)] {
            for logo in [CGSize(width: 800, height: 100), CGSize(width: 200, height: 100),
                         CGSize(width: 100, height: 100), CGSize(width: 100, height: 200)] {
                let rect = NowPlayingVideoArtwork.logoRect(imageSize: logo, canvas: canvas)
                XCTAssertEqual(rect.width / rect.height, logo.width / logo.height, accuracy: 0.001)
                XCTAssertEqual(rect.midX, canvas.width / 2, accuracy: 0.001)
                XCTAssertEqual(rect.midY, canvas.height / 2, accuracy: 0.001)
                XCTAssertGreaterThanOrEqual(rect.minX, canvas.width * 0.04 - 0.001)
                XCTAssertGreaterThanOrEqual(rect.minY, canvas.height * 0.08 - 0.001)
                XCTAssertTrue(
                    abs(rect.width - canvas.width * 0.92) < 0.001
                        || abs(rect.height - canvas.height * 0.84) < 0.001,
                    "Every shape fills a safe dimension instead of shrinking to an equal-area budget"
                )
            }
        }
    }

    func testCollapsedThumbnailsKeepLargeInkWhenDownsampledFromExpandedArtwork() throws {
        let background = image(.blue, size: CGSize(width: 640, height: 360))
        for (shape, widthShare, heightShare) in [
            (CGSize(width: 400, height: 100), 0.92, 0.23),
            (CGSize(width: 100, height: 100), 0.84, 0.84),
            (CGSize(width: 100, height: 200), 0.42, 0.84)
        ] {
            let logo = HeroUIKitLogo(
                image: image(.white, size: shape), isMonochrome: true,
                needsHalo: false, isDark: false, coverage: 1
            )
            let artwork = NowPlayingVideoArtwork.artwork(background: background, logo: logo)
            let expanded = try XCTUnwrap(artwork.image(at: CGSize(width: 320, height: 320)))
            for side in [32.0, 40.0, 60.0] {
                let size = CGSize(width: side, height: side)
                let direct = try XCTUnwrap(artwork.image(at: size))
                let format = UIGraphicsImageRendererFormat.preferred()
                format.scale = 1
                let downsampled = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                    expanded.draw(in: CGRect(origin: .zero, size: size))
                }
                for thumbnail in [direct, downsampled] {
                    let ink = try whiteInkBounds(thumbnail)
                    XCTAssertEqual(ink.width, side * widthShare, accuracy: 1.5)
                    XCTAssertEqual(ink.height, side * heightShare, accuracy: 1.5)
                    XCTAssertEqual(ink.midX, side / 2, accuracy: 1)
                    XCTAssertEqual(ink.midY, side / 2, accuracy: 1)
                }
            }
        }
    }

    func testWordmarkPreviewsAtCollapsedAndExpandedSizes() throws {
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        let background = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 360), format: format).image {
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
                UIColor(red: 0.07, green: 0.18, blue: 0.24, alpha: 1).cgColor,
                UIColor(red: 0.62, green: 0.39, blue: 0.22, alpha: 1).cgColor
            ] as CFArray, locations: [0, 1])!
            $0.cgContext.drawLinearGradient(
                gradient, start: .zero, end: CGPoint(x: 640, y: 360), options: []
            )
        }
        for words in [["ORBIT"], ["DEEP", "BLUE", "SKY"], ["UP", "IN", "THE", "AIR"]] {
            let artwork = NowPlayingVideoArtwork.artwork(background: background, logo: wordmark(words))
            let expanded = try XCTUnwrap(artwork.image(at: CGSize(width: 320, height: 320)))
            for side in [40.0, 160.0] {
                let size = CGSize(width: side, height: side)
                let preview = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                    expanded.draw(in: CGRect(origin: .zero, size: size))
                }
                let attachment = XCTAttachment(image: preview)
                attachment.name = "\(words.joined(separator: " ")) \(Int(side))px"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    func testColoredLogoKeepsItsInkAndBackdropUsesAspectFill() throws {
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        let background = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 180), format: format).image {
            UIColor.red.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
            UIColor.blue.setFill()
            $0.fill(CGRect(x: 70, y: 0, width: 180, height: 180))
        }
        let artwork = NowPlayingVideoArtwork.artwork(background: background, logo: preparedLogo(.green))
        let result = try XCTUnwrap(artwork.image(at: CGSize(width: 180, height: 180)))
        XCTAssertEqual(try pixel(result, at: CGPoint(x: 90, y: 90)), [0, 255, 0])
        XCTAssertEqual(try pixel(result, at: CGPoint(x: 1, y: 1))[0], 0,
                       "Crop the red side bands instead of squashing a wide backdrop")
    }

    private func movie() -> MediaItem {
        MediaItem(id: "movie", title: "Movie", kind: .movie, posterURL: poster, backdropURL: backdrop)
    }

    private func image(_ color: UIColor, size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image {
            color.setFill()
            $0.fill(CGRect(origin: .zero, size: size))
        }
    }

    private func preparedLogo(_ color: UIColor, monochrome: Bool = false) -> HeroUIKitLogo {
        HeroUIKitLogo(
            image: image(color, size: CGSize(width: 160, height: 40)),
            isMonochrome: monochrome, needsHalo: true, isDark: monochrome, coverage: 0.32
        )
    }

    private func wordmark(_ words: [String]) -> HeroUIKitLogo {
        let lines = words.map { word in
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: word, attributes: [
                .font: UIFont.systemFont(ofSize: 80, weight: .black), .foregroundColor: UIColor.white
            ]))
            return (line, CTLineGetBoundsWithOptions(line, .useGlyphPathBounds))
        }
        let gap: CGFloat = 8
        let size = CGSize(
            width: ceil(lines.map { $0.1.width }.max()!),
            height: ceil(lines.reduce(0) { $0 + $1.1.height } + gap * CGFloat(lines.count - 1))
        )
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            var y: CGFloat = 0
            for (line, bounds) in lines {
                context.cgContext.saveGState()
                context.cgContext.translateBy(x: (size.width - bounds.width) / 2 - bounds.minX, y: y + bounds.maxY)
                context.cgContext.scaleBy(x: 1, y: -1)
                context.cgContext.textMatrix = .identity
                context.cgContext.textPosition = .zero
                CTLineDraw(line, context.cgContext)
                context.cgContext.restoreGState()
                y += bounds.height + gap
            }
        }
        return HeroUIKitLogo(image: image, isMonochrome: true, needsHalo: false, isDark: false, coverage: 0.32)
    }

    private func whiteInkBounds(_ image: UIImage) throws -> CGRect {
        let cg = try XCTUnwrap(image.cgImage)
        let width = cg.width
        let height = cg.height
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &rgba, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        // These fixtures are solid white ink over blue. Integrate the red/green
        // coverage instead of discarding partially covered pixels at an arbitrary
        // cutoff: a 40px resample legitimately has 43%-covered boundary pixels.
        var columns = [Double](repeating: 0, count: width)
        var rows = [Double](repeating: 0, count: height)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let coverage = Double(min(rgba[offset], rgba[offset + 1])) / 255
                columns[x] = max(columns[x], coverage)
                rows[y] = max(rows[y], coverage)
            }
        }
        let inkWidth = columns.reduce(0, +)
        let inkHeight = rows.reduce(0, +)
        _ = try XCTUnwrap(inkWidth > 0 && inkHeight > 0 ? true : nil,
                          "The thumbnail must contain visible logo ink")
        let centerX = columns.enumerated().reduce(0) { $0 + (Double($1.offset) + 0.5) * $1.element } / inkWidth
        let centerY = rows.enumerated().reduce(0) { $0 + (Double($1.offset) + 0.5) * $1.element } / inkHeight
        return CGRect(x: centerX - inkWidth / 2, y: centerY - inkHeight / 2, width: inkWidth, height: inkHeight)
    }

    private func pixel(_ image: UIImage, at point: CGPoint) throws -> [UInt8] {
        var rgba = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(
            data: &rgba, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.interpolationQuality = .none
        context.translateBy(x: -point.x, y: -point.y)
        context.draw(try XCTUnwrap(image.cgImage), in: CGRect(origin: .zero, size: image.size))
        return Array(rgba.prefix(3))
    }
}
#endif
