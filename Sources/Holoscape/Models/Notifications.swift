import Foundation

/// Central namespace for Holoscape-internal `Notification.Name` values.
/// Prefix names with `holoscape.` so they don't collide with AppKit or
/// third-party notifications.
extension Notification.Name {
    /// Posted by `DensityModeManager` after `setMode` transitions to a new
    /// mode. `userInfo["previous"]` and `userInfo["current"]` carry the
    /// `DensityModeManager.Mode.rawValue` strings for the transition.
    static let densityModeDidChange = Notification.Name("holoscape.densityModeDidChange")

    /// Posted whenever the active SkinContext changes (skin load, skin
    /// unload, hot reload). Chrome views observing this re-run their
    /// `layout()` so they pick up the new surface descriptors.
    static let skinDidChange = Notification.Name("holoscape.skinDidChange")
}
