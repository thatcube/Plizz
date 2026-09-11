#if os(iOS)
import CoreUI
import Observation
import SwiftUI
import UIKit
import XCTest

@MainActor @Observable
private final class LivePlayLabel {
    var episode = ""
    var progress: Double?
}

private struct LiveActionRow<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View { content() }
}

@MainActor
final class TouchHeroActionRowTests: XCTestCase {
    private func size(of view: some View, width: CGFloat = 2_000) -> CGSize {
        UIHostingController(rootView: view
            .environment(\.dynamicTypeSize, .large)
        ).sizeThatFits(in: CGSize(width: width, height: 2_000))
    }

    private func play(
        episode: String?,
        progress: Double? = nil,
        wraps: Bool = false,
        minimumWidth: CGFloat? = nil
    ) -> some View {
        Button {} label: {
            PlayResumeButtonLabel(
                title: "Play",
                progress: progress,
                remainingText: progress == nil ? nil : "43m",
                seasonEpisodeText: episode,
                onLight: true,
                spacing: 10,
                capsuleWidth: 60,
                wrapsText: wraps
            )
        }
        .buttonStyle(TouchHeroActionButtonStyle(kind: .primary, minimumWidth: minimumWidth))
    }

    private func row(
        episode: String?, extras: Int,
        progress: Double? = nil, minimumWidth: CGFloat? = nil
    ) -> some View {
        HeroActionRow {
            play(episode: episode, progress: progress, minimumWidth: minimumWidth)
            ForEach(0..<extras, id: \.self) { _ in
                Button {} label: { Image(systemName: "ellipsis") }
                    .buttonStyle(TouchHeroActionButtonStyle(kind: .secondary, circular: true))
            }
        }
        .controlSize(.large)
    }

