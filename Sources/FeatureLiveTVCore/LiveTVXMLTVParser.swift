#if DEBUG
import CryptoKit
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import zlib

public struct LiveTVGuideImport: Codable, Sendable {
    public let programs: [LiveTVPrototypeProgram]
    public let matchedChannelCount: Int
    public let guideChannelCount: Int
    public let programCount: Int
    public let coverageStart: Date?
    public let coverageEnd: Date?
    public let matches: [String: LiveTVGuideMatch]
    public let guideChannels: [String: [String]]

    public init(
        programs: [LiveTVPrototypeProgram],
        matchedChannelCount: Int,
        guideChannelCount: Int,
        programCount: Int,
        coverageStart: Date?,
        coverageEnd: Date?,
        matches: [String: LiveTVGuideMatch] = [:],
        guideChannels: [String: [String]] = [:]
    ) {
        self.programs = programs
        self.matchedChannelCount = matchedChannelCount
        self.guideChannelCount = guideChannelCount
        self.programCount = programCount
        self.coverageStart = coverageStart
        self.coverageEnd = coverageEnd
        self.matches = matches
        self.guideChannels = guideChannels
    }
}

public struct LiveTVXMLTVParser: Sendable {
    public static let maximumCompressedBytes = 32 * 1_024 * 1_024
    public static let maximumExpandedBytes = 256 * 1_024 * 1_024
    public static let maximumGuideChannels = 20_000
    public static let maximumPrograms = 2_000_000
    public static let maximumTextLength = 16_384
    public static let maximumRetainedPrograms = 250_000
    public static let maximumRetainedTextBytes = 32 * 1_024 * 1_024

    private let maximumExpandedBytes: Int
    private let provider: LiveTVGuideProvider?

    public init(
        maximumExpandedBytes: Int = Self.maximumExpandedBytes,
        provider: LiveTVGuideProvider? = nil
    ) {
        self.maximumExpandedBytes = maximumExpandedBytes
        self.provider = provider
    }

    public func parse(
        gzipData: Data,
        channels: [LiveTVPrototypeChannel],
        now: Date,
        overrides: [String: String] = [:],
        lookbackDays: Int = 1, lookaheadDays: Int = 7
    ) throws -> LiveTVGuideImport {
        guard gzipData.count <= Self.maximumCompressedBytes else {
            throw LiveTVSourceImportError.guideTooLarge
        }
        return try parseXML(
            makeStream: {
                try BoundedGzipInputStream(
                    compressedStream: InputStream(data: gzipData),
                    maximumExpandedBytes: maximumExpandedBytes
                )
            },
            channels: channels,
            now: now, overrides: overrides, lookbackDays: lookbackDays, lookaheadDays: lookaheadDays
        )
    }

    public func parseXML(
        data: Data,
        channels: [LiveTVPrototypeChannel],
        now: Date,
        overrides: [String: String] = [:],
        lookbackDays: Int = 1, lookaheadDays: Int = 7
    ) throws -> LiveTVGuideImport {
        guard data.count <= maximumExpandedBytes else {
            throw LiveTVSourceImportError.guideTooLarge
        }
        return try parseXML(
            makeStream: { InputStream(data: data) },
            channels: channels,
            now: now, overrides: overrides, lookbackDays: lookbackDays, lookaheadDays: lookaheadDays
        )
    }

    public func parseIndexed(
        data: Data, channels: [LiveTVPrototypeChannel], now: Date,
        overrides: [String: String] = [:], lookbackDays: Int = 1, lookaheadDays: Int = 7,
        sink: @escaping (LiveTVPrototypeProgram) throws -> Void
    ) throws -> LiveTVGuideImport {
        guard (0...7).contains(lookbackDays), (1...28).contains(lookaheadDays) else {
            throw LiveTVSourceImportError.invalidGuide
        }
        let gzip = data.starts(with: [0x1f, 0x8b])
        guard data.count <= (gzip ? Self.maximumCompressedBytes : maximumExpandedBytes) else {
            throw LiveTVSourceImportError.guideTooLarge
        }
        return try parseXML(
            makeStream: {
                if gzip {
                    return try BoundedGzipInputStream(
                        compressedStream: InputStream(data: data), maximumExpandedBytes: maximumExpandedBytes
                    )
                }
                return InputStream(data: data)
            }, channels: channels, now: now, overrides: overrides,
            lookbackDays: lookbackDays, lookaheadDays: lookaheadDays, sink: sink
        )
    }

