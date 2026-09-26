import Foundation

/// Pure, AppKit-free formatting helpers for the scrollback maintenance settings
/// surface. Kept in the Services layer so the unit target can exercise the
/// formatting deterministically without constructing any AppKit views.
enum ScrollbackMaintenanceFormatting {

    /// Formats a byte count as a short human-readable size, e.g. "512 B",
    /// "1.5 KB", "3.2 MB". Uses integer arithmetic for the one-decimal rounding
    /// so the output is locale- and formatter-independent (deterministic in
    /// tests and stable across users' locales).
    static func byteSize(_ bytes: Int) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        let clamped = max(0, bytes)

        var value = Double(clamped)
        var unitIndex = 0
        while value >= 1024 && unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }

        if unitIndex == 0 {
            return "\(clamped) B"
        }

        let scaled = Int((value * 10).rounded())
        let whole = scaled / 10
        let tenths = scaled % 10
        if tenths == 0 {
            return "\(whole) \(units[unitIndex])"
        }
        return "\(whole).\(tenths) \(units[unitIndex])"
    }

    /// Formats a last-modified date for display, or an em dash when the date is
    /// unavailable (the store treats `modifiedAt` as optional). The `timeZone`
    /// parameter defaults to the user's current time zone but is injectable so
    /// tests can pin it for deterministic assertions.
    static func modifiedAt(_ date: Date?, timeZone: TimeZone = .current) -> String {
        guard let date else { return "—" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
