#if DEBUG
import CoreModels
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct LiveTVChannelScanTarget: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let sourceID: String
    public let streamURL: URL
    public let policy: LiveTVScanOriginPolicy
    public let streamIdentity: String
    public let hasCredentialedSourceContext: Bool

    /// Only imported IPTV entries with a configured playlist identity qualify.
    public init(
        channel: LiveTVPrototypeChannel, policy: LiveTVScanOriginPolicy, sourceIdentity: String = "",
        hasCredentialedSourceContext: Bool = false
    ) throws {
        guard channel.source == .iptv, let sourceID = channel.playlistSourceID,
              !sourceID.isEmpty, let url = channel.streamURL, policy.permits(url),
              try LiveTVScanOriginPolicy.origin(url) == policy.rootOrigin else {
            throw LiveTVChannelScanError.ineligibleChannel
        }
        id = channel.id
        name = channel.name
        self.sourceID = sourceID
        streamURL = url
        self.policy = policy
        self.hasCredentialedSourceContext = hasCredentialedSourceContext
        let headers = policy.headers.sorted { $0.key.lowercased() < $1.key.lowercased() }
            .flatMap { [$0.key.lowercased(), $0.value] }
        let origins = policy.allowedOrigins.map { "\($0.scheme)://\($0.host):\($0.port)" }.sorted()
        streamIdentity = LiveTVChannelHealthIdentity.digest(
            [sourceIdentity, url.absoluteString, String(policy.allowsHTTP), String(policy.allowsLocalNetwork),
             String(hasCredentialedSourceContext)] + headers + origins
        )
    }

    var missingResponseIsAmbiguous: Bool {
        hasCredentialedSourceContext || LiveTVScanCredentialContext.mayRequireCredentials(streamURL) ||
            policy.headers.keys.contains { ["authorization", "cookie"].contains($0.lowercased()) }
    }
}

extension LiveTVChannelScanTarget: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "LiveTVChannelScanTarget(\(streamIdentity))" }
    public var debugDescription: String { description }
}

enum LiveTVScanCredentialContext {
    static func mayRequireCredentials(_ url: URL) -> Bool {
        if url.query != nil || url.user != nil || url.password != nil { return true }
        let parts = url.pathComponents.filter { $0 != "/" }.map { $0.lowercased() }
        for (index, part) in parts.enumerated() {
            // Xtream-style URLs put account and password in path components.
            if ["live", "movie", "series"].contains(part), parts.count >= index + 4 { return true }
            if ["token", "auth", "authorization", "signature", "sig", "key", "apikey", "api-key", "session"].contains(part),
               index + 1 < parts.count { return true }
            if ["token=", "auth=", "signature=", "sig=", "key=", "hdnts=", "hdnea="].contains(where: { part.hasPrefix($0) }) ||
                part.contains("~hmac=") {
                return true
            }
            if part.hasPrefix("eyj"), part.split(separator: ".").count == 3 { return true }
        }
        return false
    }
}

public struct LiveTVChannelProbeResult: Equatable, Sendable {
    public let status: LiveTVChannelHealthStatus
    public let reason: LiveTVChannelHealthReason
    public let requests: Int

    public init(status: LiveTVChannelHealthStatus, reason: LiveTVChannelHealthReason, requests: Int = 0) {
        self.status = status
        self.reason = reason
        self.requests = requests
    }
}

public protocol LiveTVChannelProbing: Sendable {
    func probe(_ target: LiveTVChannelScanTarget) async throws -> LiveTVChannelProbeResult
}

public struct LiveTVChannelProbe: LiveTVChannelProbing {
    private let transport: any LiveTVScanHTTPTransport
    private let limits: LiveTVChannelScanLimits
    private let now: @Sendable () -> Date

    public init(
        transport: (any LiveTVScanHTTPTransport)? = nil,
        limits: LiveTVChannelScanLimits = .init(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport ?? LiveTVScanURLSessionTransport(limits: limits)
        self.limits = limits
        self.now = now
    }

    public func probe(_ target: LiveTVChannelScanTarget) async throws -> LiveTVChannelProbeResult {
        try await withThrowingTaskGroup(of: LiveTVChannelProbeResult.self) { group in
            group.addTask {
                var operation = LiveTVScanProbeOperation(target: target, transport: transport, limits: limits, now: now())
                return try await operation.run()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(limits.channelTimeout))
                return LiveTVChannelProbeResult(status: .uncertain, reason: .timedOut)
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }
            try Task.checkCancellation()
            return result
        }
    }
}

private struct LiveTVScanProbeOperation {
    let target: LiveTVChannelScanTarget
    let transport: any LiveTVScanHTTPTransport
    let limits: LiveTVChannelScanLimits
    let now: Date
    private var requests = 0
    private let started = ContinuousClock.now

