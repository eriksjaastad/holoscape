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

    var searchableText: String {
        [label, detail, profile?.directory]
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

    func filtered(by query: String) -> DirectoryLauncherSnapshot {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return self }
        return DirectoryLauncherSnapshot(
            root: root,
            sections: sections.compactMap { section in
                let items = section.items.filter { $0.searchableText.contains(normalized) }
                return items.isEmpty ? nil : DirectoryLauncherSection(title: section.title, items: items)
            }
        )
    }
}

enum DirectoryLauncherModel {
    static func root(activeDirectory: String?, fallback: URL = DefaultWorkingDirectory.preferredURL) -> URL {
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
        fileManager: FileManager = .default
    ) throws -> DirectoryLauncherSnapshot {
        let standardizedRoot = root.standardizedFileURL
        let childURLs = try fileManager.contentsOfDirectory(
            at: standardizedRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        let directories = try childURLs.compactMap { url -> URL? in
            guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { return nil }
            return url.standardizedFileURL
        }.sorted {
            $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending
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
                        profile: $0
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
                        )
                    )
                }
            ))
        }

        let directoryPaths = Set(directories.map(\.path))
        var seenProfiles = Set<String>()
        let savedProfiles = (configured + discovered).filter { profile in
            let key = "\(profile.connection.rawValue)|\(profile.label.lowercased())|\(profile.directory)"
            guard !seenProfiles.contains(key), !directoryPaths.contains(profile.directory) else { return false }
            seenProfiles.insert(key)
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
                        profile: $0
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
                        detail: "Reopen recent session",
                        kind: .recent,
                        profile: nil
                    )
                }
            ))
        }

        return DirectoryLauncherSnapshot(root: standardizedRoot, sections: sections)
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
        switch profile.connection {
        case .local:
            return profile.directory.isEmpty ? "Local session" : profile.directory
        case .ssh:
            return profile.host.map { "SSH to \($0)" } ?? "SSH session"
        case .agentChat:
            return "Shared agent chat"
        case .bridge:
            return "Holoscape bridge"
        case .mcp:
            return "MCP tool session"
        }
    }
}
