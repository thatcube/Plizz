import Foundation

/// Runtime playback input. Network credentials are never serialized or printed.
public enum LiveChannelInput: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    case stream(url: URL, httpHeaders: [String: String])
    case libraryChannel(id: UUID, authorizationID: String)

    public var description: String {
        switch self {
        case .stream: "LiveChannelInput(stream: redacted)"
        case .libraryChannel(let id, _): "LiveChannelInput(libraryChannel: \(id))"
        }
    }

    public var debugDescription: String { description }
}

public enum LiveChannelInputError: Error, Equatable, Sendable {
    case unsupportedSource

    public var message: LocalizedStringResource {
        "This player can't play this channel source."
    }
}
