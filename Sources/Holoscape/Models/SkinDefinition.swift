import Foundation

struct SkinDefinition: Codable, Equatable, Sendable {
    var windowBackground: String?
    var titleBarBackground: String?
    var sidebarBackground: String?
    var tabActiveColor: String?
    var tabInactiveColor: String?
    var textForeground: String?
    var ansiColors: [String]?           // 16 hex strings
    var windowBackgroundImage: String?   // relative path to PNG
    var sidebarBackgroundImage: String?  // relative path to PNG
    var tabBarBackgroundImage: String?   // relative path to PNG
}
