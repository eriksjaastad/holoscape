import Foundation

/// Compile-time-typed identifier for every chrome surface the SkinContext
/// can resolve. Views reference surfaces by enum case so rename drift is
/// caught by the compiler, not at runtime.
///
/// Raw values match the hierarchical dot-separated keys in `skin.json`
/// manifests (e.g., `"tabBar.tab.active"`). The 23 cases correspond to
/// the surface catalog in `docs/skins/06-chrome-skinning.md` §6.
enum SurfaceKey: String, CaseIterable, Codable, Sendable {
    // Window
    case windowTitleBar           = "window.titleBar"
    case windowBackground         = "window.background"

    // Tab bar
    case tabBarContainer          = "tabBar.container"
    case tabBarTabActive          = "tabBar.tab.active"
    case tabBarTabIdle            = "tabBar.tab.idle"
    case tabBarTabPermission      = "tabBar.tab.permission"
    case tabBarTabNormal          = "tabBar.tab.normal"
    case tabBarTabUnreadMarker    = "tabBar.tab.unreadMarker"

    // Sidebar
    case sidebarContainer         = "sidebar.container"
    case sidebarRowNormal         = "sidebar.row.normal"
    case sidebarRowSelected       = "sidebar.row.selected"
    case sidebarRowHover          = "sidebar.row.hover"
    case sidebarRowIndicator      = "sidebar.row.indicator"
    case sidebarSectionHeader     = "sidebar.sectionHeader"

    // Input box
    case inputBoxContainer        = "inputBox.container"
    case inputBoxField            = "inputBox.field"
    case inputBoxPlaceholder      = "inputBox.placeholder"

    // Session launcher
    case sessionLauncherContainer = "sessionLauncher.container"
    case sessionLauncherRow       = "sessionLauncher.row"

    // Split pane + terminal
    case splitPaneDivider         = "splitPane.divider"
    case terminalContainerPadding = "terminalContainer.padding"

    // Settings + dialogs
    case settingsPanel            = "settings.panel"
    case dialogContainer          = "dialog.container"
}
