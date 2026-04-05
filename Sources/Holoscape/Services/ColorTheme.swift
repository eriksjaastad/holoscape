import Foundation

struct ColorTheme: Equatable, Sendable {
    let name: String
    let background: String
    let foreground: String
    let ansiColors: [String]  // 16 hex strings: 8 standard + 8 bright

    func apply(to config: AppearanceConfig, overrides: [String: String]?) -> AppearanceConfig {
        var result = config
        result.backgroundColor = overrides?["backgroundColor"] ?? background
        var colors: [String: String] = [:]
        let names = [
            "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white",
            "brightBlack", "brightRed", "brightGreen", "brightYellow",
            "brightBlue", "brightMagenta", "brightCyan", "brightWhite",
        ]
        for (i, name) in names.enumerated() where i < ansiColors.count {
            colors[name] = overrides?[name] ?? ansiColors[i]
        }
        colors["foreground"] = overrides?["foreground"] ?? foreground
        result.ansiColors = colors
        return result
    }

    // MARK: - Built-in Themes

    static let dark = ColorTheme(
        name: "Dark",
        background: "#1a1a2e",
        foreground: "#e0e0e0",
        ansiColors: [
            "#1a1a2e", "#ff5555", "#50fa7b", "#f1fa8c",
            "#bd93f9", "#ff79c6", "#8be9fd", "#f8f8f2",
            "#6272a4", "#ff6e6e", "#69ff94", "#ffffa5",
            "#d6acff", "#ff92df", "#a4edff", "#ffffff",
        ]
    )

    static let monokai = ColorTheme(
        name: "Monokai",
        background: "#272822",
        foreground: "#f8f8f2",
        ansiColors: [
            "#272822", "#f92672", "#a6e22e", "#f4bf75",
            "#66d9ef", "#ae81ff", "#a1efe4", "#f8f8f2",
            "#75715e", "#f92672", "#a6e22e", "#f4bf75",
            "#66d9ef", "#ae81ff", "#a1efe4", "#f9f8f5",
        ]
    )

    static let solarizedDark = ColorTheme(
        name: "Solarized Dark",
        background: "#002b36",
        foreground: "#839496",
        ansiColors: [
            "#073642", "#dc322f", "#859900", "#b58900",
            "#268bd2", "#d33682", "#2aa198", "#eee8d5",
            "#002b36", "#cb4b16", "#586e75", "#657b83",
            "#839496", "#6c71c4", "#93a1a1", "#fdf6e3",
        ]
    )

    static let solarizedLight = ColorTheme(
        name: "Solarized Light",
        background: "#fdf6e3",
        foreground: "#657b83",
        ansiColors: [
            "#073642", "#dc322f", "#859900", "#b58900",
            "#268bd2", "#d33682", "#2aa198", "#eee8d5",
            "#002b36", "#cb4b16", "#586e75", "#657b83",
            "#839496", "#6c71c4", "#93a1a1", "#fdf6e3",
        ]
    )

    static let dracula = ColorTheme(
        name: "Dracula",
        background: "#282a36",
        foreground: "#f8f8f2",
        ansiColors: [
            "#21222c", "#ff5555", "#50fa7b", "#f1fa8c",
            "#bd93f9", "#ff79c6", "#8be9fd", "#f8f8f2",
            "#6272a4", "#ff6e6e", "#69ff94", "#ffffa5",
            "#d6acff", "#ff92df", "#a4edff", "#ffffff",
        ]
    )

    static let nord = ColorTheme(
        name: "Nord",
        background: "#2e3440",
        foreground: "#d8dee9",
        ansiColors: [
            "#3b4252", "#bf616a", "#a3be8c", "#ebcb8b",
            "#81a1c1", "#b48ead", "#88c0d0", "#e5e9f0",
            "#4c566a", "#bf616a", "#a3be8c", "#ebcb8b",
            "#81a1c1", "#b48ead", "#8fbcbb", "#eceff4",
        ]
    )

    static let allThemes: [ColorTheme] = [dark, monokai, solarizedDark, solarizedLight, dracula, nord]

    static func named(_ name: String) -> ColorTheme? {
        allThemes.first { $0.name == name }
    }
}
