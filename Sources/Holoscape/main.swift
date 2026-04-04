import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.regular)

// Disable state restoration — Holoscape manages its own channel persistence
UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")

let delegate = AppDelegate()
app.delegate = delegate
app.run()
