import Foundation

struct GroupChatMessage: Codable, Sendable {
    let sender: String
    let body: String
    let timestamp: Date

    func formatted() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        let timeString = formatter.string(from: timestamp)
        return "[\(timeString)] \(sender): \(body)"
    }
}
