import AppKit
import Foundation

if try BrokerSessionHostCommand(arguments: CommandLine.arguments).runIfRequested() {
    Foundation.exit(EXIT_SUCCESS)
}

do {
    try ConfigService.validateAutomatedLaunchIsolation()
} catch {
    FileHandle.standardError.write(Data("Holoscape launch refused: \(error)\n".utf8))
    Foundation.exit(EXIT_FAILURE)
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)

// Disable state restoration — Holoscape manages its own channel persistence
UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")

let delegate = AppDelegate()
app.delegate = delegate
app.run()