    private func parseXML(
        makeStream: () throws -> InputStream,
        channels: [LiveTVPrototypeChannel],
        now: Date,
        overrides: [String: String] = [:],
        lookbackDays: Int = 1, lookaheadDays: Int = 7,
        sink: ((LiveTVPrototypeProgram) throws -> Void)? = nil
    ) throws -> LiveTVGuideImport {
        try checkCancellation()
        guard (0...7).contains(lookbackDays), (1...28).contains(lookaheadDays) else {
            throw LiveTVSourceImportError.invalidGuide
        }
        let metadataDelegate = XMLTVDelegate()
        try parseXML(stream: makeStream(), delegate: metadataDelegate)
        try checkCancellation()
        let matching = LiveTVGuideMatcher(provider: provider).matching(
            channels: channels,
            guideChannels: metadataDelegate.guideChannels,
            overrides: overrides
        )
        try checkCancellation()
        let programmeDelegate = XMLTVDelegate(
            channelsByGuideID: matching.channelsByGuideID,
            initialRetainedTextBytes: metadataDelegate.retainedTextBytes,
            now: now, lookbackDays: lookbackDays, lookaheadDays: lookaheadDays, sink: sink
        )
        try parseXML(stream: makeStream(), delegate: programmeDelegate)
        try checkCancellation()
        return try programmeDelegate.makeResult(
            guideChannelCount: metadataDelegate.guideChannels.count,
            assignments: matching.assignments,
            guideChannels: metadataDelegate.guideChannels
        )
    }

    private func parseXML(stream: InputStream, delegate: XMLTVDelegate) throws {
        stream.open()
        defer { stream.close() }
        let guardedStream = EntityRejectingXMLInputStream(source: stream)
        delegate.didStartRoot = { guardedStream.inspectDeclarations = false }
        defer { delegate.didStartRoot = nil }
        let parser = XMLParser(stream: guardedStream)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        let parsed = parser.parse()
        if let streamError = guardedStream.streamError as? LiveTVSourceImportError {
            throw streamError
        }
        guard parsed, delegate.error == nil else {
            if let sinkError = delegate.sinkError { throw sinkError }
            throw delegate.error ?? LiveTVSourceImportError.invalidGuide
        }
    }

    private func checkCancellation() throws {
        if Task.isCancelled {
            throw LiveTVSourceImportError.cancelled
        }
    }
}

private final class XMLTVDelegate: NSObject, XMLParserDelegate {
    var didStartRoot: (() -> Void)?
    private enum Pass {
        case metadata
        case programmes
    }

    private let pass: Pass
    private let channelsByGuideID: [String: [LiveTVPrototypeChannel]]
    private let lowerBound: Date?
    private let upperBound: Date?
    private(set) var guideChannels: [String: [String]] = [:]
    private(set) var retainedTextBytes: Int
    private var programs: [LiveTVPrototypeProgram] = []
    private var retainedProgramCount = 0
    private let sink: ((LiveTVPrototypeProgram) throws -> Void)?
    private(set) var sinkError: (any Error)?
    private var seenProgramIDs = Set<String>()
    private var currentChannelID: String?
    private var currentChannelNames: [String] = []
    private var currentChannelTextBytes = 0
    private var insideProgramme = false
    private var currentProgram: PendingProgram?
    private var missingEndPrograms: [String: PendingProgram] = [:]
    private var missingEndTextBytes = 0
    private var parsedDates: [String: Date] = [:]
    private var currentElement: String?
    private var currentElementDepth: Int?
    private var text = ""
    private var sawTV = false
    private var closedTV = false
    private var depth = 0
    private var channelDeclarationCount = 0
    private var sourceProgramCount = 0
    private(set) var error: LiveTVSourceImportError?
    private(set) var coverageStart: Date?
    private(set) var coverageEnd: Date?

    override init() {
        pass = .metadata
        channelsByGuideID = [:]
        lowerBound = nil
        upperBound = nil
        retainedTextBytes = 0
        sink = nil
        super.init()
    }

