import Foundation

enum ChannelDisplayLabelResolver {
    @MainActor
    static func labels(for channels: [any ChannelController]) -> [UUID: String] {
        var seenCounts: [String: Int] = [:]
        var resolved: [UUID: String] = [:]

        for channel in channels {
            let base = normalizedDisplayBaseLabel(channel.displayBaseLabel)
            let key = base.lowercased()
            let nextCount = seenCounts[key, default: 0] + 1
            seenCounts[key] = nextCount
            resolved[channel.channelId] = nextCount == 1 ? base : "\(base) \(nextCount)"
        }

        return resolved
    }

    private static func normalizedDisplayBaseLabel(_ label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : trimmed
    }
}
