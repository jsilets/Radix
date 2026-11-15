import Foundation

nonisolated enum CleanupError: Error, LocalizedError {
    case commandFailed(String, String)
    case backupFailed(String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let command, let output): "\(command) failed: \(output)"
        case .backupFailed(let detail): "Could not save local work, so nothing was removed. \(detail)"
        }
    }
}

/// Saves work that exists only on this Mac before a worktree is removed. The Swift form
/// of `save-local-work` in harness-parity:
///   local.bundle   commits from HEAD that are on no remote branch
///   tracked.patch  uncommitted changes to tracked files
///   untracked.tgz  untracked files that .gitignore does not exclude
nonisolated enum LocalWorkSaver {
    static var archiveRoot: URL {
        let day = Date().formatted(.iso8601.year().month().day())
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Archive/radix-cleanup/\(day)")
    }

    /// Returns the folder that holds the saved files.
    static func save(_ worktree: URL, into archive: URL = archiveRoot) async throws -> URL {
        let slug = WorktreeCleanupProvider.abbreviatedPath(worktree)
            .replacingOccurrences(of: "~/", with: "").replacingOccurrences(of: "/", with: "_")
        let destination = archive.appendingPathComponent(slug)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let path = worktree.path

        let head = try await git(["-C", path, "rev-parse", "HEAD"])
        try (["path=\(path)", "head=\(head.stdout)"].joined(separator: "\n"))
            .write(to: destination.appendingPathComponent("meta.txt"), atomically: true, encoding: .utf8)

        let unpushed = try await git(["-C", path, "rev-list", "--count", "HEAD", "--not", "--remotes"])
        if (Int(unpushed.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) > 0 {
            let bundle = destination.appendingPathComponent("local.bundle").path
            _ = try await git(["-C", path, "bundle", "create", bundle, "HEAD", "--not", "--remotes"])
            _ = try await git(["-C", path, "bundle", "verify", bundle])
        }
        let diff = try await git(["-C", path, "diff", "HEAD", "--binary"])
        if !diff.stdout.isEmpty {
            try diff.stdout.write(to: destination.appendingPathComponent("tracked.patch"), atomically: true, encoding: .utf8)
        }
        let untracked = try await git(["-C", path, "ls-files", "--others", "--exclude-standard", "-z"])
        // A nested checkout shows up as one untracked folder. It is listed and saved on
        // its own, so leave it out instead of copying its whole tree here.
        let entries = untracked.stdout.split(separator: "\0").map(String.init).filter {
            !FileManager.default.fileExists(atPath: worktree.appendingPathComponent($0).appendingPathComponent(".git").path)
        }
        if !entries.isEmpty {
            let list = destination.appendingPathComponent("untracked.list")
            try entries.joined(separator: "\0").write(to: list, atomically: true, encoding: .utf8)
            let tar = try await CommandRunner.run(
                "tar", ["--null", "-T", list.path, "-czf", destination.appendingPathComponent("untracked.tgz").path],
                in: worktree, timeout: 600
            )
            guard tar.succeeded else { throw CleanupError.backupFailed(tar.stderr) }
            try? FileManager.default.removeItem(at: list)
        }
        return destination
    }

    private static func git(_ arguments: [String]) async throws -> CommandResult {
        let result = try await CommandRunner.run("git", arguments, timeout: 600)
        guard result.succeeded else { throw CleanupError.backupFailed(result.stderr) }
        return result
    }
}

/// Runs the operation behind each cleanup action and logs what happened.
nonisolated enum CleanupExecutor {
    static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Radix/cleanup.log")
    }

    /// Removes one item. Returns a short description of what was done.
    @concurrent
    static func perform(_ item: CleanupItem) async throws -> String {
        let detail = try await run(item.action)
        log("REMOVED \(item.category.rawValue) \(item.title) — \(detail)")
        return detail
    }

    private static func run(_ action: CleanupAction) async throws -> String {
        switch action {
        case let .removeWorktree(repo, worktree, branch, deleteBranch):
            var notes: [String] = []
            let work = await GitCheckouts.localWork(in: worktree)
            if !work.isEmpty {
                let saved = try await LocalWorkSaver.save(worktree)
                notes.append("saved \(work.description) to \(WorktreeCleanupProvider.abbreviatedPath(saved))")
            }
            try await check("git", ["-C", repo.path, "worktree", "remove", "--force", worktree.path])
            notes.append("removed the worktree")
            if deleteBranch, let branch {
                try await check("git", ["-C", repo.path, "branch", "-D", branch])
                notes.append("deleted merged branch \(branch)")
            }
            return notes.joined(separator: "; ")
        case let .pruneWorktreeRecords(repo):
            try await check("git", ["-C", repo.path, "worktree", "prune"])
            return "pruned stale worktree records"
        case let .deleteSimulator(udid):
            try await check("xcrun", ["simctl", "delete", udid])
            return "deleted the simulator"
        case let .deleteSimulatorRuntime(identifier):
            try await check("xcrun", ["simctl", "runtime", "delete", identifier], timeout: 600)
            return "deleted the runtime"
        case let .deleteDockerVolume(name, stoppedContainers):
            if !stoppedContainers.isEmpty {
                try await check("docker", ["rm"] + stoppedContainers)
            }
            try await check("docker", ["volume", "rm", name])
            return stoppedContainers.isEmpty
                ? "deleted the volume"
                : "deleted stopped containers \(stoppedContainers.joined(separator: ", ")) and the volume"
        case .pruneDockerImages:
            try await check("docker", ["image", "prune", "-af"], timeout: 600)
            return "pruned unused images"
        case .pruneDockerBuildCache:
            try await check("docker", ["builder", "prune", "-af"], timeout: 600)
            return "pruned the build cache"
        case let .deleteRebuildableFolders(folders):
            for folder in folders where FileManager.default.fileExists(atPath: folder.path) {
                try FileManager.default.removeItem(at: folder)
            }
            return "deleted " + folders.map(\.lastPathComponent).joined(separator: ", ")
        }
    }

    private static func check(_ tool: String, _ arguments: [String], timeout: TimeInterval = 120) async throws {
        let result = try await CommandRunner.run(tool, arguments, timeout: timeout)
        guard result.succeeded else {
            throw CleanupError.commandFailed(([tool] + arguments).joined(separator: " "),
                                             result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    static func log(_ line: String) {
        let url = logURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let entry = "\(Date().formatted(.iso8601)) \(line)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(entry.utf8))
            try? handle.close()
        } else {
            try? entry.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
