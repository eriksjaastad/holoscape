import Foundation

enum DefaultWorkingDirectory {
    static var projectsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("projects")
            .standardizedFileURL
    }

    static var preferredURL: URL {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: projectsURL.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return projectsURL
        }
        return FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
    }

    static var preferredPath: String {
        preferredURL.path
    }

    static func expandedURL(from path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .standardizedFileURL
    }

    static func localSessionDirectory(named label: String, root: String = "~/projects") -> URL {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") || trimmed.contains("/") {
            let explicitURL = expandedURL(from: trimmed)
            if isDirectory(explicitURL) {
                return explicitURL.standardizedFileURL
            }
        }

        let rootURL = expandedURL(from: root)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return preferredURL
        }

        if let exact = entries.first(where: { $0.lastPathComponent == label && isDirectory($0) }) {
            return exact.standardizedFileURL
        }

        if let caseInsensitive = entries.first(where: {
            $0.lastPathComponent.caseInsensitiveCompare(label) == .orderedSame && isDirectory($0)
        }) {
            return caseInsensitive.standardizedFileURL
        }

        return rootURL.standardizedFileURL
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}