    private func adaptiveRow(
        episode: String?, progress: Double?, minimumWidth: CGFloat? = nil
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            ForEach((1...4).reversed(), id: \.self) { count in
                self.row(episode: episode, extras: count, progress: progress, minimumWidth: minimumWidth)
            }
            HeroActionRow(stacksVertically: true) {
                play(episode: episode, progress: progress, wraps: true)
            }
        }
    }

    func testProminentPlayWidensThePillWithoutChangingItsHeight() {
        let original = size(of: play(episode: nil))
        let prominent = size(of: play(episode: nil, minimumWidth: 180))
        XCTAssertEqual(prominent.width, 180, accuracy: 0.5)
        XCTAssertGreaterThan(prominent.width, original.width)
        XCTAssertEqual(prominent.height, original.height, accuracy: 0.5)
        let longOriginal = size(of: play(episode: "S20, E100", progress: 0.4))
        let longProminent = size(of: play(episode: "S20, E100", progress: 0.4, minimumWidth: 180))
        XCTAssertEqual(longProminent.width, max(180, longOriginal.width), accuracy: 0.5)
    }

    func testProminentPlayFoldsExtrasInsteadOfCompressingItsPill() {
        for (width, extras) in [(CGFloat(276), 1), (331, 2), (386, 3)] {
            let expected = size(of: row(episode: nil, extras: extras, minimumWidth: 180))
            let actual = size(of: adaptiveRow(episode: nil, progress: nil, minimumWidth: 180), width: width)
            XCTAssertEqual(actual.width, expected.width, accuracy: 0.5)
            XCTAssertEqual(actual.height, expected.height, accuracy: 0.5)
            XCTAssertLessThanOrEqual(actual.width, width)
        }
    }

    func testProminentPlayKeepsTheAccessibleWrappingFallback() {
        let actual = size(of: adaptiveRow(
            episode: "S20, E100", progress: 0.4, minimumWidth: 180
        ), width: 145)
        let expected = size(of: HeroActionRow(stacksVertically: true) {
            self.play(episode: "S20, E100", progress: 0.4, wraps: true)
        }, width: 145)
        XCTAssertEqual(actual.width, expected.width, accuracy: 0.5)
        XCTAssertEqual(actual.height, expected.height, accuracy: 0.5)
        XCTAssertLessThanOrEqual(actual.width, 145)
    }

    func testInlinePlayLabelNeverReportsATruncatedWidth() {
        for episode in ["S1, E8", "S20, E100"] {
            for progress in [nil, 0.4] as [Double?] {
                let label = PlayResumeButtonLabel(
                    title: "Play", progress: progress,
                    remainingText: progress == nil ? nil : "43m",
                    seasonEpisodeText: episode, onLight: true,
                    spacing: 10, capsuleWidth: 60
                ).font(.headline.weight(.semibold))
                let natural = size(of: label)
                let constrained = size(of: label, width: natural.width - 35)
                XCTAssertEqual(constrained.width, natural.width, accuracy: 0.5, episode)
                XCTAssertEqual(constrained.height, natural.height, accuracy: 0.5, episode)
            }
        }
    }

    func testActualStyledRowPreservesPlayWidthWithNeighboringButtons() {
        for episode in ["S1, E8", "S20, E100"] {
            for progress in [nil, 0.4] as [Double?] {
                let playSize = size(of: play(episode: episode, progress: progress))
                for extras in 1...4 {
                    let expectedWidth = playSize.width + CGFloat(extras) * 60
                    for width in [CGFloat(276), 331, 386] {
                        let actual = size(of: row(episode: episode, extras: extras, progress: progress), width: width)
                        XCTAssertEqual(actual.width, expectedWidth, accuracy: 1, "\(episode), \(extras) extras")
                    }
                }
            }
        }
    }

    func testOverflowShedsAnExtraBeforeShorteningThePlayLabel() {
        let episode = "S1, E8"
        let smaller = size(of: row(episode: episode, extras: 3))
        let larger = size(of: row(episode: episode, extras: 4))
        let width = (smaller.width + larger.width) / 2
        let candidate = ViewThatFits(in: .horizontal) {
            row(episode: episode, extras: 4)
            row(episode: episode, extras: 3)
        }
        let actual = size(of: candidate, width: width)
        XCTAssertEqual(actual.width, smaller.width, accuracy: 0.5)
        XCTAssertEqual(actual.height, smaller.height, accuracy: 0.5)
    }

    func testStyledVerticalFallbackStillWrapsInsteadOfOverflowing() {
        let candidate = HeroActionRow(stacksVertically: true) {
            play(episode: "S20, E100", progress: 0.4, wraps: true)
        }
        let wide = size(of: candidate)
        let narrow = size(of: candidate, width: 145)
        XCTAssertLessThanOrEqual(narrow.width, 145)
        XCTAssertGreaterThan(narrow.height, wide.height)
    }

    func testLateEpisodeAndResumeChangesReconsiderTheFittingCandidate() async {
        let state = LivePlayLabel()
        let host = UIHostingController(rootView: LiveActionRow {
            self.adaptiveRow(episode: state.episode, progress: state.progress)
                .environment(\.dynamicTypeSize, .large)
        })
        let proposal = CGSize(width: 331, height: 2_000)
        _ = host.sizeThatFits(in: proposal)
        for (episode, progress) in [("S1, E8", nil), ("S20, E100", 0.4)] as [(String, Double?)] {
            state.episode = episode
            state.progress = progress
            await Task.yield()
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            let actual = host.sizeThatFits(in: proposal)
            let fresh = size(of: adaptiveRow(episode: episode, progress: progress), width: proposal.width)
            XCTAssertEqual(actual.width, fresh.width, accuracy: 0.5)
            XCTAssertEqual(actual.height, fresh.height, accuracy: 0.5)
            XCTAssertLessThanOrEqual(actual.width, proposal.width)
        }
    }

    func testRendersStyledRowsAcrossPhoneWidthsAndTextSizes() throws {
        for width in [CGFloat(276), 331, 386] {
            for textSize in [DynamicTypeSize.large, .xxxLarge, .accessibility3] {
                let content = adaptiveRow(episode: "S20, E100", progress: nil, minimumWidth: 180)
                    .environment(\.dynamicTypeSize, textSize)
                    .environment(\.themePalette, .dark)
                    .environment(\.colorScheme, .dark)
                    .frame(width: width)
                    .padding(12)
                    .background(.black)
                let renderer = ImageRenderer(content: content)
                renderer.scale = 3
                let image = try XCTUnwrap(renderer.uiImage)
                XCTAssertEqual(image.size.width, width + 24, accuracy: 0.5)
                let attachment = XCTAttachment(image: image)
                attachment.name = "styled-play-\(Int(width))-\(textSize)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }
}
#endif