    init(target: LiveTVChannelScanTarget, transport: any LiveTVScanHTTPTransport, limits: LiveTVChannelScanLimits, now: Date) {
        self.target = target
        self.transport = transport
        self.limits = limits
        self.now = now
    }

    mutating func run() async throws -> LiveTVChannelProbeResult {
        do {
            var first = try await inspect(target.streamURL, depth: 0, isRoot: true)
            if first.reason == .repeatedlyMissing {
                // A provider may mask expired account/path credentials as 404.
                guard !target.missingResponseIsAmbiguous else {
                    return result(.uncertain, .authorizationRequired)
                }
                try await Task.sleep(for: limits.retryDelay)
                let second = try await inspect(target.streamURL, depth: 0, isRoot: true)
                if second.reason == .repeatedlyMissing { return result(.unavailable, .repeatedlyMissing) }
                return result(second.status, second.reason)
            }
            if first.reason == .expiredSegment || first.reason == .staleManifest {
                // Reload the manifest instead of repeatedly fetching an expired
                // segment. Even repeated expiry is uncertain, never auto-hidden.
                try await Task.sleep(for: limits.retryDelay)
                first = try await inspect(target.streamURL, depth: 0, isRoot: true)
            }
            return result(first.status, first.reason)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as LiveTVScanTransportError {
            switch error {
            case .unsafeOrigin: return result(.uncertain, .unsafeOrigin)
            case .responseLimit: return result(.uncertain, .responseLimit)
            case .requestLimit: return result(.uncertain, .requestLimit)
            case .timedOut: return result(.uncertain, .timedOut)
            case .networkUnavailable: return result(.uncertain, .networkUnavailable)
            case .invalidResponse: return result(.uncertain, .invalidManifest)
            }
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            return result(.uncertain, error.code == .timedOut ? .timedOut : .networkUnavailable)
        } catch {
            return result(.uncertain, .networkUnavailable)
        }
    }

    private func result(_ status: LiveTVChannelHealthStatus, _ reason: LiveTVChannelHealthReason) -> LiveTVChannelProbeResult {
        LiveTVChannelProbeResult(status: status, reason: reason, requests: requests)
    }

    private mutating func inspect(_ url: URL, depth: Int, isRoot: Bool) async throws -> LiveTVChannelProbeResult {
        guard depth <= 2 else { return result(.uncertain, .requestLimit) }
        let (response, resolvedURL) = try await fetch(url, media: false)
        guard (200...299).contains(response.statusCode) else {
            return status(
                response.statusCode,
                missingReason: isRoot && url == resolvedURL ? .repeatedlyMissing : .staleManifest
            )
        }
        if Self.hasMediaEvidence(response.data) { return result(.reachable, .mediaObserved) }
        guard !response.wasTruncated else { return result(.uncertain, .responseLimit) }
        guard let text = String(data: response.data, encoding: .utf8),
              text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") else {
            return result(.uncertain, .unsupportedMedia)
        }
        let manifest = LiveTVScanManifest(text)
        if manifest.encrypted { return result(.uncertain, .encryptedMedia) }
        if manifest.unsupported { return result(.uncertain, .unsupportedMedia) }
        if !manifest.variants.isEmpty {
            var failure = result(.uncertain, .staleManifest)
            for reference in manifest.variants.prefix(2) {
                guard let variant = URL(string: reference, relativeTo: resolvedURL)?.absoluteURL,
                      target.policy.permits(variant) else {
                    failure = result(.uncertain, .unsafeOrigin)
                    continue
                }
                let checked = try await inspect(variant, depth: depth + 1, isRoot: false)
                if checked.status == .reachable { return checked }
                failure = checked
            }
            return failure
        }
        guard !manifest.segments.isEmpty else { return result(.uncertain, .invalidManifest) }
        if !manifest.ended, let newest = manifest.lastProgramDate,
           now.timeIntervalSince(newest) > max(120, manifest.targetDuration * 6) {
            return result(.uncertain, .staleManifest)
        }
        var failure = result(.uncertain, .expiredSegment)
        for reference in manifest.segments.suffix(2).reversed() {
            guard let segment = URL(string: reference, relativeTo: resolvedURL)?.absoluteURL,
                  target.policy.permits(segment) else {
                failure = result(.uncertain, .unsafeOrigin)
                continue
            }
            let (sample, _) = try await fetch(segment, media: true)
            if (200...299).contains(sample.statusCode) {
                if Self.hasMediaEvidence(sample.data) { return result(.reachable, .mediaObserved) }
                failure = result(.uncertain, .unsupportedMedia)
            } else {
                failure = status(sample.statusCode, missingReason: .expiredSegment)
                if sample.statusCode == 401 || sample.statusCode == 403 || sample.statusCode == 429 { return failure }
            }
        }
        return failure
    }

