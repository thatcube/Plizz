#if DEBUG
import Foundation
import XCTest
import zlib
@testable import FeatureLiveTVCore

final class LiveTVXMLTVParserTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_767_225_600)

    func testMissingEndUsesOnlyBoundedSameChannelSuccessorAndRetainsProvenance() throws {
        let xml = """
        <tv><channel id="g"><display-name>Station</display-name></channel>
        <programme channel="g" start="20260101000000 +0000"><title>Inferred</title><desc>Details</desc><category>Science</category><language>en</language><rating><value>PG</value></rating></programme>
        <programme channel="other" start="20260101001500 +0000" stop="20260101003000 +0000"><title>Other channel</title></programme>
        <programme channel="g" start="20260101010000 +0000" stop="20260101020000 +0000"><title>Next</title></programme>
        <programme channel="g" start="20260101030000 +0000"><title>Unbounded final</title></programme>
        </tv>
        """
        let result = try LiveTVXMLTVParser().parseXML(
            data: Data(xml.utf8), channels: [makeChannel(id: "app", name: "Station", guideID: "g")], now: now
        )
        XCTAssertEqual(result.programs.map(\.title), ["Inferred", "Next"])
        XCTAssertEqual(result.programs[0].end, result.programs[1].start)
        XCTAssertEqual(result.programs[0].details?.endWasInferred, true)
        XCTAssertEqual(result.programs[0].details?.description, "Details")
        XCTAssertEqual(result.programs[0].details?.rating, "PG")
        XCTAssertEqual(result.programs[0].details?.categories, ["Science"])
        XCTAssertEqual(result.programs[0].details?.languages, ["en"])
    }

    func testMissingManualGuideStationNeverFallsBackToAnExactOrNameMatch() throws {
        let xml = Data("<tv><channel id=\"g\"><display-name>Station</display-name></channel></tv>".utf8)
        let result = try LiveTVXMLTVParser().parseXML(
            data: xml, channels: [makeChannel(id: "app", name: "Station", guideID: "g")], now: now,
            overrides: ["app": "removed-station"]
        )
        XCTAssertTrue(result.matches.isEmpty)
    }


    func testParsesChunksEntitiesOffsetsAndMapsToApplicationChannelID() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tv>
          <channel id="guide.one"><display-name>News HD</display-name></channel>
          <programme channel="guide.one" start="20251231210000 -0500" stop="20251231223000 -0500">
            <title>Tom &amp; Jerry</title>
            <sub-title>Part <![CDATA[One]]></sub-title>
          </programme>
        </tv>
        """
        let channel = makeChannel(id: "app-channel", name: "News HD", guideID: "guide.one")
        let result = try LiveTVXMLTVParser().parseXML(
            data: Data(xml.utf8),
            channels: [channel],
            now: now
        )

        XCTAssertEqual(result.guideChannelCount, 1)
        XCTAssertEqual(result.matchedChannelCount, 1)
        XCTAssertEqual(result.programCount, 1)
        XCTAssertEqual(result.programs[0].channelID, "app-channel")
        XCTAssertEqual(result.programs[0].title, "Tom & Jerry")
        XCTAssertEqual(result.programs[0].subtitle, "Part One")
        XCTAssertEqual(result.programs[0].start, date("20260101020000 +0000"))
        XCTAssertEqual(result.programs[0].end, date("20260101033000 +0000"))
        XCTAssertEqual(result.coverageStart, result.programs[0].start)
        XCTAssertEqual(result.coverageEnd, result.programs[0].end)
    }

    func testPreservesGuideGapsAndDoesNotFabricateMissingStops() throws {
        let xml = """
        <tv>
          <channel id="gap"><display-name>Gap TV</display-name></channel>
          <programme channel="gap" start="20251231230000 +0000" stop="20260101000000 +0000"><title>First</title></programme>
          <programme channel="gap" start="20260101010000 +0000" stop="20260101020000 +0000"><title>Second</title></programme>
          <programme channel="gap" start="20260101020000 +0000"><title>No Stop</title></programme>
          <programme channel="gap" start="20260101030000 +0000" stop="20260101020000 +0000"><title>Backwards</title></programme>
        </tv>
        """
        let result = try LiveTVXMLTVParser().parseXML(
            data: Data(xml.utf8),
            channels: [makeChannel(id: "gap-app", name: "Gap TV", guideID: "gap")],
            now: now
        )
        XCTAssertEqual(result.programs.map(\.title), ["First", "Second"])
        XCTAssertEqual(
            result.programs[1].start.timeIntervalSince(result.programs[0].end),
            3_600
        )
    }

    func testNoMatchingOrCurrentProgramsReportsFeedCoverageHonestly() throws {
        let xml = """
        <tv>
          <channel id="old"><display-name>Old TV</display-name></channel>
          <programme channel="old" start="20200101000000 +0000" stop="20200101010000 +0000"><title>Old</title></programme>
        </tv>
        """
        let result = try LiveTVXMLTVParser().parseXML(
            data: Data(xml.utf8),
            channels: [makeChannel(id: "different", name: "Different", guideID: nil)],
            now: now
        )
        XCTAssertTrue(result.programs.isEmpty)
        XCTAssertEqual(result.matchedChannelCount, 0)
        XCTAssertEqual(result.guideChannelCount, 1)
        XCTAssertEqual(result.programCount, 0)
        XCTAssertEqual(result.coverageStart, date("20200101000000 +0000"))
        XCTAssertEqual(result.coverageEnd, date("20200101010000 +0000"))
    }

    func testMatchedChannelIsReportedEvenWhenItsProgramsAreOutsideTheWindow() throws {
        let xml = """
        <tv>
          <channel id="old"><display-name>Old TV</display-name></channel>
          <programme channel="old" start="20200101000000 +0000" stop="20200101010000 +0000"><title>Old</title></programme>
        </tv>
        """
        let result = try LiveTVXMLTVParser().parseXML(
            data: Data(xml.utf8),
            channels: [makeChannel(id: "old-app", name: "Old TV", guideID: "old")],
            now: now
        )
        XCTAssertEqual(result.matchedChannelCount, 1)
        XCTAssertEqual(result.programCount, 0)
    }

    func testExactIdentitySharesProgramsAcrossStreamVariants() throws {
        let xml = """
        <tv>
          <channel id="station"><display-name>Station</display-name></channel>
          <programme channel="station" start="20260101000000 +0000" stop="20260101010000 +0000"><title>Listing</title></programme>
        </tv>
        """
        let result = try LiveTVXMLTVParser().parseXML(
            data: Data(xml.utf8),
            channels: [
                makeChannel(id: "sd", name: "Station SD", guideID: "station"),
                makeChannel(id: "hd", name: "Station HD", guideID: "station")
            ],
            now: now
        )
        XCTAssertEqual(result.matchedChannelCount, 2)
        XCTAssertEqual(Set(result.programs.map(\.channelID)), ["sd", "hd"])
        XCTAssertEqual(Set(result.programs.map(\.id)).count, 2)
    }

    func testProviderIsForwardedToGuideMatcher() throws {
        let xml = """
        <tv>
          <channel id="station"><display-name>Station</display-name></channel>
          <programme channel="station" start="20260101000000 +0000" stop="20260101010000 +0000"><title>Listing</title></programme>
        </tv>
        """
        let samsungChannel = makeChannel(
            id: "samsung",
            name: "Station",
            guideID: "station",
            streamURL: URL(string: "https://samsung-us.amagi.tv/playlist.m3u8")
        )
        let matching = try LiveTVXMLTVParser(provider: .samsung).parseXML(
            data: Data(xml.utf8),
            channels: [samsungChannel],
            now: now
        )
        let mismatching = try LiveTVXMLTVParser(provider: .plex).parseXML(
            data: Data(xml.utf8),
            channels: [samsungChannel],
            now: now
        )
        XCTAssertEqual(matching.programs.map(\.channelID), ["samsung"])
        XCTAssertEqual(matching.matches["samsung"]?.guideChannelID, "station")
        XCTAssertTrue(mismatching.programs.isEmpty)
        XCTAssertTrue(mismatching.matches.isEmpty)
    }

    func testInterleavedChannelsAndProgramsMatchAcrossWholeDocument() throws {
        let xml = """
        <tv>
          <programme channel="late" start="20260101000000 +0000" stop="20260101010000 +0000"><title>Before Metadata</title></programme>
          <channel id="late"><display-name>Station</display-name></channel>
          <programme channel="late" start="20260101010000 +0000" stop="20260101020000 +0000"><title>After Metadata</title></programme>
        </tv>
        """
        let result = try LiveTVXMLTVParser().parseXML(
            data: Data(xml.utf8),
            channels: [makeChannel(id: "station-app", name: "Station", guideID: "late")],
            now: now
        )
        XCTAssertEqual(result.programs.map(\.title), ["Before Metadata", "After Metadata"])
        XCTAssertEqual(
            result.matches["station-app"],
            LiveTVGuideMatch(guideChannelID: "late", method: .exactID)
        )
    }

    func testStandardExternalDOCTYPEParsesAsPlainAndGzipWithoutLoadingDTD() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE tv SYSTEM "xmltv.dtd">
        <tv>
          <channel id="guide"><display-name>Guide</display-name></channel>
          <programme channel="guide" start="20260101000000 +0000" stop="20260101010000 +0000"><title>Listing</title></programme>
        </tv>
        """
        let channel = makeChannel(id: "app", name: "Guide", guideID: "guide")
        let plain = try LiveTVXMLTVParser().parseXML(
            data: Data(xml.utf8),
            channels: [channel],
            now: now
        )
        let compressed = try LiveTVXMLTVParser().parse(
            gzipData: gzip(Data(xml.utf8)),
            channels: [channel],
            now: now
        )
        XCTAssertEqual(plain.programs.map(\.id), compressed.programs.map(\.id))
        XCTAssertEqual(plain.programs.map(\.title), ["Listing"])
        XCTAssertEqual(plain.matches["app"]?.guideChannelID, "guide")
    }

    func testExternalDTDResourceIsNeverRequired() throws {
        let xml = """
        <?xml version="1.0"?>
        <!DOCTYPE tv SYSTEM "https://example.invalid/unavailable.dtd">
        <tv><channel id="guide"><display-name>Guide</display-name></channel></tv>
        """
        let result = try LiveTVXMLTVParser().parseXML(
            data: Data(xml.utf8),
            channels: [],
            now: now
        )
        XCTAssertEqual(result.guideChannelCount, 1)
    }

    func testRejectsEntityDeclarationsInUTF8AndUTF16() {
        let utf8 = """
        <?xml version="1.0"?>
        <!DOCTYPE tv [<!ENTITY xxe SYSTEM "file:///etc/passwd">]>
        <tv><channel id="x"><display-name>&xxe;</display-name></channel></tv>
        """
        XCTAssertThrowsError(
            try LiveTVXMLTVParser().parseXML(
                data: Data(utf8.utf8),
                channels: [],
                now: now
            )
        ) {
            XCTAssertEqual($0 as? LiveTVSourceImportError, .invalidGuide)
        }
        let utf16 = """
        <?xml version="1.0" encoding="UTF-16"?>
        <!DOCTYPE tv [<!ENTITY payload "expanded">]>
        <tv><channel id="x"><display-name>&payload;</display-name></channel></tv>
        """
        var utf16Data = Data([0xff, 0xfe])
        utf16Data.append(utf16.data(using: .utf16LittleEndian)!)
        XCTAssertThrowsError(
            try LiveTVXMLTVParser().parseXML(
                data: utf16Data,
                channels: [],
                now: now
            )
        ) {
            XCTAssertEqual($0 as? LiveTVSourceImportError, .invalidGuide)
        }
    }

    func testRejectsUnusedAndChunkSplitEntityDeclarationsAcrossEncodings() throws {
        let body = """
        <!DOCTYPE tv [<!ENTITY unused SYSTEM "https://example.invalid/entity">]>
        <tv><channel id="x"><display-name>Station</display-name></channel></tv>
        """
        for padding in [0] + Array(4_040...4_055) + Array(65_480...65_495) {
            let xml = "<?xml version=\"1.0\"?><!----><!--\(String(repeating: "x", count: padding))-->\(body)"
            let data = Data(xml.utf8)
            XCTAssertThrowsError(try LiveTVXMLTVParser().parseXML(data: data, channels: [], now: now))
            XCTAssertThrowsError(try LiveTVXMLTVParser().parse(gzipData: gzip(data), channels: [], now: now))
        }
        for encoding in [String.Encoding.utf16BigEndian, .utf32LittleEndian, .utf32BigEndian] {
            let label = encoding == .utf16BigEndian ? "UTF-16BE" :
                (encoding == .utf32LittleEndian ? "UTF-32LE" : "UTF-32BE")
            let data = try XCTUnwrap(("<?xml version=\"1.0\" encoding=\"\(label)\"?>\(body)").data(using: encoding))
            XCTAssertThrowsError(try LiveTVXMLTVParser().parseXML(data: data, channels: [], now: now))
        }
    }

    func testEntityDeclarationCannotBeIntroducedAfterRootStarts() {
        let xml = "<tv><!--\(String(repeating: "x", count: 65_536))-->"
            + "<!ENTITY late \"expanded\"><channel id=\"x\"><display-name>&late;</display-name></channel></tv>"
        XCTAssertThrowsError(try LiveTVXMLTVParser().parseXML(data: Data(xml.utf8), channels: [], now: now)) {
            XCTAssertEqual($0 as? LiveTVSourceImportError, .invalidGuide)
        }
    }

    func testRejectsConflictingDuplicateMetadataAndNestedRoot() throws {
        let identical = """
        <tv>
          <channel id="same"><display-name>Same</display-name></channel>
          <channel id="same"><display-name>Same</display-name></channel>
        </tv>
        """
        let result = try LiveTVXMLTVParser().parseXML(
            data: Data(identical.utf8),
            channels: [],
            now: now
        )
        XCTAssertEqual(result.guideChannelCount, 1)

        let conflicting = """
        <tv>
          <channel id="same"><display-name>First</display-name></channel>
          <channel id="same"><display-name>Second</display-name></channel>
        </tv>
        """
        XCTAssertThrowsError(
            try LiveTVXMLTVParser().parseXML(
                data: Data(conflicting.utf8),
                channels: [],
                now: now
            )
        ) {
            XCTAssertEqual($0 as? LiveTVSourceImportError, .invalidGuide)
        }
        XCTAssertThrowsError(
            try LiveTVXMLTVParser().parseXML(
                data: Data("<tv><tv/></tv>".utf8),
                channels: [],
                now: now
            )
        ) {
            XCTAssertEqual($0 as? LiveTVSourceImportError, .invalidGuide)
        }
    }

    func testRejectsMalformedXML() {
        XCTAssertThrowsError(
            try LiveTVXMLTVParser().parseXML(
                data: Data("<tv><channel>".utf8),
                channels: [],
                now: now
            )
        )
    }

    func testGzipCorruptionAndExpansionLimitAreRejected() throws {
        XCTAssertThrowsError(
            try LiveTVXMLTVParser().parse(
                gzipData: Data(count: LiveTVXMLTVParser.maximumCompressedBytes + 1),
                channels: [],
                now: now
            )
        ) {
            XCTAssertEqual($0 as? LiveTVSourceImportError, .guideTooLarge)
        }
        XCTAssertThrowsError(
            try LiveTVXMLTVParser().parse(
                gzipData: Data([0x1f, 0x8b, 0x00, 0x01]),
                channels: [],
                now: now
            )
        ) {
            XCTAssertEqual($0 as? LiveTVSourceImportError, .invalidGuide)
        }

        let oversizedXML = "<tv><!--" + String(repeating: "x", count: 1_024) + "--></tv>"
        let compressed = try gzip(Data(oversizedXML.utf8))
        XCTAssertThrowsError(
            try LiveTVXMLTVParser(maximumExpandedBytes: 128).parse(
                gzipData: compressed,
                channels: [],
                now: now
            )
        ) {
            XCTAssertEqual($0 as? LiveTVSourceImportError, .guideTooLarge)
        }
    }

    func testTextLimitIsEnforcedForMatchedAndUnmatchedListings() {
        let title = String(
            repeating: "x",
            count: LiveTVXMLTVParser.maximumTextLength + 1
        )
        let xml = """
        <tv>
          <channel id="guide"><display-name>Guide</display-name></channel>
          <programme channel="guide" start="20260101000000 +0000" stop="20260101010000 +0000"><title>\(title)</title></programme>
        </tv>
        """
        XCTAssertThrowsError(
            try LiveTVXMLTVParser().parseXML(
                data: Data(xml.utf8),
                channels: [makeChannel(id: "app", name: "Guide", guideID: "guide")],
                now: now
            )
        ) {
            XCTAssertEqual($0 as? LiveTVSourceImportError, .guideTooLarge)
        }
        XCTAssertThrowsError(
            try LiveTVXMLTVParser().parseXML(
                data: Data(xml.utf8),
                channels: [],
                now: now
            )
        ) {
            XCTAssertEqual($0 as? LiveTVSourceImportError, .guideTooLarge)
        }
    }

    func testCancellationPropagates() async {
        let xml = "<tv>" + (0..<20_000).map {
            #"<channel id="\#($0)"><display-name>Channel \#($0)</display-name></channel>"#
        }.joined() + "</tv>"
        let task = Task {
            try LiveTVXMLTVParser().parseXML(
                data: Data(xml.utf8),
                channels: [],
                now: now
            )
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual(error as? LiveTVSourceImportError, .cancelled)
        }
    }

    func testDateParserRejectsInvalidFieldsAndPreservesOffsets() {
        XCTAssertNil(XMLTVDateParser.date(from: "20261301000000 +0000"))
        XCTAssertNil(XMLTVDateParser.date(from: "20260101000000 +2460"))
        XCTAssertNil(XMLTVDateParser.date(from: String(repeating: "\u{06F1}", count: 14) + " +0000"))
        XCTAssertEqual(
            XMLTVDateParser.date(from: "20260101010000 +0100"),
            XMLTVDateParser.date(from: "20260101000000 +0000")
        )
    }
    private func makeChannel(
        id: String,
        name: String,
        guideID: String?,
        streamURL: URL? = URL(string: "https://example.com/live.m3u8")
    ) -> LiveTVPrototypeChannel {
        LiveTVPrototypeChannel(
            id: id,
            number: 1,
            name: name,
            category: "Test",
            symbol: "tv.fill",
            accent: 0,
            source: .iptv,
            tagline: "Test",
            streamURL: streamURL,
            guideID: guideID
        )
    }

    private func date(_ value: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMddHHmmss Z"
        return formatter.date(from: value)!
    }

    private func gzip(_ data: Data) throws -> Data {
        var stream = z_stream()
        guard deflateInit2_(
            &stream,
            Z_BEST_SPEED,
            Z_DEFLATED,
            15 + 16,
            8,
            Z_DEFAULT_STRATEGY,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        ) == Z_OK else {
            throw LiveTVSourceImportError.invalidGuide
        }
        defer { deflateEnd(&stream) }

        var result = Data()
        var input = [UInt8](data)
        let status = input.withUnsafeMutableBytes { bytes -> Int32 in
            stream.next_in = bytes.baseAddress!.assumingMemoryBound(to: Bytef.self)
            stream.avail_in = uInt(bytes.count)
            repeat {
                var output = [UInt8](repeating: 0, count: 64 * 1_024)
                let code = output.withUnsafeMutableBytes { outputBytes -> Int32 in
                    stream.next_out = outputBytes.baseAddress!
                        .assumingMemoryBound(to: Bytef.self)
                    stream.avail_out = uInt(outputBytes.count)
                    return deflate(&stream, Z_FINISH)
                }
                let produced = output.count - Int(stream.avail_out)
                result.append(contentsOf: output.prefix(produced))
                if code == Z_STREAM_END { return code }
                if code != Z_OK { return code }
            } while true
        }
        guard status == Z_STREAM_END else {
            throw LiveTVSourceImportError.invalidGuide
        }
        return result
    }
}
#endif
