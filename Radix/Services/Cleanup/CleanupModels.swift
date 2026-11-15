import Foundation

nonisolated enum CleanupCategory: String, CaseIterable, Identifiable, Sendable {
    case worktrees
    case simulators
    case docker
    case buildOutput

    var id: String { rawValue }
    /// Sidebar selection IDs share a namespace with scan targets, so they carry a prefix.
    var sidebarID: String { "cleanup:" + rawValue }

    init?(sidebarID: String) {
        guard sidebarID.hasPrefix("cleanup:") else { return nil }
        self.init(rawValue: String(sidebarID.dropFirst("cleanup:".count)))
    }

    var title: String {
        switch self {
        case .worktrees: "Worktrees"
        case .simulators: "Simulators"
        case .docker: "Docker"
        case .buildOutput: "Build Output"
        }
    }

    var systemImage: String {
        switch self {
        case .worktrees: "arrow.triangle.branch"
        case .simulators: "iphone"
        case .docker: "shippingbox"
        case .buildOutput: "hammer"
        }
    }

    var summary: String {
        switch self {
        case .worktrees: "Git worktrees from agents and branches. Merged ones are safe to remove; local work is saved first."
        case .simulators: "iOS simulator devices and runtimes, with when each was last used."
        case .docker: "Docker volumes, unused images, and build cache."
        case .buildOutput: "Xcode DerivedData and node_modules, .next, and target folders in idle checkouts."
        }
    }
}

/// How safe an item is to remove, shown as a badge and used to preselect rows.
nonisolated enum CleanupSafety: Int, Comparable, Sendable {
    /// Rebuildable or already merged. Preselected.
    case safe
    /// Nothing is lost, but it may be in use or slow to rebuild.
    case review
    /// Holds data that exists only here. Removal saves or loses it, so it is never preselected.
    case holdsData

    static func < (lhs: CleanupSafety, rhs: CleanupSafety) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// What removing an item runs. Each case maps to one concrete operation in CleanupExecutor.
nonisolated enum CleanupAction: Sendable, Equatable {
    /// Saves local-only work, removes the worktree, and deletes the branch if merged.
    case removeWorktree(repo: URL, worktree: URL, branch: String?, deleteBranch: Bool)
    /// Removes stale worktree records whose folders are already gone.
    case pruneWorktreeRecords(repo: URL)
    case deleteSimulator(udid: String)
    case deleteSimulatorRuntime(identifier: String)
    case deleteDockerVolume(name: String, stoppedContainers: [String])
    case pruneDockerImages
    case pruneDockerBuildCache
    /// Deletes folders a build makes again. Deleted, not moved to the Trash,
    /// because space in the Trash is not free.
    case deleteRebuildableFolders([URL])
}

nonisolated struct CleanupItem: Identifiable, Sendable, Equatable {
    let id: String
    let category: CleanupCategory
    let title: String
    let subtitle: String
    /// Short state, such as "Merged (PR content in main)" or "3 uncommitted files".
    let status: String
    let safety: CleanupSafety
    /// Space removal gives back. Nil until measured.
    var frees: Int64?
    /// Space the item holds with each shared block counted once. Nil when unknown.
    var holds: Int64?
    let lastUsed: Date?
    /// Paths to measure with DiskFreedMeasurer. Empty when the size comes from a tool.
    let measurePaths: [URL]
    let action: CleanupAction
    /// Removal is blocked, for example a booted simulator. Shown instead of a checkbox.
    let blockedReason: String?
}

/// One finished or failed removal, for the history log and the result banner.
nonisolated struct CleanupOutcome: Identifiable, Sendable {
    let id = UUID()
    let item: CleanupItem
    let succeeded: Bool
    let detail: String
}
