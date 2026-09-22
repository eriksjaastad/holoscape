import XCTest
@testable import Holoscape

final class GitBranchResolverTests: XCTestCase {
    func testResolvesBranchFromRepositoryRoot() throws {
        let repo = try makeRepository(branch: "main")
        defer { try? FileManager.default.removeItem(at: repo) }

        XCTAssertEqual(GitBranchResolver.currentBranch(containing: repo.path), "main")
    }

    func testResolvesBranchFromNestedDirectory() throws {
        let repo = try makeRepository(branch: "feature/git-tabs")
        let nested = repo.appendingPathComponent("Sources/Holoscape", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }

        XCTAssertEqual(GitBranchResolver.currentBranch(containing: nested.path), "feature/git-tabs")
    }

    func testResolvesWorktreeGitDirFile() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let actualGit = root.appendingPathComponent("actual.git", isDirectory: true)
        let worktree = root.appendingPathComponent("worktree", isDirectory: true)
        try FileManager.default.createDirectory(at: actualGit, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try "ref: refs/heads/worktree-branch\n".write(
            to: actualGit.appendingPathComponent("HEAD"),
            atomically: true,
            encoding: .utf8
        )
        try "gitdir: ../actual.git\n".write(
            to: worktree.appendingPathComponent(".git"),
            atomically: true,
            encoding: .utf8
        )

        XCTAssertEqual(GitBranchResolver.currentBranch(containing: worktree.path), "worktree-branch")
    }

    func testDetachedHeadReturnsShortObjectID() throws {
        let repo = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: repo) }
        let git = repo.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        try "0123456789abcdef\n".write(to: git.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)

        XCTAssertEqual(GitBranchResolver.currentBranch(containing: repo.path), "0123456")
    }

    func testDecoratesChannelLabelWhenBranchExists() throws {
        let repo = try makeRepository(branch: "main")
        defer { try? FileManager.default.removeItem(at: repo) }

        XCTAssertEqual(ChannelGitBranchLabel.decorate("holoscape", workingDirectory: repo.path), "holoscape · main")
    }

    private func makeRepository(branch: String) throws -> URL {
        let repo = try makeTempDirectory()
        let git = repo.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        try "ref: refs/heads/\(branch)\n".write(to: git.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        return repo
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitBranchResolverTests-")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