    init(
        channelsByGuideID: [String: [LiveTVPrototypeChannel]],
        initialRetainedTextBytes: Int,
        now: Date, lookbackDays: Int = 1, lookaheadDays: Int = 7,
        sink: ((LiveTVPrototypeProgram) throws -> Void)? = nil
    ) {
        pass = .programmes
        self.channelsByGuideID = channelsByGuideID
        lowerBound = now.addingTimeInterval(-Double(lookbackDays) * 86_400)
        upperBound = now.addingTimeInterval(Double(lookaheadDays) * 86_400)
        retainedTextBytes = initialRetainedTextBytes
        self.sink = sink
        super.init()
    }

    func makeResult(
        guideChannelCount: Int,
        assignments: [String: LiveTVGuideMatch],
        guideChannels: [String: [String]]
    ) throws -> LiveTVGuideImport {
        if Task.isCancelled {
            throw LiveTVSourceImportError.cancelled
        }
        programs.sort {
            ($0.channelID, $0.start, $0.end, $0.title, $0.id)
                < ($1.channelID, $1.start, $1.end, $1.title, $1.id)
        }
        if Task.isCancelled {
            throw LiveTVSourceImportError.cancelled
        }
        return LiveTVGuideImport(
            programs: programs,
            matchedChannelCount: assignments.count,
            guideChannelCount: guideChannelCount,
            programCount: retainedProgramCount,
            coverageStart: coverageStart,
            coverageEnd: coverageEnd,
            matches: assignments,
            guideChannels: guideChannels
        )
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard error == nil else {
            parser.abortParsing()
            return
        }
        if Task.isCancelled {
            error = .cancelled
            parser.abortParsing()
            return
        }
        let parentDepth = depth
        depth += 1
        if parentDepth == 0 {
            guard elementName == "tv", !sawTV, !closedTV else {
                error = .invalidGuide
                parser.abortParsing()
                return
            }
            sawTV = true
            didStartRoot?()
            return
        }
        if elementName == "tv" {
            error = .invalidGuide
            parser.abortParsing()
            return
        }
        if parentDepth == 1 {
            switch elementName {
            case "channel":
                channelDeclarationCount += 1
                guard channelDeclarationCount <= LiveTVXMLTVParser.maximumGuideChannels else {
                    error = .guideTooLarge
                    parser.abortParsing()
                    return
                }
                guard case .metadata = pass else { return }
                guard let rawIdentifier = attributeDict["id"], !rawIdentifier.isEmpty else {
                    error = .invalidGuide
                    parser.abortParsing()
                    return
                }
                guard rawIdentifier.count <= 4_096 else {
                    error = .guideTooLarge
                    parser.abortParsing()
                    return
                }
                currentChannelID = rawIdentifier
                currentChannelNames = []
                currentChannelTextBytes = 0
            case "programme":
                sourceProgramCount += 1
                guard sourceProgramCount <= LiveTVXMLTVParser.maximumPrograms else {
                    error = .guideTooLarge
                    parser.abortParsing()
                    return
                }
                guard case .programmes = pass else { return }
                insideProgramme = true
                guard let guideChannelID = bounded(attributeDict["channel"], maximum: 4_096),
                      let startText = bounded(attributeDict["start"], maximum: 64),
                      let start = parsedDate(startText)
                else {
                    currentProgram = nil
                    return
                }
                let end: Date
                if let stop = attributeDict["stop"] {
                    guard let text = bounded(stop, maximum: 64), let parsed = parsedDate(text),
                          parsed > start else { currentProgram = nil; return }
                    end = parsed
                } else {
                    end = start
                }
                if var previous = missingEndPrograms.removeValue(forKey: guideChannelID) {
                    missingEndTextBytes -= previous.textBytes
                    // Missing stops are inferred only from the next valid start for the
                    // same XMLTV channel, strictly increasing and at most six hours.
                    // Out-of-order, final and discontinuous entries remain unscheduled.
                    if start > previous.start, start.timeIntervalSince(previous.start) <= 6 * 3_600 {
                        previous.end = start
                        previous.details.endWasInferred = true
                        emitProgramme(previous, parser: parser)
                        if error != nil { return }
                    }
                }
                coverageStart = min(coverageStart ?? start, start)
                if end > start { coverageEnd = max(coverageEnd ?? end, end) }
                guard let lowerBound, let upperBound,
                      start < upperBound, (end > start ? end : start.addingTimeInterval(6 * 3_600)) > lowerBound,
                      channelsByGuideID[guideChannelID] != nil
                else {
                    currentProgram = nil
                    return
                }
                currentProgram = PendingProgram(
                    guideChannelID: guideChannelID,
                    title: "",
                    subtitle: "",
                    start: start,
                    end: end
                )
            default:
                break
            }
            return
        }
        if parentDepth == 2 {
            switch pass {
            case .metadata where currentChannelID != nil && elementName == "display-name":
                beginText(for: elementName)
            case .programmes where insideProgramme
                && ["title", "sub-title", "desc", "episode-num", "category", "language"].contains(elementName):
                beginText(for: elementName)
                if let language = bounded(attributeDict["lang"], maximum: 64),
                   (currentProgram?.details.languages.count ?? 0) < 32,
                   currentProgram?.details.languages.contains(language) == false {
                    currentProgram?.details.languages.append(language)
                }
            case .programmes where insideProgramme && elementName == "icon":
                if let address = bounded(attributeDict["src"], maximum: 4_096),
                   let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                   url.user == nil, url.password == nil {
                    currentProgram?.details.artworkURL = url
                }
            default:
                break
            }
            return
        }
        if parentDepth == 3, insideProgramme, elementName == "value" {
            beginText(for: elementName)
        }
        if elementName == "channel" || elementName == "programme" {
            error = .invalidGuide
            parser.abortParsing()
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard currentElement != nil else { return }
        guard text.utf8.count + string.utf8.count <= LiveTVXMLTVParser.maximumTextLength else {
            error = .guideTooLarge
            parser.abortParsing()
            return
        }
        text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard let string = String(data: CDATABlock, encoding: .utf8) else {
            error = .invalidGuide
            parser.abortParsing()
            return
        }
        self.parser(parser, foundCharacters: string)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard depth > 0 else {
            error = .invalidGuide
            parser.abortParsing()
            return
        }
        depth -= 1
        let elementDepth = depth

        if currentElement == elementName, currentElementDepth == elementDepth {
            switch elementName {
            case "display-name":
                if let value = normalizedText(text) {
                    let byteCount = value.utf8.count
                    guard retainedTextBytes + currentChannelTextBytes + byteCount
                        <= LiveTVXMLTVParser.maximumRetainedTextBytes
                    else {
                        error = .guideTooLarge
                        parser.abortParsing()
                        return
                    }
                    currentChannelNames.append(value)
                    currentChannelTextBytes += byteCount
                }
            case "title":
                if currentProgram != nil, let value = normalizedText(text) {
                    currentProgram?.title = value
                }
            case "sub-title":
                if currentProgram != nil, let value = normalizedText(text) {
                    currentProgram?.subtitle = value
                }
            case "desc": currentProgram?.details.description = normalizedText(text)
            case "episode-num": currentProgram?.details.episode = normalizedText(text)
            case "category":
                if let value = normalizedText(text), currentProgram?.details.categories.count ?? 0 < 32 {
                    currentProgram?.details.categories.append(value)
                }
            case "language":
                if let value = normalizedText(text), currentProgram?.details.languages.count ?? 0 < 32 {
                    currentProgram?.details.languages.append(value)
                }
            case "value": currentProgram?.details.rating = normalizedText(text)
            default:
                break
            }
            currentElement = nil
            currentElementDepth = nil
            text = ""
        }

        if elementDepth == 1 {
            switch elementName {
            case "channel":
                finishChannel(parser)
            case "programme":
                finishProgramme(parser)
            default:
                break
            }
        } else if elementDepth == 0 {
            guard elementName == "tv", sawTV, !closedTV else {
                error = .invalidGuide
                parser.abortParsing()
                return
            }
            closedTV = true
        }
    }

    func parser(_ parser: XMLParser, foundSkippedEntityName name: String) {
        error = .invalidGuide
        parser.abortParsing()
    }

    func parser(
        _ parser: XMLParser,
        resolveExternalEntityName name: String,
        systemID: String?
    ) -> Data? {
        nil
    }

    func parser(
        _ parser: XMLParser,
        foundInternalEntityDeclarationWithName name: String,
        value: String?
    ) {
        error = .invalidGuide
        parser.abortParsing()
    }

    func parser(
        _ parser: XMLParser,
        foundExternalEntityDeclarationWithName name: String,
        publicID: String?,
        systemID: String?
    ) {
        error = .invalidGuide
        parser.abortParsing()
    }

    func parser(
        _ parser: XMLParser,
        foundUnparsedEntityDeclarationWithName name: String,
        publicID: String?,
        systemID: String?,
        notationName: String?
    ) {
        error = .invalidGuide
        parser.abortParsing()
    }

    func parser(
        _ parser: XMLParser,
        foundNotationDeclarationWithName name: String,
        publicID: String?,
        systemID: String?
    ) {
        error = .invalidGuide
        parser.abortParsing()
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        if error == nil {
            error = Task.isCancelled ? .cancelled : .invalidGuide
        }
    }

    func parserDidEndDocument(_ parser: XMLParser) {
        if (!sawTV || !closedTV || depth != 0), error == nil {
            error = .invalidGuide
        }
    }

    private func beginText(for elementName: String) {
        currentElement = elementName
        currentElementDepth = depth - 1
        text = ""
    }

    private func finishChannel(_ parser: XMLParser) {
        defer {
            currentChannelID = nil
            currentChannelNames = []
            currentChannelTextBytes = 0
        }
        guard case .metadata = pass, let identifier = currentChannelID else { return }
        if let existing = guideChannels[identifier] {
            guard existing == currentChannelNames else {
                error = .invalidGuide
                parser.abortParsing()
                return
            }
        } else {
            guard guideChannels.count < LiveTVXMLTVParser.maximumGuideChannels else {
                error = .guideTooLarge
                parser.abortParsing()
                return
            }
            guideChannels[identifier] = currentChannelNames
            retainedTextBytes += currentChannelTextBytes
        }
    }

    private func finishProgramme(_ parser: XMLParser) {
        defer {
            insideProgramme = false
            currentProgram = nil
        }
        guard case .programmes = pass,
              let program = currentProgram,
              !program.title.isEmpty
        else { return }
        if program.end == program.start {
            missingEndTextBytes += program.textBytes
            guard missingEndPrograms.count < LiveTVXMLTVParser.maximumGuideChannels,
                  missingEndTextBytes <= LiveTVXMLTVParser.maximumRetainedTextBytes else {
                error = .guideTooLarge
                parser.abortParsing()
                return
            }
            missingEndPrograms[program.guideChannelID] = program
            return
        }
        emitProgramme(program, parser: parser)
    }

    private func emitProgramme(_ program: PendingProgram, parser: XMLParser) {
        guard let lowerBound, let upperBound, program.start < upperBound, program.end > lowerBound else { return }
        coverageEnd = max(coverageEnd ?? program.end, program.end)
        if sink == nil {
            retainedTextBytes += program.textBytes
        }
        guard retainedTextBytes <= LiveTVXMLTVParser.maximumRetainedTextBytes else {
            error = .guideTooLarge
            parser.abortParsing()
            return
        }
        for channel in channelsByGuideID[program.guideChannelID] ?? [] {
            if Task.isCancelled {
                error = .cancelled
                parser.abortParsing()
                return
            }
            let identifier = stableProgramID(
                channelID: channel.id,
                guideChannelID: program.guideChannelID,
                title: program.title,
                subtitle: program.subtitle,
                start: program.start,
                end: program.end
            )
            if sink == nil, !seenProgramIDs.insert(identifier).inserted { continue }
            guard retainedProgramCount < (sink == nil ? LiveTVXMLTVParser.maximumRetainedPrograms : LiveTVXMLTVParser.maximumPrograms) else {
                error = .guideTooLarge
                parser.abortParsing()
                return
            }
            let value = LiveTVPrototypeProgram(
                id: identifier,
                channelID: channel.id,
                title: program.title,
                subtitle: program.subtitle,
                start: program.start,
                end: program.end,
                details: program.details
            )
            if let sink {
                do { try sink(value) }
                catch {
                    sinkError = error
                    self.error = .cacheFailed
                    parser.abortParsing()
                    return
                }
            } else {
                programs.append(value)
            }
            retainedProgramCount += 1
        }
    }

    private func stableProgramID(
        channelID: String,
        guideChannelID: String,
        title: String,
        subtitle: String,
        start: Date,
        end: Date
    ) -> String {
        let components = [
            channelID,
            guideChannelID,
            title,
            subtitle,
            String(Int64(start.timeIntervalSince1970)),
            String(Int64(end.timeIntervalSince1970)),
        ]
        let digest = SHA256.hash(
            data: Data(components.joined(separator: "\u{1F}").utf8)
        )
        return "xmltv-" + LiveTVIdentityDigest.hex(digest)
    }

    private func normalizedText(_ text: String) -> String? {
        let result = text.split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return result.isEmpty ? nil : result
    }

    private func bounded(_ text: String?, maximum: Int) -> String? {
        guard let text, !text.isEmpty, text.count <= maximum else { return nil }
        return text
    }

    private func parsedDate(_ text: String) -> Date? {
        if let existing = parsedDates[text] { return existing }
        guard let date = XMLTVDateParser.date(from: text) else { return nil }
        if parsedDates.count >= 2_048 { parsedDates.removeAll(keepingCapacity: true) }
        parsedDates[text] = date
        return date
    }
}

private struct PendingProgram {
    let guideChannelID: String
    var title: String
    var subtitle: String
    let start: Date
    var end: Date
    var details = LiveTVProgramDetails()
    var textBytes: Int {
        title.utf8.count + subtitle.utf8.count + (details.description?.utf8.count ?? 0)
            + details.categories.reduce(0) { $0 + $1.utf8.count }
            + details.languages.reduce(0) { $0 + $1.utf8.count }
            + (details.episode?.utf8.count ?? 0) + (details.rating?.utf8.count ?? 0)
            + (details.artworkURL?.absoluteString.utf8.count ?? 0)
    }
}

public enum XMLTVDateParser {
    public static func date(from input: String) -> Date? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 14 else { return nil }
        let timestampEnd = trimmed.index(trimmed.startIndex, offsetBy: 14)
        let timestamp = trimmed[..<timestampEnd]
        guard timestamp.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        let remainder = trimmed[timestampEnd...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let offsetText: String
        if remainder.isEmpty {
            offsetText = "+0000"
        } else if remainder == "Z" {
            offsetText = "+0000"
        } else {
            guard remainder.count == 5,
                  ["+", "-"].contains(String(remainder.prefix(1))),
                  remainder.dropFirst().allSatisfy(\.isNumber)
            else { return nil }
            offsetText = remainder
        }
        let digits = Array(timestamp.utf8)
        func integer(_ start: Int, _ count: Int) -> Int {
            digits[start..<(start + count)].reduce(0) {
                $0 * 10 + Int($1 - 48)
            }
        }
        let year = integer(0, 4)
        let month = integer(4, 2)
        let day = integer(6, 2)
        let hour = integer(8, 2)
        let minute = integer(10, 2)
        let second = integer(12, 2)
        guard (1...9_999).contains(year),
              (1...12).contains(month),
              (1...daysInMonth(month, year: year)).contains(day),
              (0...23).contains(hour),
              (0...59).contains(minute),
              (0...60).contains(second),
              let offsetHours = Int(offsetText.dropFirst().prefix(2)),
              let offsetMinutes = Int(offsetText.suffix(2)),
              offsetHours <= 23,
              offsetMinutes <= 59
        else { return nil }
        let direction = offsetText.first == "-" ? -1 : 1
        let offset = direction * ((offsetHours * 60 + offsetMinutes) * 60)
        let seconds = daysFromCivil(year: year, month: month, day: day) * 86_400
            + hour * 3_600
            + minute * 60
            + second
            - offset
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    private static func daysInMonth(_ month: Int, year: Int) -> Int {
        switch month {
        case 2:
            let leap = year.isMultiple(of: 4)
                && (!year.isMultiple(of: 100) || year.isMultiple(of: 400))
            return leap ? 29 : 28
        case 4, 6, 9, 11:
            return 30
        default:
            return 31
        }
    }

    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let adjustedYear = year - (month <= 2 ? 1 : 0)
        let era = adjustedYear / 400
        let yearOfEra = adjustedYear - era * 400
        let adjustedMonth = month + (month > 2 ? -3 : 9)
        let dayOfYear = (153 * adjustedMonth + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }
}

private final class BoundedGzipInputStream: InputStream {
    private let compressedStream: InputStream
    private let maximumExpandedBytes: Int
    private var zstream = z_stream()
    private let input = UnsafeMutablePointer<UInt8>.allocate(capacity: 64 * 1_024)
    private var output = [UInt8]()
    private var outputIndex = 0
    private var expandedBytes = 0
    private var reachedEnd = false
    private var failure: LiveTVSourceImportError?

