#if DEBUG
import CoreModels
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct LiveTVChannelScanLimits: Equatable, Sendable {
    public let concurrentChannels: Int
    public let requestsPerHost: Int
    public let requestTimeout: TimeInterval
    public let channelTimeout: TimeInterval
    public let manifestBytes: Int
    public let mediaBytes: Int
    public let requestsPerChannel: Int
    public let redirects: Int
    public let retryDelay: Duration

    public init(
        concurrentChannels: Int = 4, requestsPerHost: Int = 2,
        requestTimeout: TimeInterval = 8, channelTimeout: TimeInterval = 30,
        manifestBytes: Int = 256 * 1_024, mediaBytes: Int = 4_096,
        requestsPerChannel: Int = 12, redirects: Int = 3,
        retryDelay: Duration = .milliseconds(300)
    ) {
        self.concurrentChannels = min(8, max(1, concurrentChannels))
        self.requestsPerHost = min(2, max(1, requestsPerHost))
        self.requestTimeout = requestTimeout.isFinite ? min(15, max(0.1, requestTimeout)) : 8
        self.channelTimeout = channelTimeout.isFinite ? min(60, max(0.1, channelTimeout)) : 30
        self.manifestBytes = min(512 * 1_024, max(1_024, manifestBytes))
        self.mediaBytes = min(16 * 1_024, max(564, mediaBytes))
        self.requestsPerChannel = min(20, max(2, requestsPerChannel))
        self.redirects = min(5, max(0, redirects))
        self.retryDelay = min(.seconds(2), max(.zero, retryDelay))
    }
}

/// All additional origins must come from user approval/source policy, never
/// from a manifest. Credentials are only attached to their original origin.
public struct LiveTVScanOriginPolicy: Sendable {
    public let rootOrigin: NetworkOrigin
    public let allowedOrigins: Set<NetworkOrigin>
    public let headers: [String: String]
    public let allowsHTTP: Bool
    public let allowsLocalNetwork: Bool

    public init(
        streamURL: URL, headers: [String: String] = [:],
        additionalAllowedOrigins: Set<NetworkOrigin> = [], allowsHTTP: Bool = false,
        allowsLocalNetwork: Bool = false
    ) throws {
        rootOrigin = try Self.origin(streamURL)
        var allowed = additionalAllowedOrigins.union([rootOrigin])
        if rootOrigin.scheme == "http", rootOrigin.port == 80 {
            allowed.insert(try NetworkOrigin(scheme: "https", host: rootOrigin.host))
        }
        self.allowedOrigins = allowed
        self.allowsHTTP = allowsHTTP
        self.allowsLocalNetwork = allowsLocalNetwork
        self.headers = try Self.validatedHeaders(headers)
        guard permits(streamURL) else { throw LiveTVScanTransportError.unsafeOrigin }
    }

    public func permits(_ url: URL) -> Bool {
        guard let origin = try? Self.origin(url),
              allowsHTTP || origin.scheme == "https",
              allowsLocalNetwork || !Self.isLocalHost(origin.host) else { return false }
        return allowedOrigins.contains(origin)
    }

    func requestHeaders(for url: URL) -> [String: String] {
        (try? Self.origin(url)) == rootOrigin ? headers : [:]
    }

    static func origin(_ url: URL) throws -> NetworkOrigin {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil, components.password == nil, components.fragment == nil,
              let scheme = components.scheme, let host = components.host else {
            throw LiveTVScanTransportError.unsafeOrigin
        }
        do { return try NetworkOrigin(scheme: scheme, host: host, port: components.port) }
        catch { throw LiveTVScanTransportError.unsafeOrigin }
    }

    private static func validatedHeaders(_ headers: [String: String]) throws -> [String: String] {
        let allowed: Set<String> = ["authorization", "cookie", "user-agent", "referer", "origin"]
        var names = Set<String>()
        guard headers.count <= allowed.count else { throw LiveTVScanTransportError.unsafeOrigin }
        for (name, value) in headers {
            guard allowed.contains(name.lowercased()), names.insert(name.lowercased()).inserted,
                  value.utf8.count <= 8_192,
                  value.rangeOfCharacter(from: .controlCharacters) == nil else {
                throw LiveTVScanTransportError.unsafeOrigin
            }
        }
        return headers
    }

    private static func isLocalHost(_ value: String) -> Bool {
        let host = value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") ||
            host == "::1" || host == "::" || host.hasPrefix("fc") && host.contains(":") ||
            host.hasPrefix("fd") && host.contains(":") || host.hasPrefix("fe80:") ||
            host.hasPrefix("::ffff:") || host.contains("%") { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4 {
            return parts[0] == 0 || parts[0] == 10 || parts[0] == 127 ||
                parts[0] == 169 && parts[1] == 254 ||
                parts[0] == 172 && (16...31).contains(parts[1]) ||
                parts[0] == 192 && parts[1] == 168 ||
                parts[0] == 100 && (64...127).contains(parts[1]) || parts[0] >= 224
        }
        return !host.contains(".") && !host.contains(":")
    }
}

extension LiveTVScanOriginPolicy: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "LiveTVScanOriginPolicy" }
    public var debugDescription: String { description }
}

public enum LiveTVScanTransportError: Error, Equatable, Sendable {
    case unsafeOrigin, responseLimit, requestLimit, timedOut, networkUnavailable, invalidResponse
}

