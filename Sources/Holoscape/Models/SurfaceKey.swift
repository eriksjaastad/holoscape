import Foundation

/// Compile-time-typed identifier for every chrome surface the SkinContext
/// can resolve. Views reference surfaces by enum case so rename drift is
/// caught by the compiler, not at runtime.
///
/// Raw values match the hierarchical dot-separated keys in `skin.json`
/// manifests (e.g., `"tabBar.tab.active"`). Two generations of surfaces:
///
/// - **v2 (chrome-skinning)**: 23 cases covering container / row / state
///   surfaces for every migrated chrome view, per the v2 surface catalog
///   in `docs/skins/06-chrome-skinning.md` §6.
/// - **v3 (Amplify)**: 13 additional cases for interactive sprite states
///   (`tabBar.tab.hover/pressed`, `sidebar.row.pressed`, launcher button
///   states) and Reader Mode + window-level surfaces. Unknown keys in a
///   manifest are ignored at decode time so v3 manifests load cleanly on
///   older builds.
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

    // MARK: - Amplify (v3) additions

    // Tab bar interactive states (sprite sheets)
    case tabBarTabHover                   = "tabBar.tab.hover"
    case tabBarTabPressed                 = "tabBar.tab.pressed"

    // Sidebar interactive state
    case sidebarRowPressed                = "sidebar.row.pressed"

    // Session launcher button states
    case sessionLauncherButtonNormal      = "sessionLauncher.button.normal"
    case sessionLauncherButtonHover       = "sessionLauncher.button.hover"
    case sessionLauncherButtonPressed     = "sessionLauncher.button.pressed"

    // Reader Mode panel surfaces
    case readerPanelTitleBar              = "readerPanel.titleBar"
    case readerPanelBackground            = "readerPanel.background"
    case readerPanelCloseButtonNormal     = "readerPanel.closeButton.normal"
    case readerPanelCloseButtonHover      = "readerPanel.closeButton.hover"
    case readerPanelCloseButtonPressed    = "readerPanel.closeButton.pressed"

    // Window-level Amplify surfaces
    case windowShape                      = "window.shape"
    case windowDragHandle                 = "window.dragHandle"
}
