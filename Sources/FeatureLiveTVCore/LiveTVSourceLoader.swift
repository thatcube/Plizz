#if DEBUG
import Foundation
import CryptoKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public actor LiveTVSourceLoader: LiveTVIndexedSourceLoading {
    private static let playlistLimit = LiveTVPlaylistParser.maximumBytes
    private static let guideLimit = LiveTVXMLTVParser.maximumExpandedBytes
    private let session: URLSession
    private let redirects = LiveTVSourceRedirectPolicy()
    private var responses: [URL: Response] = [:]

    private struct Response: Sendable {
        let data: Data
        let finalURL: URL
        let etag: String?
        let modified: String?
        let expires: Date
        let permitsPersistence: Bool
        let cacheControl: String
    }

    public init(configuration suppliedConfiguration: URLSessionConfiguration? = nil) {
        let configuration = suppliedConfiguration ?? URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: redirects, delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    public func loadPlaylist(from url: URL) async throws -> LiveTVPlaylistImport {
        let response = try await download(
            from: url,
            maximumBytes: Self.playlistLimit,
            tooLargeError: .responseTooLarge
        )
        try Task.checkCancellation()
        let task = Task.detached(priority: .userInitiated) {
            let parsed: LiveTVPlaylistImport
            if response.data.starts(with: [0x1f, 0x8b]) {
                throw LiveTVSourceImportError.guideWithoutPlaylist
            }
            let prefix = String(decoding: response.data.prefix(512), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if prefix.hasPrefix("<tv") || prefix.hasPrefix("<?xml") {
                throw LiveTVSourceImportError.guideWithoutPlaylist
            }
            do {
                parsed = try LiveTVPlaylistParser(baseURL: response.finalURL).parse(response.data)
            } catch LiveTVSourceImportError.streamManifest {
                guard let text = String(data: response.data, encoding: .utf8),
                      text.contains("#EXT-X-STREAM-INF:") || text.contains("#EXT-X-TARGETDURATION:") else {
                    throw LiveTVSourceImportError.invalidPlaylist
                }
                let digest = SHA256.hash(data: Data(response.finalURL.absoluteString.utf8))
                    .map { String(format: "%02x", $0) }.joined()
                parsed = LiveTVPlaylistImport(
                    channels: [LiveTVPrototypeChannel(
                        id: "iptv-direct-" + digest, number: 1, name: response.finalURL.host ?? "Live channel",
                        category: "Other", symbol: "tv", accent: 0, source: .iptv, tagline: "Live stream",
                        streamURL: response.finalURL
                    )], entryCount: 1, skippedEntryCount: 0
                )
            }
            return LiveTVPlaylistImport(
                channels: parsed.channels, entryCount: parsed.entryCount, skippedEntryCount: parsed.skippedEntryCount,
                declaredGuideURLs: parsed.declaredGuideURLs, permitsPersistence: response.permitsPersistence,
                originURL: parsed.originURL
            )
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    public func loadGuide(
        from url: URL,
        channels: [LiveTVPrototypeChannel],
        now: Date
    ) async throws -> LiveTVGuideImport {
        let response = try await download(
            from: url,
            maximumBytes: Self.guideLimit,
            tooLargeError: .guideTooLarge
        )
        try Task.checkCancellation()
        let task = Task.detached(priority: .userInitiated) {
            let parser = LiveTVXMLTVParser(provider: LiveTVGuideSource.provider(for: url))
            let data = response.data
            if data.starts(with: [0x1f, 0x8b]) {
                return try parser.parse(gzipData: data, channels: channels, now: now)
            }
            return try parser.parseXML(data: data, channels: channels, now: now)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    public func loadIndexedGuide(
        from url: URL, sourceID: String, channels: [LiveTVPrototypeChannel], now: Date,
        cache: LiveTVIndexedCache, lookbackDays: Int, lookaheadDays: Int
    ) async throws -> LiveTVGuideImport {
        let response = try await download(from: url, maximumBytes: Self.guideLimit, tooLargeError: .guideTooLarge)
        guard response.permitsPersistence else {
            let overrides = try await cache.mappingOverrides().filter { $0.value.guideSourceID == sourceID }
                .mapValues(\.guideChannelID)
            let task = Task.detached(priority: .userInitiated) {
                let parser = LiveTVXMLTVParser(provider: LiveTVGuideSource.provider(for: url))
                if response.data.starts(with: [0x1f, 0x8b]) {
                    return try parser.parse(
                        gzipData: response.data, channels: channels, now: now, overrides: overrides,
                        lookbackDays: lookbackDays, lookaheadDays: lookaheadDays
                    )
                }
                return try parser.parseXML(
                    data: response.data, channels: channels, now: now, overrides: overrides,
                    lookbackDays: lookbackDays, lookaheadDays: lookaheadDays
                )
            }
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try await cache.removeDownloadedGuide(sourceID: sourceID, sourceURL: url)
            return result
        }
        return try await cache.importGuide(
            data: response.data, sourceID: sourceID, channels: channels,
            provider: LiveTVGuideSource.provider(for: url), now: now,
            lookbackDays: lookbackDays, lookaheadDays: lookaheadDays, sourceURL: url
        )
    }

    private func download(
        from url: URL,
        maximumBytes: Int,
        tooLargeError: LiveTVSourceImportError
    ) async throws -> Response {
        guard let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil,
              url.user == nil,
              url.password == nil
        else {
            throw LiveTVSourceImportError.invalidResponse
        }

        if let cached = responses[url], cached.expires > Date() {
            guard cached.data.count <= maximumBytes else { throw tooLargeError }
            return cached
        }
        var lastFailure: LiveTVSourceImportError = .downloadFailed
        for attempt in 0..<3 {
          do {
            try Task.checkCancellation()
            var request = URLRequest(url: url)
            request.timeoutInterval = 120
            request.setValue("gzip, identity", forHTTPHeaderField: "Accept-Encoding")
            if let cached = responses[url] {
                request.setValue(cached.etag, forHTTPHeaderField: "If-None-Match")
                request.setValue(cached.modified, forHTTPHeaderField: "If-Modified-Since")
            }
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let response = response as? HTTPURLResponse else {
                throw LiveTVSourceImportError.invalidResponse
            }
            if response.statusCode == 304 {
                guard let cached = responses[url] else { throw LiveTVSourceImportError.invalidResponse }
                guard cached.data.count <= maximumBytes else { throw tooLargeError }
                let refreshed = responsePayload(data: cached.data, response: response, url: url, previous: cached)
                retainResponse(refreshed, for: url)
                return refreshed
            }
            if response.statusCode == 429 || (500...599).contains(response.statusCode) {
                bytes.task.cancel()
                guard attempt < 2 else {
                    throw response.statusCode == 429
                        ? LiveTVSourceImportError.tooManyRequests : LiveTVSourceImportError.temporarilyUnavailable
                }
                let suggested = response.value(forHTTPHeaderField: "Retry-After").flatMap {
                    Double($0) ?? httpDate($0)?.timeIntervalSinceNow
                }
                if let suggested, suggested.isFinite, suggested > 10 {
                    throw response.statusCode == 429
                        ? LiveTVSourceImportError.tooManyRequests : LiveTVSourceImportError.temporarilyUnavailable
                }
                let retryAfter = suggested.flatMap { $0.isFinite ? max(1, $0) : nil } ?? Double(1 << attempt)
                try await Task.sleep(for: .seconds(retryAfter))
                continue
            }
            if response.statusCode == 401 || response.statusCode == 403 {
                throw LiveTVSourceImportError.authenticationRequired
            }
            if (300...399).contains(response.statusCode) {
                throw LiveTVSourceImportError.redirectBlocked
            }
            guard (200...299).contains(response.statusCode) else {
                throw LiveTVSourceImportError.invalidResponse
            }
            if response.expectedContentLength > Int64(maximumBytes) {
                throw tooLargeError
            }
            var data = Data()
            data.reserveCapacity(
                min(maximumBytes, max(0, Int(response.expectedContentLength)))
            )
            for try await byte in bytes {
                if Task.isCancelled {
                    throw LiveTVSourceImportError.cancelled
                }
                guard data.count < maximumBytes else {
                    throw tooLargeError
                }
                data.append(byte)
            }
            let result = responsePayload(data: data, response: response, url: url)
            retainResponse(result, for: url)
            return result
          } catch is CancellationError {
            throw LiveTVSourceImportError.cancelled
          } catch let error as LiveTVSourceImportError {
            throw error
          } catch {
            lastFailure = .downloadFailed
            guard attempt < 2 else { throw lastFailure }
            try await Task.sleep(for: .seconds(1 << attempt))
          }
        }
        throw lastFailure
    }

    private func responsePayload(
        data: Data, response: HTTPURLResponse, url: URL, previous: Response? = nil
    ) -> Response {
        let directives = (response.value(forHTTPHeaderField: "Cache-Control") ?? previous?.cacheControl ?? "").lowercased()
        let maxAge = directives.split(separator: ",").compactMap { directive -> Double? in
            let parts = directive.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0] == "max-age" else { return nil }
            return Double(parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\" ")))
        }.first
        let received = Date()
        let date = response.value(forHTTPHeaderField: "Date").flatMap(httpDate) ?? received
        let expiresAge = response.value(forHTTPHeaderField: "Expires").flatMap(httpDate)?.timeIntervalSince(date) ?? 0
        let age = response.value(forHTTPHeaderField: "Age").flatMap(Double.init) ?? 0
        let effectiveMaxAge = maxAge ?? expiresAge
        let currentAge = max(max(0, age), received.timeIntervalSince(date))
        let lifetime = effectiveMaxAge.isFinite && age.isFinite
            ? min(max(0, effectiveMaxAge - currentAge), 86_400) : 0
        return Response(
            data: data, finalURL: response.url ?? previous?.finalURL ?? url,
            etag: response.value(forHTTPHeaderField: "ETag") ?? previous?.etag,
            modified: response.value(forHTTPHeaderField: "Last-Modified") ?? previous?.modified,
            expires: received.addingTimeInterval(directives.contains("no-cache") ? 0 : lifetime),
            permitsPersistence: !directives.contains("no-store"), cacheControl: directives
        )
    }

    private func retainResponse(_ result: Response, for url: URL) {
        guard result.permitsPersistence else {
            responses.removeValue(forKey: url)
            return
        }
        let maximumBytes = 64 * 1_024 * 1_024
        let retainedBytes = responses.values.reduce(0) { $0 + $1.data.count } - (responses[url]?.data.count ?? 0)
        if retainedBytes + result.data.count > maximumBytes || (responses[url] == nil && responses.count >= 256) {
            responses.removeAll(keepingCapacity: true)
        }
        if result.data.count <= maximumBytes { responses[url] = result }
    }

    private func httpDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }
}

public enum LiveTVSourceOriginPolicy {
    public static func permits(_ candidate: URL, from origin: URL) -> Bool {
        guard candidate.user == nil, candidate.password == nil,
              let candidateHost = candidate.host?.lowercased(),
              candidateHost == origin.host?.lowercased() else { return false }
        let sourceScheme = origin.scheme?.lowercased()
        let targetScheme = candidate.scheme?.lowercased()
        let sameOrigin = sourceScheme == targetScheme && port(candidate) == port(origin)
        let upgrade = sourceScheme == "http" && targetScheme == "https"
            && port(origin) == 80 && port(candidate) == 443
        return sameOrigin || upgrade
    }

    private static func port(_ url: URL) -> Int { url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80) }
}

private final class LiveTVSourceRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var redirectsByTask: [Int: Int] = [:]

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        lock.lock()
        let count = redirectsByTask[task.taskIdentifier, default: 0] + 1
        redirectsByTask[task.taskIdentifier] = count
        lock.unlock()
        guard let original = task.originalRequest?.url, let next = request.url,
              count <= 5,
              LiveTVSourceOriginPolicy.permits(next, from: original),
              task.countOfBytesReceived <= Int64(LiveTVXMLTVParser.maximumCompressedBytes) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        lock.lock()
        redirectsByTask[task.taskIdentifier] = nil
        lock.unlock()
    }
}
#endif
