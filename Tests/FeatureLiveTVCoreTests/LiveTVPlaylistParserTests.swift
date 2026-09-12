#if DEBUG
import Foundation
import XCTest
@testable import FeatureLiveTVCore

final class LiveTVPlaylistParserTests: XCTestCase {
    func testDiscoversBothHeaderConventionsAndPreservesCountryAndLanguages() throws {
        let input = """
        #EXTM3U url-tvg="../guide.xml.gz, https://other.test/extra.xml" x-tvg-url="../guide.xml.gz"
        #EXTINF:-1 tvg-id="station" tvg-language="English;Spanish" tvg-country="US,CA",Station
        https://example.test/live.m3u8
        """
        let parsed = try LiveTVPlaylistParser(baseURL: URL(string: "https://example.test/lists/catalog.m3u")).parse(input)
        XCTAssertEqual(parsed.declaredGuideURLs.map(\.absoluteString), [
            "https://example.test/guide.xml.gz", "https://other.test/extra.xml"
        ])
        XCTAssertEqual(parsed.channels.first?.languages, ["English", "Spanish"])
        XCTAssertEqual(parsed.channels.first?.countries, ["US", "CA"])
    }

    func testGuideDiscoveryOriginPolicyRejectsCrossOriginCredentialsAndDowngrades() throws {
        let origin = try XCTUnwrap(URL(string: "https://example.test/source"))
        for address in [
            "https://evil.test/guide", "http://example.test/guide", "https://example.test:8443/guide",
            "https://name:password@example.test/guide", "https://example.test.evil.test/guide"
        ] {
            XCTAssertFalse(LiveTVSourceOriginPolicy.permits(try XCTUnwrap(URL(string: address)), from: origin))
        }
        XCTAssertTrue(LiveTVSourceOriginPolicy.permits(try XCTUnwrap(URL(string: "https://example.test/guide")), from: origin))
        XCTAssertTrue(LiveTVSourceOriginPolicy.permits(
            origin, from: try XCTUnwrap(URL(string: "http://example.test/source"))
        ))
    }

    func testRejectsHLSMediaSegmentsInsteadOfImportingThemAsChannels() {
        let input = """
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXTINF:6,First segment
        https://example.com/segment-1.ts
        #EXTINF:6,Second segment
        https://example.com/segment-2.ts
        """
        XCTAssertThrowsError(try LiveTVPlaylistParser().parse(input)) {
            XCTAssertEqual($0 as? LiveTVSourceImportError, .streamManifest)
        }
    }