    init(compressedStream: InputStream, maximumExpandedBytes: Int) throws {
        self.compressedStream = compressedStream
        self.maximumExpandedBytes = maximumExpandedBytes
        super.init(data: Data())
        let status = inflateInit2_(
            &zstream,
            15 + 32,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard status == Z_OK else {
            throw LiveTVSourceImportError.invalidGuide
        }
    }

    deinit {
        inflateEnd(&zstream)
        input.deallocate()
    }

    override var hasBytesAvailable: Bool {
        failure == nil && (outputIndex < output.count || !reachedEnd)
    }

    override var streamStatus: Stream.Status {
        if failure != nil { return .error }
        if reachedEnd && outputIndex >= output.count { return .atEnd }
        return .open
    }

    override var streamError: Error? {
        failure
    }

    override func open() {
        compressedStream.open()
    }

    override func close() {
        compressedStream.close()
    }

    override func read(
        _ buffer: UnsafeMutablePointer<UInt8>,
        maxLength len: Int
    ) -> Int {
        guard failure == nil else { return -1 }
        if Task.isCancelled {
            failure = .cancelled
            return -1
        }
        if outputIndex >= output.count, !fillOutput() {
            return failure == nil ? 0 : -1
        }
        let count = min(len, output.count - outputIndex)
        output.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            buffer.update(
                from: base.assumingMemoryBound(to: UInt8.self)
                    .advanced(by: outputIndex),
                count: count
            )
        }
        outputIndex += count
        return count
    }

