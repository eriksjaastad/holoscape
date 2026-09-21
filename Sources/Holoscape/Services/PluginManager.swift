import Foundation

struct PluginManager: Sendable {
    private let registry: PluginRegistry
    private let projectTrackerPlugin: ProjectTrackerPlugin
    private let projectTrackerConfiguration: ProjectTrackerPluginConfiguration

    init(
        registry: PluginRegistry = PluginRegistry(),
        projectTrackerPlugin: ProjectTrackerPlugin = ProjectTrackerPlugin(),
        projectTrackerConfiguration: ProjectTrackerPluginConfiguration = .default
    ) {
        self.registry = registry
        self.projectTrackerPlugin = projectTrackerPlugin
        self.projectTrackerConfiguration = projectTrackerConfiguration
    }

    init(
        registry: PluginRegistry = PluginRegistry(),
        projectTrackerPlugin: ProjectTrackerPlugin = ProjectTrackerPlugin(),
        config: HoloscapeConfig
    ) {
        self.init(
            registry: registry,
            projectTrackerPlugin: projectTrackerPlugin,
            projectTrackerConfiguration: config.projectTrackerPluginConfiguration()
        )
    }

    func prepareStartup() -> PluginStartupSnapshot {
        do {
            let manifests = try registry.bundledPlugins()
            let states = manifests.map { manifest in
                prepareState(for: manifest)
            }
            return PluginStartupSnapshot(states: states)
        } catch {
            return PluginStartupSnapshot(states: [
                .failed(
                    .init(
                        pluginID: "plugin-registry",
                        displayName: "Plugin Registry",
                        message: String(describing: error)
                    )
                ),
            ])
        }
    }

    private func prepareState(for manifest: ValidatedPluginManifest) -> PluginStartupState {
        guard manifest.id == ProjectTrackerPlugin.pluginID else {
            return .failed(
                .init(
                    pluginID: manifest.id,
                    displayName: manifest.displayName,
                    message: "No bundled runtime is registered for plugin \(manifest.id)"
                )
            )
        }

        do {
            let startPlan = try projectTrackerPlugin.prepareStart(
                manifest: manifest,
                configuration: projectTrackerConfiguration
            )
            switch startPlan {
            case .disabled(let pluginID):
                return .disabled(
                    .init(
                        pluginID: pluginID,
                        displayName: manifest.displayName,
                        removedContributions: PluginContributions(projectTrackerPlan: nil)
                    )
                )
            case .ready(let runtimePlan):
                return .ready(
                    .init(
                        plan: runtimePlan,
                        contributions: PluginContributions(projectTrackerPlan: runtimePlan)
                    )
                )
            }
        } catch {
            return .failed(
                .init(
                    pluginID: manifest.id,
                    displayName: manifest.displayName,
                    message: String(describing: error)
                )
            )
        }
    }
}

struct PluginStartupSnapshot: Equatable, Sendable {
    let states: [PluginStartupState]

    var contributions: PluginContributions {
        states.reduce(.empty) { partial, state in
            guard case .ready(let ready) = state else { return partial }
            return partial.merging(ready.contributions)
        }
    }

    var failures: [PluginFailureState] {
        states.compactMap { state in
            guard case .failed(let failure) = state else { return nil }
            return failure
        }
    }
}

enum PluginStartupState: Equatable, Sendable {
    case disabled(PluginDisabledState)
    case ready(PluginReadyState)
    case failed(PluginFailureState)
}

struct PluginDisabledState: Equatable, Sendable {
    let pluginID: String
    let displayName: String
    let removedContributions: PluginContributions
}

struct PluginReadyState: Equatable, Sendable {
    let plan: ProjectTrackerPluginRuntimePlan
    let contributions: PluginContributions
}

struct PluginFailureState: Equatable, Sendable {
    let pluginID: String
    let displayName: String
    let message: String
}

struct PluginContributions: Equatable, Sendable {
    static let empty = PluginContributions(
        launcherProfiles: [],
        commandDescriptors: [],
        statusAdapters: []
    )

    let launcherProfiles: [PluginLauncherProfile]
    let commandDescriptors: [PluginCommandDescriptor]
    let statusAdapters: [PluginStatusAdapterDescriptor]

    init(
        launcherProfiles: [PluginLauncherProfile],
        commandDescriptors: [PluginCommandDescriptor],
        statusAdapters: [PluginStatusAdapterDescriptor]
    ) {
        self.launcherProfiles = launcherProfiles
        self.commandDescriptors = commandDescriptors
        self.statusAdapters = statusAdapters
    }

    init(projectTrackerPlan plan: ProjectTrackerPluginRuntimePlan?) {
        guard let plan else {
            self = .empty
            return
        }
        launcherProfiles = [
            .init(
                pluginID: plan.pluginID,
                id: "project-tracker-message-board",
                displayName: "Project Tracker Message Board"
            ),
        ]
        commandDescriptors = [
            .init(
                pluginID: plan.pluginID,
                id: ProjectTrackerPlugin.openBoardCommandID,
                displayName: "Open Project Tracker Board",
                requiredArguments: ["projectSlug"]
            ),
        ]
        statusAdapters = [
            .init(
                pluginID: plan.pluginID,
                id: ProjectTrackerPlugin.taskStatusAdapterID,
                displayName: "Project Tracker Task Status"
            ),
        ]
    }

    func merging(_ other: PluginContributions) -> PluginContributions {
        PluginContributions(
            launcherProfiles: launcherProfiles + other.launcherProfiles,
            commandDescriptors: commandDescriptors + other.commandDescriptors,
            statusAdapters: statusAdapters + other.statusAdapters
        )
    }
}

struct PluginLauncherProfile: Equatable, Sendable {
    let pluginID: String
    let id: String
    let displayName: String
}

struct PluginCommandDescriptor: Equatable, Sendable {
    let pluginID: String
    let id: String
    let displayName: String
    let requiredArguments: [String]

    init(
        pluginID: String,
        id: String,
        displayName: String,
        requiredArguments: [String] = []
    ) {
        self.pluginID = pluginID
        self.id = id
        self.displayName = displayName
        self.requiredArguments = requiredArguments
    }
}

struct PluginStatusAdapterDescriptor: Equatable, Sendable {
    let pluginID: String
    let id: String
    let displayName: String
}
