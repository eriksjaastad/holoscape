import Foundation

enum DirectoryLauncherItemKind: Equatable {
    case builtIn
    case profile
    case recent
}

struct DirectoryLauncherItem: Equatable {
    let label: String
    let detail: String?
    let kind: DirectoryLauncherItemKind
    let profile: SessionProfile?
    let recent: RecentSession?

    var searchableText: String {
        [label, detail, profile?.directory, profile?.command, profile?.host, profile?.user]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
    }
}

struct DirectoryLauncherSection: Equatable {
    let title: String
    let items: [DirectoryLauncherItem]
}

struct DirectoryLauncherSnapshot: Equatable {
    let root: URL
    let sections: [DirectoryLauncherSection]
    let directoryError: String?
    let hasAvailableDirectories: Bool

    func filtered(by query: String) -> DirectoryLauncherSnapshot {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return self }
        return DirectoryLauncherSnapshot(
            root: root,
            sections: sections.compactMap { section in
                let items = section.items.filter { $0.searchableText.contains(normalized) }
                    .sorted { lhs, rhs in
                        let lhsExact = lhs.label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized
                        let rhsExact = rhs.label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized
                        return lhsExact && !rhsExact
                    }
                return items.isEmpty ? nil : DirectoryLauncherSection(title: section.title, items: items)
            }.sorted { lhs, rhs in
                let lhsExact = lhs.items.contains { $0.label.lowercased() == normalized }
                let rhsExact = rhs.items.contains { $0.label.lowercased() == normalized }
                return lhsExact && !rhsExact
            },
            directoryError: directoryError,
            hasAvailableDirectories: hasAvailableDirectories
        )
    }
}

enum DirectoryLauncherModel {
    static func root(activeDirectory: String?, fallback: URL = DefaultWorkingDirectory.projectsURL) -> URL {
        if let activeDirectory {
            let activeURL = DefaultWorkingDirectory.expandedURL(from: activeDirectory)
            if isReadableDirectory(activeURL) {
                return activeURL
            }
        }
        return fallback.standardizedFileURL
    }

    static func snapshot(
        root: URL,
        configured: [SessionProfile],
        builtIn: [SessionProfile],
        discovered: [SessionProfile],
        recent: [RecentSession],
        fileManager: FileManager = .default,
        resourceValues: (URL) throws -> URLResourceValues = { try $0.resourceValues(forKeys: [.isDirectoryKey]) }
    ) -> DirectoryLauncherSnapshot {
        let standardizedRoot = root.standardizedFileURL
        let directories: [URL]
        let directoryError: String?
        do {
            let childURLs = try fileManager.contentsOfDirectory(
                at: standardizedRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            var errors: [String] = []
            directories = childURLs.compactMap { url -> URL? in
                do {
                    guard try resourceValues(url).isDirectory == true else { return nil }
                    return url.standardizedFileURL
                } catch {
                    errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
                    return nil
                }
            }.sorted {
                $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending
            }
            directoryError = errors.isEmpty ? nil : errors.joined(separator: "; ")
        } catch {
            directories = []
            directoryError = String(describing: error)
        }

        var sections: [DirectoryLauncherSection] = []
        if !builtIn.isEmpty {
            sections.append(DirectoryLauncherSection(
                title: "Channels",
                items: builtIn.map {
                    DirectoryLauncherItem(
                        label: $0.label,
                        detail: builtInDetail(for: $0),
                        kind: .builtIn,
                        profile: $0,
                        recent: nil
                    )
                }
            ))
        }

        if !directories.isEmpty {
            sections.append(DirectoryLauncherSection(
                title: "Directories",
                items: directories.map { directory in
                    DirectoryLauncherItem(
                        label: directory.lastPathComponent,
                        detail: directory.path,
                        kind: .profile,
                        profile: SessionProfile(
                            label: directory.lastPathComponent,
                            connection: .local,
                            command: "/bin/zsh",
                            directory: directory.path
                        ),
                        recent: nil
                    )
                }
            ))
        }

        var seenProfiles: [SessionProfile] = []
        let savedProfiles = (configured + discovered).filter { profile in
            guard !seenProfiles.contains(profile) else { return false }
            seenProfiles.append(profile)
            return true
        }
        if !savedProfiles.isEmpty {
            sections.append(DirectoryLauncherSection(
                title: "Saved Sessions",
                items: savedProfiles.map {
                    DirectoryLauncherItem(
                        label: $0.label,
                        detail: profileDetail(for: $0),
                        kind: .profile,
                        profile: $0,
                        recent: nil
                    )
                }
            ))
        }

        if !recent.isEmpty {
            sections.append(DirectoryLauncherSection(
                title: "Recent",
                items: recent.map {
                    DirectoryLauncherItem(
                        label: $0.label,
                        detail: recentDetail(for: $0),
                        kind: .recent,
                        profile: $0.profile,
                        recent: $0
                    )
                }
            ))
        }

        return DirectoryLauncherSnapshot(
            root: standardizedRoot,
            sections: sections,
            directoryError: directoryError,
            hasAvailableDirectories: !directories.isEmpty
        )
    }

    private static func isReadableDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
            && FileManager.default.isReadableFile(atPath: url.path)
    }

    private static func builtInDetail(for profile: SessionProfile) -> String {
        switch profile.label.lowercased() {
        case "shell": return "Local shell"
        case "agent (oauth)": return "Agent with browser sign-in"
        case "agent (api key)": return "Agent with API-key auth"
        case "claude": return "Claude in the selected root"
        case "group chat": return "Shared agent chat"
        case "bridge": return "Holoscape bridge"
        default: return profileDetail(for: profile)
        }
    }

    private static func profileDetail(for profile: SessionProfile) -> String {
        var parts: [String] = []
        switch profile.connection {
        case .local:
            parts.append("Local")
        case .ssh:
            let destination = [profile.user, profile.host]
                .compactMap { value in value?.isEmpty == false ? value : nil }
                .joined(separator: "@")
            parts.append(destination.isEmpty ? "SSH" : "SSH to \(destination)")
        case .agentChat:
            parts.append("Shared agent chat")
        case .bridge:
            parts.append("Holoscape bridge")
        case .mcp:
            parts.append("MCP tool session")
        }
        if !profile.directory.isEmpty {
            parts.append(profile.directory)
        }
        if !profile.command.isEmpty {
            parts.append(profile.command)
        }
        return parts.joined(separator: " · ")
    }

    private static func recentDetail(for recent: RecentSession) -> String {
        guard let profile = recent.profile else { return "Reopen recent session" }
        return profileDetail(for: profile)
    }
}