    override func getBuffer(
        _ buffer: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>,
        length len: UnsafeMutablePointer<Int>
    ) -> Bool {
        false
    }

    private func fillOutput() -> Bool {
        output = []
        outputIndex = 0
        guard !reachedEnd else { return false }

        while output.isEmpty && !reachedEnd && failure == nil {
            if zstream.avail_in == 0 {
                let count = compressedStream.read(input, maxLength: 64 * 1_024)
                guard count > 0 else {
                    failure = .invalidGuide
                    break
                }
                zstream.next_in = input
                zstream.avail_in = uInt(count)
            }

            var chunk = [UInt8](repeating: 0, count: 64 * 1_024)
            let status: Int32 = chunk.withUnsafeMutableBytes {
                zstream.next_out = $0.baseAddress!
                    .assumingMemoryBound(to: Bytef.self)
                zstream.avail_out = uInt($0.count)
                return inflate(&zstream, Z_NO_FLUSH)
            }
            let produced = chunk.count - Int(zstream.avail_out)
            if produced > 0 {
                expandedBytes += produced
                guard expandedBytes <= maximumExpandedBytes else {
                    failure = .guideTooLarge
                    break
                }
                output = Array(chunk.prefix(produced))
            }
            if status == Z_STREAM_END {
                reachedEnd = true
            } else if status != Z_OK {
                failure = .invalidGuide
            }
        }
        return !output.isEmpty
    }
}

private final class EntityRejectingXMLInputStream: InputStream {
    var inspectDeclarations = true
    private static let forbidden = Array("<!ENTITY".utf8)
    private let source: InputStream
    private var matchedBytes = 0
    private var failure: LiveTVSourceImportError?

