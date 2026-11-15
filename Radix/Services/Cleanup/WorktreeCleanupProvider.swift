import Foundation

/// Lists linked git worktrees and how safe each one is to remove.
///
/// "Merged" comes from worktrunk (`wt step prune --dry-run`) when it is installed,
/// because it detects squash merges from content and so works after a branch rename.
/// Without worktrunk, a worktree counts as merged only when its HEAD is an ancestor
/// of the remote default branch.
nonisolated enum WorktreeCleanupProvider {
    struct MergeInfo: Sendable, Equatable {
        let reason: String
        let target: String
    }

    /// Parses `wt step prune --dry-run --format=json` into merge info keyed by worktree path.
    static func parseWorktrunkPrune(_ json: String) -> [String: MergeInfo] {
        guard let data = json.data(using: .utf8),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [:] }
        var merged: [String: MergeInfo] = [:]
        for entry in entries {
            guard let path = entry["path"] as? String else { continue }
            merged[URL(fileURLWithPath: path).standardizedFileURL.path] = MergeInfo(
                reason: entry["reason"] as? String ?? "merged",
                target: entry["target"] as? String ?? "the default branch"
            )
        }
        return merged
    }

    static func mergedWorktrees(in repository: URL) async -> [String: MergeInfo]? {
        guard CommandRunner.isAvailable("wt"),
              let result = try? await CommandRunner.run(
                "wt", ["step", "prune", "--dry-run", "--min-age=0s", "--format=json"], in: repository
              ),
              result.succeeded else { return nil }
        return parseWorktrunkPrune(result.stdout)
    }

    static func isAncestorOfDefaultBranch(_ worktree: URL) async -> Bool {
        guard let result = try? await CommandRunner.run(
            "git", ["-C", worktree.path, "merge-base", "--is-ancestor", "HEAD", "refs/remotes/origin/HEAD"]
        ) else { return false }
        return result.succeeded
    }

    static func scan(roots: [URL] = GitCheckouts.defaultRoots) async -> [CleanupItem] {
        let repositories = await GitCheckouts.repositories(under: roots)
        return await withTaskGroup(of: [CleanupItem].self) { group in
            for repository in repositories where !repository.worktrees.isEmpty {
                group.addTask { await items(for: repository) }
            }
            var items: [CleanupItem] = []
            for await batch in group { items += batch }
            return items
        }
    }

    static func items(for repository: GitRepository) async -> [CleanupItem] {
        let repoName = repository.root.lastPathComponent
        let wtMerged = await mergedWorktrees(in: repository.root)
        var items: [CleanupItem] = []

        let stale = repository.worktrees.filter(\.isPrunable)
        if !stale.isEmpty {
            items.append(CleanupItem(
                id: "worktree-records:" + repository.root.path,
                category: .worktrees,
                title: "\(stale.count) stale worktree record\(stale.count == 1 ? "" : "s")",
                subtitle: repoName + " · folders already gone",
                status: "Record only",
                safety: .safe,
                frees: 0, holds: 0, lastUsed: nil, measurePaths: [],
                action: .pruneWorktreeRecords(repo: repository.root),
                blockedReason: nil
            ))
        }

        for worktree in repository.worktrees where !worktree.isPrunable {
            async let work = GitCheckouts.localWork(in: worktree.path)
            async let lastUsed = GitCheckouts.lastActivity(of: worktree.path)
            let merge: MergeInfo?
            if let wtMerged {
                merge = wtMerged[worktree.path.standardizedFileURL.path]
            } else {
                merge = await isAncestorOfDefaultBranch(worktree.path)
                    ? MergeInfo(reason: "ancestor of", target: "origin") : nil
            }
            let localWork = await work
            let status: String
            let safety: CleanupSafety
            if let merge, localWork.uncommittedFiles == 0 {
                status = "Merged · \(merge.reason) \(merge.target)"
                safety = .safe
            } else if !localWork.isEmpty {
                status = localWork.description
                safety = .holdsData
            } else {
                status = "Pushed, not merged"
                safety = .review
            }
            items.append(CleanupItem(
                id: "worktree:" + worktree.path.path,
                category: .worktrees,
                title: worktree.branch ?? worktree.path.lastPathComponent,
                subtitle: repoName + " · " + abbreviatedPath(worktree.path),
                status: status,
                safety: safety,
                frees: nil, holds: nil,
                lastUsed: await lastUsed,
                measurePaths: [worktree.path],
                action: .removeWorktree(
                    repo: repository.root, worktree: worktree.path, branch: worktree.branch,
                    deleteBranch: merge != nil && worktree.branch != nil
                ),
                blockedReason: worktree.isLocked ? "Locked by the tool that made it" : nil
            ))
        }
        return items
    }

    static func abbreviatedPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
    }
}