    private func status(_ code: Int, missingReason: LiveTVChannelHealthReason) -> LiveTVChannelProbeResult {
        switch code {
        case 404, 410: return result(.uncertain, missingReason)
        case 401, 403: return result(.uncertain, .authorizationRequired)
        case 451: return result(.uncertain, .restricted)
        case 429: return result(.uncertain, .rateLimited)
        case 500...599: return result(.uncertain, .serverFailure)
        default: return result(.uncertain, .invalidManifest)
        }
    }

    private mutating func fetch(_ initialURL: URL, media: Bool) async throws -> (LiveTVScanHTTPResponse, URL) {
        var url = initialURL
        for redirect in 0...limits.redirects {
            try Task.checkCancellation()
            guard requests < limits.requestsPerChannel else { throw LiveTVScanTransportError.requestLimit }
            let remaining = limits.channelTimeout - Self.seconds(started.duration(to: .now))
            guard remaining > 0 else { throw LiveTVScanTransportError.timedOut }
            guard target.policy.permits(url) else { throw LiveTVScanTransportError.unsafeOrigin }
            let maximumBytes = media ? limits.mediaBytes : limits.manifestBytes
            var request = URLRequest(url: url)
            request.timeoutInterval = min(limits.requestTimeout, remaining)
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            for (name, value) in target.policy.requestHeaders(for: url) {
                request.setValue(value, forHTTPHeaderField: name)
            }
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            request.setValue("bytes=0-\(maximumBytes - 1)", forHTTPHeaderField: "Range")
            requests += 1
            let response = try await transport.fetch(request, maximumBytes: maximumBytes, acceptsPrefix: true)
            try Task.checkCancellation()
            guard response.data.count <= maximumBytes else { throw LiveTVScanTransportError.responseLimit }
            if [301, 302, 303, 307, 308].contains(response.statusCode) {
                guard redirect < limits.redirects, let location = response.location,
                      let next = URL(string: location, relativeTo: url)?.absoluteURL,
                      target.policy.permits(next),
                      !(url.scheme?.lowercased() == "https" && next.scheme?.lowercased() == "http")
                else { throw LiveTVScanTransportError.unsafeOrigin }
                url = next
                continue
            }
            return (response, url)
        }
        throw LiveTVScanTransportError.requestLimit
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    static func hasMediaEvidence(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(1_024))
        // Three MPEG-TS packet sync bytes, or a recognized ISO media box.
        if bytes.count >= 377 && bytes[0] == 0x47 && bytes[188] == 0x47 && bytes[376] == 0x47 { return true }
        if bytes.count >= 12,
           let box = String(bytes: bytes[4..<8], encoding: .ascii),
           ["ftyp", "styp", "moof", "mdat"].contains(box) { return true }
        // ADTS audio, or a framed MPEG audio header. No decoder is allocated.
        if bytes.count >= 16 && bytes[0] == 0xff && (bytes[1] & 0xf6) == 0xf0 { return true }
        return false
    }
}

private struct LiveTVScanManifest {
    var variants: [String] = []
    var segments: [String] = []
    var encrypted = false
    var unsupported = false
    var ended = false
    var lastProgramDate: Date?
    var targetDuration: TimeInterval = 10

    init(_ text: String) {
        var variantExpected = false
        var segmentExpected = false
        let formatter = ISO8601DateFormatter()
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for line in text.split(whereSeparator: \.isNewline) {
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("#EXT-X-STREAM-INF:") {
                variantExpected = true
            } else if value.hasPrefix("#EXTINF:") {
                segmentExpected = true
            } else if value.hasPrefix("#EXT-X-KEY:") || value.hasPrefix("#EXT-X-SESSION-KEY:") {
                let attributes = value.split(separator: ":", maxSplits: 1).last.map(String.init) ?? ""
                let method = attributes.split(separator: ",").first { $0.hasPrefix("METHOD=") }
                if method != "METHOD=NONE" { encrypted = true }
            } else if value.hasPrefix("#EXT-X-BYTERANGE:") || value.hasPrefix("#EXT-X-PART:") {
                unsupported = true
            } else if value == "#EXT-X-ENDLIST" {
                ended = true
            } else if value.hasPrefix("#EXT-X-TARGETDURATION:") {
                if let duration = Double(value.dropFirst("#EXT-X-TARGETDURATION:".count)), duration.isFinite, duration > 0 {
                    targetDuration = duration
                }
            } else if value.hasPrefix("#EXT-X-PROGRAM-DATE-TIME:") {
                let date = String(value.dropFirst("#EXT-X-PROGRAM-DATE-TIME:".count))
                lastProgramDate = fractionalFormatter.date(from: date) ?? formatter.date(from: date)
            } else if !value.hasPrefix("#"), !value.isEmpty {
                if variantExpected {
                    variants.append(value)
                    variantExpected = false
                } else if segmentExpected {
                    segments.append(value)
                    segmentExpected = false
                }
            }
        }
    }
}
#endif
