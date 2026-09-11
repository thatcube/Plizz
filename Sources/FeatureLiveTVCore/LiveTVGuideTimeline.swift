#if DEBUG
import Foundation

public struct LiveTVGuideSlot: Identifiable, Equatable, Sendable {
    public let program: LiveTVPrototypeProgram?
    public let start: Date
    public let end: Date

    public var id: String {
        "\(program?.id ?? "gap"):\(start.timeIntervalSince1970)"
    }
}

public enum LiveTVGuideTimeline {
    /// Clip overlaps and retain empty intervals so every row shares the same clock.
    public static func slots(
        programs: [LiveTVPrototypeProgram],
        from start: Date,
        to end: Date
    ) -> [LiveTVGuideSlot] {
        guard start < end else { return [] }
        var cursor = start
        var result: [LiveTVGuideSlot] = []
        let ordered = programs.sorted {
            $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start
        }
        for program in ordered where program.start < end && program.end > cursor {
            let clippedStart = max(cursor, program.start)
            let clippedEnd = min(end, program.end)
            guard clippedStart < clippedEnd else { continue }
            if clippedStart > cursor {
                result.append(LiveTVGuideSlot(program: nil, start: cursor, end: clippedStart))
            }
            result.append(LiveTVGuideSlot(program: program, start: clippedStart, end: clippedEnd))
            cursor = clippedEnd
        }
        if cursor < end {
            result.append(LiveTVGuideSlot(program: nil, start: cursor, end: end))
        }
        return result
    }
}
#endif
