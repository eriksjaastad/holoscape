import Foundation

class CommandHistory: @unchecked Sendable {
    private var entries: [String] = []
    private var cursor: Int = -1
    private let maxEntries: Int

    init(maxEntries: Int = 100) {
        self.maxEntries = maxEntries
    }

    func add(_ command: String) {
        guard !command.isEmpty else { return }
        entries.append(command)
        if entries.count > maxEntries {
            entries.removeFirst()
        }
        cursor = entries.count
    }

    func previous() -> String? {
        guard !entries.isEmpty else { return nil }
        if cursor > 0 {
            cursor -= 1
        }
        return entries[cursor]
    }

    func next() -> String? {
        guard !entries.isEmpty else { return nil }
        if cursor < entries.count - 1 {
            cursor += 1
            return entries[cursor]
        }
        cursor = entries.count
        return nil
    }

    func reset() {
        cursor = entries.count
    }

    var count: Int { entries.count }
}
