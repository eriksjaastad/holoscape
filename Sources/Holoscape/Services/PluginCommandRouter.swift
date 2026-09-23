import AppKit
import Foundation

protocol PluginExternalURLOpening: AnyObject, Sendable {
    func openExternalURL(_ url: URL)
}

final class NSWorkspacePluginExternalURLOpener: PluginExternalURLOpening, @unchecked Sendable {
    func openExternalURL(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}

enum PluginCommandExecutionResult: Equatable, Sendable {
    case openedExternalURL(URL)
}

enum PluginCommandExecutionError: Error, Equatable, CustomStringConvertible, Sendable {
    case commandNotAdvertised(String)
    case pluginUnavailable(String)
    case unsupportedAction(String)

    var description: String {
        switch self {
        case .commandNotAdvertised(let descriptorID):
            return "Plugin command is not advertised by the active plugin contributions: \(descriptorID)"
        case .pluginUnavailable(let pluginID):
            return "Plugin command cannot run because plugin is unavailable: \(pluginID)"
        case .unsupportedAction(let descriptorID):
            return "Plugin command resolved to an unsupported action: \(descriptorID)"
        }
    }
}

struct PluginCommandRouter: Sendable {
    private let startupSnapshot: PluginStartupSnapshot
    private let externalURLOpener: PluginExternalURLOpening

    init(
        startupSnapshot: PluginStartupSnapshot,
        externalURLOpener: PluginExternalURLOpening = NSWorkspacePluginExternalURLOpener()
    ) {
        self.startupSnapshot = startupSnapshot
        self.externalURLOpener = externalURLOpener
    }

    func execute(
        descriptorID: String,
        arguments: [String: String]
    ) throws -> PluginCommandExecutionResult {
        guard startupSnapshot.contributions.commandDescriptors.contains(where: { $0.id == descriptorID }) else {
            throw PluginCommandExecutionError.commandNotAdvertised(descriptorID)
        }

        guard let projectTrackerPlan = startupSnapshot.readyProjectTrackerPlan else {
            throw PluginCommandExecutionError.pluginUnavailable(ProjectTrackerPlugin.pluginID)
        }

        switch try projectTrackerPlan.commandAction(descriptorID: descriptorID, arguments: arguments) {
        case .openExternalURL(let url):
            externalURLOpener.openExternalURL(url)
            return .openedExternalURL(url)
        }
    }
}

private extension PluginStartupSnapshot {
    var readyProjectTrackerPlan: ProjectTrackerPluginRuntimePlan? {
        for state in states {
            guard case .ready(let ready) = state,
                  ready.plan.pluginID == ProjectTrackerPlugin.pluginID else {
                continue
            }
            return ready.plan
        }
        return nil
    }
}