    func testRejectsHLSMasterAsAChannelList() {
        let input = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=800000
        https://example.com/media.m3u8
        """
        XCTAssertThrowsError(try LiveTVPlaylistParser().parse(input)) {
            XCTAssertEqual($0 as? LiveTVSourceImportError, .streamManifest)
        }
    }

    func testM3U8ChannelListStillAcceptsHLSChannelURLs() throws {
        let input = """
        #EXTM3U
        #EXTINF:-1,News
        https://example.com/live.m3u8
        """
        let parser = LiveTVPlaylistParser(baseURL: URL(string: "https://example.com/channels.m3u8"))
        XCTAssertEqual(try parser.parse(input).channels.map(\.name), ["News"])
    }

    func testParsesAttributesCommasRelativeURLsAndScopedHeaders() throws {
        let input = """
        #EXTM3U
        #EXTINF:-1 tvg-id="news.id" tvg-chno="42" tvg-name="News Name" tvg-logo="/logo.png" group-title="News, Local",News, City
        #EXTVLCOPT:http-referrer=https://example.com/watch
        #EXTVLCOPT:http-user-agent=Test Player/1.0
        stream/one.m3u8
        #EXTINF:-1 group-title="Sports",Next
        https://media.example/next.m3u8
        """
        let parser = LiveTVPlaylistParser(
            baseURL: URL(string: "https://example.com/lists/us.m3u")!
        )
        let result = try parser.parse(input)

        XCTAssertEqual(result.entryCount, 2)
        XCTAssertEqual(result.skippedEntryCount, 0)
        XCTAssertEqual(result.channels.map(\.number), [42, 2])
        XCTAssertEqual(result.channels[0].name, "News, City")
        XCTAssertEqual(result.channels[0].category, "News, Local")
        XCTAssertEqual(
            result.channels[0].streamURL?.absoluteString,
            "https://example.com/lists/stream/one.m3u8"
        )
        XCTAssertEqual(
            result.channels[0].logoURL?.absoluteString,
            "https://example.com/logo.png"
        )
        XCTAssertEqual(result.channels[0].guideID, "news.id")
        XCTAssertEqual(result.channels[0].guideName, "News Name")
        XCTAssertEqual(result.channels[0].httpHeaders["Referer"], "https://example.com/watch")
        XCTAssertEqual(result.channels[0].httpHeaders["User-Agent"], "Test Player/1.0")
        XCTAssertTrue(result.channels[1].httpHeaders.isEmpty)
    }

    func testStableUniqueIDsUseIdentityAndURLNotPlaylistOrder() throws {
        let first = """
        #EXTM3U
        #EXTINF:-1 tvg-id="same",One
        https://example.com/a.m3u8
        #EXTINF:-1 tvg-id="same",One
        https://example.com/b.m3u8
        """
        let reversed = """
        #EXTM3U
        #EXTINF:-1 tvg-id="same",One
        https://example.com/b.m3u8
        #EXTINF:-1 tvg-id="same",One
        https://example.com/a.m3u8
        """
        let parser = LiveTVPlaylistParser()
        let original = try parser.parse(first).channels
        let reordered = try parser.parse(reversed).channels

        XCTAssertEqual(Set(original.map(\.id)).count, 2)
        XCTAssertEqual(Set(original.map(\.id)), Set(reordered.map(\.id)))
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: original.map {
                ($0.streamURL!.absoluteString, $0.id)
            }),
            Dictionary(uniqueKeysWithValues: reordered.map {
                ($0.streamURL!.absoluteString, $0.id)
            })
        )
    }

    func testBOMAndSingleQuotedMetadataDoNotLoseTheFirstAttribute() throws {
        let input = "\u{FEFF}" + """
        #EXTM3U
        #EXTINF:-1 tvg-id='station' group-title='News, Local',Station
        https://example.com/live.m3u8
        """
        let channel = try XCTUnwrap(LiveTVPlaylistParser().parse(input).channels.first)
        XCTAssertEqual(channel.guideID, "station")
        XCTAssertEqual(channel.category, "News, Local")
    }
    func testExactDuplicateEntryIsExplicitlySkipped() throws {
        let input = """
        #EXTM3U
        #EXTINF:-1 tvg-id="same",One
        https://example.com/a.m3u8
        #EXTINF:-1 tvg-id="same",One
        https://example.com/a.m3u8
        """
        let result = try LiveTVPlaylistParser().parse(input)
        XCTAssertEqual(result.entryCount, 2)
        XCTAssertEqual(result.channels.count, 1)
        XCTAssertEqual(result.skippedEntryCount, 1)
    }

    func testKnownTransparentWhiteLogosKeepTheirContrastHint() throws {
        let sample = try XCTUnwrap(LiveTVPrototypeCatalog.channels.first { $0.logoNeedsDarkBackground })
        let logo = try XCTUnwrap(sample.logoURL)
        let input = """
        #EXTM3U
        #EXTINF:-1 tvg-logo="\(logo.absoluteString)",Station
        https://example.com/live.m3u8
        """
        let imported = try XCTUnwrap(LiveTVPlaylistParser().parse(input).channels.first)
        XCTAssertTrue(imported.logoNeedsDarkBackground)
    }

    func testUsesPrimaryCategoryAndPreservesAllGroupLabels() throws {
        let input = """
        #EXTM3U
        #EXTINF:-1 group-title="Animation; Kids;Religious",Kids Network
        https://example.com/kids.m3u8
        """
        let channel = try LiveTVPlaylistParser().parse(input).channels[0]
        XCTAssertEqual(channel.category, "Animation")
        XCTAssertEqual(channel.tagline, "Animation • Kids • Religious")
    }

    func testMalformedAndUnsafeEntriesAreCountedInsteadOfTrapping() throws {
        let input = """
        #EXTM3U
        #EXTINF:-1,Missing URL
        #EXTINF:-1,Bad Scheme
        file:///private/movie.ts
        #EXTINF:-1,Credentials
        https://user:secret@example.com/live.m3u8
        #EXTINF:-1,Good
        https://example.com/live.m3u8
        #EXTINF:-1,Trailing
        """
        let result = try LiveTVPlaylistParser().parse(input)
        XCTAssertEqual(result.entryCount, 5)
        XCTAssertEqual(result.channels.map(\.name), ["Good"])
        XCTAssertEqual(result.skippedEntryCount, 4)
    }

    func testRejectsNonM3UAndOversizedInput() {
        XCTAssertThrowsError(try LiveTVPlaylistParser().parse("not a playlist")) {
            XCTAssertEqual($0 as? LiveTVSourceImportError, .invalidPlaylist)
        }
        let data = Data(
            repeating: 65,
            count: LiveTVPlaylistParser.maximumBytes + 1
        )
        XCTAssertThrowsError(try LiveTVPlaylistParser().parse(data)) {
            XCTAssertEqual($0 as? LiveTVSourceImportError, .responseTooLarge)
        }
    }

    func testRejectsEntryOverflow() {
        var input = "#EXTM3U\n"
        for index in 0...LiveTVPlaylistParser.maximumEntries {
            input += "#EXTINF:-1,Channel \(index)\nhttps://example.com/\(index).m3u8\n"
        }
        XCTAssertThrowsError(try LiveTVPlaylistParser().parse(input)) {
            XCTAssertEqual($0 as? LiveTVSourceImportError, .responseTooLarge)
        }
    }
}
#endif
