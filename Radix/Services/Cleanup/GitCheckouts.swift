import Foundation

/// A primary repository and the linked worktrees git has registered for it.
nonisolated struct GitRepository: Sendable, Equatable {
    let root: URL
    let worktrees: [GitWorktree]
}

nonisolated struct GitWorktree: Sendable, Equatable {
    let path: URL
    let head: String?
    /// Short branch name, or nil when HEAD is detached.
    let branch: String?
    let isLocked: Bool
    /// Git reports the folder as gone; only the record remains.
    let isPrunable: Bool
}

nonisolated enum GitCheckouts {
    /// Folders searched for primary repositories. Agent worktrees elsewhere (T3, Codex,
    /// Claude Code) are found through `git worktree list` of these repositories.
    static var defaultRoots: [URL] {
        [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/GitHub")]
    }

    private static let skippedFolderNames: Set<String> = ["node_modules", "Library", ".Trash", "worktrees", ".worktrees"]

    /// Finds folders whose `.git` is a directory (primary repositories), down to `maxDepth`.
    static func primaryRepositories(under roots: [URL], maxDepth: Int = 3) -> [URL] {
        var found: [URL] = []
        let manager = FileManager.default
        func visit(_ folder: URL, depth: Int) {
            var isDirectory: ObjCBool = false
            if manager.fileExists(atPath: folder.appendingPathComponent(".git").path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                found.append(folder)
            }
            guard depth < maxDepth,
                  let children = try? manager.contentsOfDirectory(
                    at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]
                  ) else { return }
            for child in children where !skippedFolderNames.contains(child.lastPathComponent) {
                let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
                visit(child, depth: depth + 1)
            }
        }
        roots.forEach { visit($0, depth: 0) }
        return found
    }

    /// Parses `git worktree list --porcelain`. The first entry is the main worktree and is dropped.
    static func parseWorktreeList(_ porcelain: String) -> [GitWorktree] {
        var worktrees: [GitWorktree] = []
        for block in porcelain.components(separatedBy: "\n\n") {
            var path: String?, head: String?, branch: String?
            var locked = false, prunable = false
            for line in block.split(separator: "\n").map(String.init) {
                if line.hasPrefix("worktree ") { path = String(line.dropFirst(9)) }
                else if line.hasPrefix("HEAD ") { head = String(line.dropFirst(5)) }
                else if line.hasPrefix("branch ") { branch = String(line.dropFirst(7)).replacingOccurrences(of: "refs/heads/", with: "") }
                else if line == "locked" || line.hasPrefix("locked ") { locked = true }
                else if line == "prunable" || line.hasPrefix("prunable ") { prunable = true }
            }
            guard let path else { continue }
            worktrees.append(GitWorktree(path: URL(fileURLWithPath: path), head: head, branch: branch,
                                         isLocked: locked, isPrunable: prunable))
        }
        return Array(worktrees.dropFirst())
    }

    static func repository(at root: URL) async -> GitRepository? {
        guard let result = try? await CommandRunner.run("git", ["-C", root.path, "worktree", "list", "--porcelain"]),
              result.succeeded else { return nil }
        return GitRepository(root: root, worktrees: parseWorktreeList(result.stdout))
    }

    static func repositories(under roots: [URL] = defaultRoots) async -> [GitRepository] {
        let roots = primaryRepositories(under: roots)
        return await withTaskGroup(of: GitRepository?.self) { group in
            for root in roots { group.addTask { await repository(at: root) } }
            var repositories: [GitRepository] = []
            for await repository in group { if let repository { repositories.append(repository) } }
            return repositories.sorted { $0.root.path < $1.root.path }
        }
    }

    /// Work in a checkout that exists only on this Mac.
    nonisolated struct LocalWork: Sendable, Equatable {
        var uncommittedFiles = 0
        var unpushedCommits = 0
        var isEmpty: Bool { uncommittedFiles == 0 && unpushedCommits == 0 }

        var description: String {
            var parts: [String] = []
            if uncommittedFiles > 0 { parts.append("\(uncommittedFiles) uncommitted file\(uncommittedFiles == 1 ? "" : "s")") }
            if unpushedCommits > 0 { parts.append("\(unpushedCommits) commit\(unpushedCommits == 1 ? "" : "s") on no remote") }
            return parts.joined(separator: " · ")
        }
    }

    static func localWork(in checkout: URL) async -> LocalWork {
        async let status = try? CommandRunner.run("git", ["-C", checkout.path, "status", "--porcelain"])
        async let unpushed = try? CommandRunner.run("git", ["-C", checkout.path, "rev-list", "--count", "HEAD", "--not", "--remotes"])
        var work = LocalWork()
        if let status = await status, status.succeeded {
            work.uncommittedFiles = status.stdout.split(separator: "\n").count
        }
        if let unpushed = await unpushed, unpushed.succeeded {
            work.unpushedCommits = Int(unpushed.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }
        return work
    }

    /// Last time git touched the checkout: its index (status, add, checkout) or HEAD log (commit).
    static func lastActivity(of checkout: URL) async -> Date? {
        guard let result = try? await CommandRunner.run("git", ["-C", checkout.path, "rev-parse", "--absolute-git-dir"]),
              result.succeeded else { return nil }
        let gitDir = URL(fileURLWithPath: result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        return ["index", "logs/HEAD", "HEAD"]
            .compactMap { try? gitDir.appendingPathComponent($0).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
            .max()
    }
}
