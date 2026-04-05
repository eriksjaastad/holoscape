import Foundation

struct TimestampInjector {
    private static let prefixFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    /// Format a timestamp prefix for terminal output lines: `[HH:MM:SS] `
    static func prefix(for date: Date = Date()) -> String {
        return "[\(prefixFormatter.string(from: date))] "
    }

    /// Transform a group chat timestamp from `[H:MM AM/PM]` to `[H:MM:SS AM/PM]`
    /// by inserting seconds precision.
    static func addSeconds(to formattedMessage: String, date: Date = Date()) -> String {
        let secondsFormatter = DateFormatter()
        secondsFormatter.dateFormat = "ss"
        let seconds = secondsFormatter.string(from: date)

        // Match pattern like [12:34 PM] or [1:05 AM]
        // Replace with [12:34:SS PM] or [1:05:SS AM]
        guard let range = formattedMessage.range(of: #"\[\d{1,2}:\d{2} [AP]M\]"#, options: .regularExpression) else {
            return formattedMessage
        }

        let matched = String(formattedMessage[range])
        // Insert :SS before the space before AM/PM
        let replaced = matched.replacingOccurrences(
            of: #"(\d{2}) ([AP]M)"#,
            with: "$1:\(seconds) $2",
            options: .regularExpression
        )
        return formattedMessage.replacingCharacters(in: range, with: replaced)
    }
}