public struct LiveTVScanHTTPResponse: Sendable {
    public let statusCode: Int
    public let data: Data
    public let location: String?
    public let wasTruncated: Bool

    public init(statusCode: Int, data: Data = Data(), location: String? = nil, wasTruncated: Bool = false) {
        self.statusCode = statusCode
        self.data = data
        self.location = location
        self.wasTruncated = wasTruncated
    }

}

extension LiveTVScanHTTPResponse: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "LiveTVScanHTTPResponse(status: \(statusCode), bytes: \(data.count))" }
    public var debugDescription: String { description }
}

/// Implementations must not follow redirects, exceed the byte/time limits, or
/// consult a playback engine. Test fixtures inject this boundary.
public protocol LiveTVScanHTTPTransport: Sendable {
    func fetch(_ request: URLRequest, maximumBytes: Int, acceptsPrefix: Bool) async throws -> LiveTVScanHTTPResponse
}

public final class LiveTVScanURLSessionTransport: LiveTVScanHTTPTransport, @unchecked Sendable {
    private let session: URLSession
    private let permits: LiveTVScanRequestPermits

    public init(limits: LiveTVChannelScanLimits = .init()) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = limits.requestTimeout
        configuration.timeoutIntervalForResource = limits.requestTimeout
        configuration.httpMaximumConnectionsPerHost = limits.requestsPerHost
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        session = URLSession(configuration: configuration)
        permits = LiveTVScanRequestPermits(maximum: limits.concurrentChannels, perHost: limits.requestsPerHost)
    }

    deinit { session.invalidateAndCancel() }

    public func fetch(
        _ request: URLRequest, maximumBytes: Int, acceptsPrefix: Bool
    ) async throws -> LiveTVScanHTTPResponse {
        guard let url = request.url else { throw LiveTVScanTransportError.unsafeOrigin }
        let origin = try LiveTVScanOriginPolicy.origin(url)
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await permits.acquire(id: id, host: origin.host)
            do {
                try Task.checkCancellation()
                let value = try await download(request, maximumBytes: maximumBytes, acceptsPrefix: acceptsPrefix)
                await permits.release(id: id)
                return value
            } catch {
                await permits.release(id: id)
                throw error
            }
        } onCancel: {
            Task { await self.permits.cancel(id: id) }
        }
    }

    private func download(
        _ request: URLRequest, maximumBytes: Int, acceptsPrefix: Bool
    ) async throws -> LiveTVScanHTTPResponse {
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: LiveTVScanNoRedirectDelegate())
            defer { bytes.task.cancel() }
            guard let response = response as? HTTPURLResponse else {
                throw LiveTVScanTransportError.invalidResponse
            }
            guard (200...299).contains(response.statusCode) else {
                return LiveTVScanHTTPResponse(
                    statusCode: response.statusCode,
                    location: response.value(forHTTPHeaderField: "Location")
                )
            }
            if !acceptsPrefix && response.expectedContentLength > Int64(maximumBytes) {
                throw LiveTVScanTransportError.responseLimit
            }
            var data = Data()
            data.reserveCapacity(maximumBytes)
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < maximumBytes else {
                    if acceptsPrefix {
                        return LiveTVScanHTTPResponse(statusCode: response.statusCode, data: data, wasTruncated: true)
                    }
                    throw LiveTVScanTransportError.responseLimit
                }
                data.append(byte)
                if acceptsPrefix && data.count == maximumBytes {
                    return LiveTVScanHTTPResponse(statusCode: response.statusCode, data: data, wasTruncated: true)
                }
            }
            return LiveTVScanHTTPResponse(statusCode: response.statusCode, data: data)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw error.code == .timedOut ? LiveTVScanTransportError.timedOut : .networkUnavailable
        } catch let error as LiveTVScanTransportError {
            throw error
        } catch {
            throw LiveTVScanTransportError.networkUnavailable
        }
    }
}

private final class LiveTVScanNoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// Host limits apply to segment/variant/redirect hosts too, not just lineup URLs.
actor LiveTVScanRequestPermits {
    private struct Waiter {
        let id: UUID
        let host: String
        let continuation: CheckedContinuation<Void, any Error>
    }
    private let maximum: Int
    private let perHost: Int
    private var active: [UUID: String] = [:]
    private var waiters: [Waiter] = []

    init(maximum: Int, perHost: Int) {
        self.maximum = maximum
        self.perHost = perHost
    }

    func acquire(id: UUID, host: String) async throws {
        try Task.checkCancellation()
        if available(host) {
            active[id] = host
            return
        }
        try await withCheckedThrowingContinuation { continuation in
            waiters.append(Waiter(id: id, host: host, continuation: continuation))
        }
    }

    func cancel(id: UUID) {
        if let index = waiters.firstIndex(where: { $0.id == id }) {
            waiters.remove(at: index).continuation.resume(throwing: CancellationError())
        }
    }

    func release(id: UUID) {
        active.removeValue(forKey: id)
        var index = 0
        while index < waiters.count {
            if available(waiters[index].host) {
                let waiter = waiters.remove(at: index)
                active[waiter.id] = waiter.host
                waiter.continuation.resume()
            } else {
                index += 1
            }
        }
    }

    private func available(_ host: String) -> Bool {
        active.count < maximum && active.values.filter { $0 == host }.count < perHost
    }
}
#endif
