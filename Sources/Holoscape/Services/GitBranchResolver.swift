import Foundation

enum GitBranchResolver {
    private static let maxAncestorDepth = 64

    static func currentBranch(containing path: String?) -> String? {
        guard let path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)

        for _ in 0..<maxAncestorDepth {
            let gitURL = url.appendingPathComponent(".git")
            if let branch = branchName(fromGitPath: gitURL) {
                return branch
            }

            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }
            url = parent
        }

        return nil
    }

    private static func branchName(fromGitPath gitURL: URL) -> String? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: gitURL.path, isDirectory: &isDirectory) else { return nil }

        let gitDirectory: URL
        if isDirectory.boolValue {
            gitDirectory = gitURL
        } else {
            guard let contents = try? String(contentsOf: gitURL, encoding: .utf8),
                  let relativeGitDir = parseGitDirFile(contents) else { return nil }
            gitDirectory = URL(fileURLWithPath: relativeGitDir, relativeTo: gitURL.deletingLastPathComponent()).standardizedFileURL
        }

        let headURL = gitDirectory.appendingPathComponent("HEAD")
        guard let head = try? String(contentsOf: headURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !head.isEmpty else { return nil }

        let refPrefix = "ref: refs/heads/"
        if head.hasPrefix(refPrefix) {
            let branch = String(head.dropFirst(refPrefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return branch.isEmpty ? nil : branch
        }

        // Detached HEAD: show the short object id rather than hiding useful git state.
        if head.range(of: #"^[0-9a-fA-F]{7,40}$"#, options: .regularExpression) != nil {
            return String(head.prefix(7))
        }

        return nil
    }

    private static func parseGitDirFile(_ contents: String) -> String? {
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "gitdir:"
        guard trimmed.lowercased().hasPrefix(prefix) else { return nil }
        let path = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }
}

enum ChannelGitBranchLabel {
    static func decorate(_ base: String, workingDirectory: String?) -> String {
        guard let branch = GitBranchResolver.currentBranch(containing: workingDirectory) else { return base }
        return "\(base) · \(branch)"
    }
}
