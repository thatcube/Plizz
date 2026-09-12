import Foundation

public enum WatchMutationAuthorizationError: Error, Equatable, Sendable {
    case denied, capabilityUnavailable, unsupportedApplier, superseded
}

/// A persisted requirement, not a persisted grant. Decoding cannot recreate its
/// runtime validator. Capture application owners weakly in that validator.
public struct WatchMutationAuthorization: Codable, Hashable, Sendable {
    public let id: UUID
    private let capability: Capability?

    init(validator: @escaping @Sendable () async -> Bool) {
        id = UUID()
        capability = Capability(validator: validator)
    }

    private enum CodingKeys: String, CodingKey { case version, id }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(Int.self, forKey: .version) == 1 else {
            throw DecodingError.dataCorruptedError(
                forKey: .version, in: container, debugDescription: "Unsupported authorization requirement"
            )
        }
        id = try container.decode(UUID.self, forKey: .id)
        capability = nil
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(1, forKey: .version)
        try container.encode(id, forKey: .id)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }

    func require() async throws {
        try Task.checkCancellation()
        guard let capability else { throw WatchMutationAuthorizationError.capabilityUnavailable }
        let allowed = await capability.allows()
        try Task.checkCancellation()
        guard allowed else { throw WatchMutationAuthorizationError.denied }
    }

    func allows() async -> Bool {
        guard let capability else { return false }
        return await capability.allows()
    }

    func retire() { capability?.retire() }

    private final class Capability: @unchecked Sendable {
        private let lock = NSLock()
        private var validator: (@Sendable () async -> Bool)?

        init(validator: @escaping @Sendable () async -> Bool) { self.validator = validator }

        func allows() async -> Bool {
            guard let check = lock.withLock({ validator }) else { return false }
            guard await check() else {
                retire()
                return false
            }
            return lock.withLock { validator != nil }
        }

        func retire() { lock.withLock { validator = nil } }
    }
}

/// The reconciler binds this to one queued intent. An enforcing applier checks
/// it again after its own awaits, immediately before calling a provider/tracker.
/// It cannot retract requests that have already been dispatched.
public struct WatchMutationDeliveryAuthorization: Sendable {
    @TaskLocal public static var current: WatchMutationDeliveryAuthorization?
    private let validator: @Sendable () async throws -> Void

    init(validator: @escaping @Sendable () async throws -> Void) { self.validator = validator }

    public static func check() async throws {
        if let current { try await current.validator() }
    }

    /// Nonthrowing read-only expansion APIs represent denial as inconclusive;
    /// the reconciler's next throwing check prevents any subsequent writes.
    public static func allowsExpansion() async -> Bool {
        do {
            try await check()
            return true
        } catch {
            return false
        }
    }
}

/// Opt-in contract: implementations recheck the task-local delivery requirement
/// after every internal suspension preceding another provider/tracker operation.
/// Unmarked appliers cannot receive guarded mutations.
public protocol WatchMutationAuthorizationEnforcing: WatchMutationApplying {}
