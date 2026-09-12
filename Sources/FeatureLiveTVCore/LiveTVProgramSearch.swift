#if DEBUG
import Foundation

struct LiveTVProgramSearchMatcher {
    let tokens: [String]

    init(_ query: String) {
        tokens = Self.words(String(query.prefix(2_048))).prefix(12).map { String($0.prefix(128)) }
    }

    func matches(_ title: String) -> Bool {
        guard !tokens.isEmpty else { return false }
        let words = Self.words(title)
        return tokens.allSatisfy { token in words.contains { $0.hasPrefix(token) } }
    }

    private static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}

/// Bounded merge for already-cached native programmes; never sort/materialize a
/// second full catalogue on the main actor just to display the first 100 matches.
struct LiveTVProgramSearchResults {
    private let limit: Int
    private var heap: [LiveTVPrototypeProgram] = []
    private var ids: Set<String> = []

    init(limit: Int) { self.limit = min(max(0, limit), 500) }

    mutating func insert(_ program: LiveTVPrototypeProgram) {
        guard limit > 0, !ids.contains(program.id) else { return }
        if heap.count < limit {
            heap.append(program)
            ids.insert(program.id)
            var child = heap.count - 1
            while child > 0 {
                let parent = (child - 1) / 2
                guard Self.precedes(heap[parent], heap[child]) else { break }
                heap.swapAt(parent, child)
                child = parent
            }
        } else {
            guard Self.precedes(program, heap[0]) else { return }
            ids.remove(heap[0].id)
            heap[0] = program
            ids.insert(program.id)
            var parent = 0
            while parent * 2 + 1 < heap.count {
                var child = parent * 2 + 1
                if child + 1 < heap.count, Self.precedes(heap[child], heap[child + 1]) { child += 1 }
                guard Self.precedes(heap[parent], heap[child]) else { break }
                heap.swapAt(parent, child)
                parent = child
            }
        }
    }

    var sorted: [LiveTVPrototypeProgram] { heap.sorted(by: Self.precedes) }

    private static func precedes(_ lhs: LiveTVPrototypeProgram, _ rhs: LiveTVPrototypeProgram) -> Bool {
        lhs.start == rhs.start ? lhs.id < rhs.id : lhs.start < rhs.start
    }
}
#endif