    init(source: InputStream) {
        self.source = source
        super.init(data: Data())
    }

    override var hasBytesAvailable: Bool { failure == nil && source.hasBytesAvailable }
    override var streamStatus: Stream.Status { failure == nil ? source.streamStatus : .error }
    override var streamError: Error? { failure ?? source.streamError }
    override func open() {}
    override func close() {}

    override func read(_ buffer: UnsafeMutablePointer<UInt8>, maxLength len: Int) -> Int {
        guard failure == nil else { return -1 }
        if Task.isCancelled {
            failure = .cancelled
            return -1
        }
        let count = source.read(buffer, maxLength: len)
        guard count > 0 else { return count }
        // Declarations are legal only in the prolog. Once XMLParser reports
        // the real root, it rejects any later declaration as malformed XML.
        guard inspectDeclarations else { return count }
        // XMLParser can silently skip external declarations on tvOS. Reject
        // them before parsing, including UTF-16/32's zero-padded ASCII tokens.
        for byte in UnsafeBufferPointer(start: buffer, count: count) where byte != 0 {
            if byte == Self.forbidden[matchedBytes] { matchedBytes += 1 }
            else { matchedBytes = byte == Self.forbidden[0] ? 1 : 0 }
            if matchedBytes == Self.forbidden.count {
                failure = .invalidGuide
                return -1
            }
        }
        return count
    }

    override func getBuffer(
        _ buffer: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>,
        length len: UnsafeMutablePointer<Int>
    ) -> Bool {
        false
    }
}
#endif
