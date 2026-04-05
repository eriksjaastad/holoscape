import Foundation

struct ElapsedTimeFormatter {
    /// Format elapsed time since activation as "Xh Ym" or "Ym".
    /// Returns nil if activatedAt is nil.
    static func format(since activatedAt: Date?) -> String? {
        guard let activatedAt else { return nil }
        let elapsed = Int(Date().timeIntervalSince(activatedAt))
        guard elapsed >= 0 else { return nil }
        let minutes = elapsed / 60
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        if hours > 0 {
            return "\(hours)h \(remainingMinutes)m"
        }
        return "\(remainingMinutes)m"
    }
}
