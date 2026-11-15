import Foundation

/// Lists build output that a build makes again: Xcode DerivedData, and dependency or
/// build folders inside git checkouts that nobody has used recently.
nonisolated enum BuildOutputCleanupProvider {
    /// Output in a checkout unused for this long is preselected for removal.
    static let idleAfterDays = 7

    /// Folder names that are always rebuildable output.
    static let outputNames: Set<String> = [
        "node_modules", ".next", ".turbo", ".nuxt", ".svelte-kit", ".parcel-cache", ".expo", ".wrangler"
    ]
    /// Folder names that are output only next to the named manifest.
    static let outputNamesWithManifest: [String: String] = [
        "target": "Cargo.toml",
        ".build": "Package.swift",
        "DerivedData": ""
    ]

    /// Finds output folders in one checkout, down to `maxDepth`, without entering them.
    static func outputFolders(in checkout: URL, maxDepth: Int = 4) -> [URL] {
        var found: [URL] = []
        let manager = FileManager.default
        func visit(_ folder: URL, depth: Int) {
            guard let children = try? manager.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: []
            ) else { return }
            for child in children {
                let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
                let name = child.lastPathComponent
                if outputNames.contains(name) { found.append(child); continue }
                if let manifest = outputNamesWithManifest[name] {
                    if manifest.isEmpty || manager.fileExists(atPath: folder.appendingPathComponent(manifest).path) {
                        found.append(child)
                        continue
                    }
                }
                // A nested checkout is listed on its own; .git holds no build output.
                if name == ".git" || manager.fileExists(atPath: child.appendingPathComponent(".git").path) { continue }
                if depth < maxDepth { visit(child, depth: depth + 1) }
            }
        }
        visit(checkout, depth: 1)
        return found
    }

    static func checkoutItems(roots: [URL], now: Date = Date()) async -> [CleanupItem] {
        let repositories = await GitCheckouts.repositories(under: roots)
        let checkouts = repositories.flatMap { [$0.root] + $0.worktrees.filter { !$0.isPrunable }.map(\.path) }
        return await withTaskGroup(of: CleanupItem?.self) { group in
            for checkout in checkouts {
                group.addTask {
                    let folders = outputFolders(in: checkout)
                    guard !folders.isEmpty else { return nil }
                    let lastUsed = await GitCheckouts.lastActivity(of: checkout)
                    let days = SimulatorCleanupProvider.daysSince(lastUsed, now: now)
                    let names = Set(folders.map(\.lastPathComponent)).sorted().joined(separator: ", ")
                    return CleanupItem(
                        id: "build-output:" + checkout.path,
                        category: .buildOutput,
                        title: checkout.lastPathComponent,
                        subtitle: WorktreeCleanupProvider.abbreviatedPath(checkout) + " · " + names,
                        status: days.map { $0 == 0 ? "Used today" : "Used \($0) day\($0 == 1 ? "" : "s") ago" } ?? "Last use unknown",
                        safety: (days ?? Int.max) >= idleAfterDays ? .safe : .review,
                        frees: nil, holds: nil, lastUsed: lastUsed,
                        measurePaths: folders,
                        action: .deleteRebuildableFolders(folders),
                        blockedReason: nil
                    )
                }
            }
            var items: [CleanupItem] = []
            for await item in group { if let item { items.append(item) } }
            return items
        }
    }

    static func derivedDataItems(now: Date = Date()) -> [CleanupItem] {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Developer/Xcode/DerivedData")
        guard let folders = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        return folders.compactMap { folder in
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  folder.lastPathComponent != "ModuleCache.noindex" else { return nil }
            let info = NSDictionary(contentsOf: folder.appendingPathComponent("info.plist"))
            let workspace = (info?["WorkspacePath"] as? String).map(URL.init(fileURLWithPath:))
            let lastUsed = info?["LastAccessedDate"] as? Date
                ?? (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            let days = SimulatorCleanupProvider.daysSince(lastUsed, now: now)
            return CleanupItem(
                id: "derived-data:" + folder.path,
                category: .buildOutput,
                title: workspace?.deletingPathExtension().lastPathComponent ?? folder.lastPathComponent,
                subtitle: "Xcode DerivedData" + (workspace.map { " · " + WorktreeCleanupProvider.abbreviatedPath($0) } ?? ""),
                status: days.map { $0 == 0 ? "Built today" : "Built \($0) day\($0 == 1 ? "" : "s") ago" } ?? "Last build unknown",
                safety: (days ?? Int.max) >= idleAfterDays ? .safe : .review,
                frees: nil, holds: nil, lastUsed: lastUsed,
                measurePaths: [folder],
                action: .deleteRebuildableFolders([folder]),
                blockedReason: nil
            )
        }
    }

    static func scan(roots: [URL] = GitCheckouts.defaultRoots) async -> [CleanupItem] {
        derivedDataItems() + (await checkoutItems(roots: roots))
    }
}
