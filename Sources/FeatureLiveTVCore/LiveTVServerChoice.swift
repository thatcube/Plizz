#if DEBUG
import Foundation

public struct LiveTVServerChoice: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let userName: String
    public let kind: LiveTVPrototypeSource

    public init(id: String, name: String, userName: String, kind: LiveTVPrototypeSource) {
        self.id = id
        self.name = name
        self.userName = userName
        self.kind = kind
    }
}
#endif
