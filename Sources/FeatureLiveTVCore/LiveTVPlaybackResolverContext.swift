#if DEBUG
import CoreModels
import Foundation

/// Retained preparations follow newly connected accounts without rebuilding
/// unrelated IPTV players or capturing the standalone entry's empty resolver.
@MainActor
public final class LiveTVPlaybackResolverContext: AuthenticatedHTTPResourceResolving {
    private var serverProviderResolver: LiveTVServerProviderResolver
    private var authenticatedHTTPResolver: (any AuthenticatedHTTPResourceResolving)?
    private var generation = UUID()

    public init(
        serverProviderResolver: @escaping LiveTVServerProviderResolver,
        authenticatedHTTPResolver: (any AuthenticatedHTTPResourceResolving)?
    ) {
        self.serverProviderResolver = serverProviderResolver
        self.authenticatedHTTPResolver = authenticatedHTTPResolver
    }

    public func update(
        serverProviderResolver: @escaping LiveTVServerProviderResolver,
        authenticatedHTTPResolver: (any AuthenticatedHTTPResourceResolving)?
    ) {
        generation = UUID()
        self.serverProviderResolver = serverProviderResolver
        self.authenticatedHTTPResolver = authenticatedHTTPResolver
    }

    public func provider(for accountID: String) -> LiveTVAuthorizedServerProvider? {
        serverProviderResolver(accountID)
    }

    public func resolve(_ locator: AuthenticatedHTTPPlaybackLocator) async throws -> URL {
        try Task.checkCancellation()
        let requestedGeneration = generation
        guard let authenticatedHTTPResolver else {
            throw LiveTVPlaybackPreparationError.resolverUnavailable
        }
        let url = try await authenticatedHTTPResolver.resolve(locator)
        try Task.checkCancellation()
        guard generation == requestedGeneration else {
            throw LiveTVPlaybackPreparationError.authorizationChanged
        }
        return url
    }
}
#endif
