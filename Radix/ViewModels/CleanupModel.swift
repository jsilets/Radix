import Combine
import Foundation

/// State for the Cleanup sidebar section: what each category found, what it frees,
/// what is selected, and the result of the last removal.
@MainActor
final class CleanupModel: ObservableObject {
    struct CategoryState {
        var items: [CleanupItem] = []
        var isScanning = false
        /// Items still waiting for DiskFreedMeasurer.
        var pendingMeasurements = 0
        var notice: String?
        var scannedAt: Date?
    }

    @Published private(set) var states: [CleanupCategory: CategoryState] = [:]
    @Published var selection: Set<CleanupItem.ID> = []
    @Published private(set) var snapshotsPresent = false
    @Published private(set) var isRemoving = false
    @Published private(set) var lastOutcomes: [CleanupOutcome] = []

    private var scanTasks: [CleanupCategory: Task<Void, Never>] = [:]

    func state(_ category: CleanupCategory) -> CategoryState { states[category] ?? CategoryState() }

    func items(_ category: CleanupCategory) -> [CleanupItem] { state(category).items }

    /// Space the removable items in a category free, counting only measured items.
    func totalFrees(_ category: CleanupCategory, safety: CleanupSafety? = nil) -> Int64 {
        items(category)
            .filter { $0.blockedReason == nil && (safety == nil || $0.safety == safety) }
            .compactMap(\.frees).reduce(0, +)
    }

    func selectedItems(in category: CleanupCategory) -> [CleanupItem] {
        items(category).filter { selection.contains($0.id) && $0.blockedReason == nil }
    }

    func selectSafeItems(in category: CleanupCategory) {
        selection = Set(items(category).filter { $0.safety == .safe && $0.blockedReason == nil }.map(\.id))
    }

    func scanAllIfNeeded() {
        for category in CleanupCategory.allCases where state(category).scannedAt == nil && !state(category).isScanning {
            refresh(category)
        }
    }

    func refresh(_ category: CleanupCategory) {
        scanTasks[category]?.cancel()
        states[category, default: CategoryState()].isScanning = true
        scanTasks[category] = Task { [weak self] in
            async let snapshotCount = DiskFreedMeasurer.localSnapshotCount()
            let (items, notice) = await Self.scan(category)
            let snapshots = await snapshotCount > 0
            guard let self, !Task.isCancelled else { return }
            self.snapshotsPresent = snapshots
            let previous = Dictionary(self.items(category).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            // Keep sizes from the last scan until the new measurement arrives.
            let merged = items.map { item -> CleanupItem in
                guard item.frees == nil, let old = previous[item.id] else { return item }
                var item = item
                item.frees = old.frees
                item.holds = old.holds
                return item
            }
            self.states[category] = CategoryState(
                items: merged.sorted(by: Self.displayOrder), isScanning: false,
                pendingMeasurements: 0, notice: notice, scannedAt: Date()
            )
            self.selection.formIntersection(Set(merged.map(\.id)) .union(self.otherCategoryIDs(category)))
            await self.measure(items.filter { !$0.measurePaths.isEmpty }, in: category, snapshots: snapshots)
        }
    }

    private func otherCategoryIDs(_ category: CleanupCategory) -> Set<String> {
        Set(states.filter { $0.key != category }.flatMap { $0.value.items.map(\.id) })
    }

    @concurrent
    private static func scan(_ category: CleanupCategory) async -> ([CleanupItem], String?) {
        switch category {
        case .worktrees: return (await WorktreeCleanupProvider.scan(), nil)
        case .simulators: return await SimulatorCleanupProvider.scan()
        case .docker: return await DockerCleanupProvider.scan()
        case .buildOutput: return (await BuildOutputCleanupProvider.scan(), nil)
        }
    }

    /// Measures items four at a time off the main actor, updating each row as it finishes.
    private func measure(_ items: [CleanupItem], in category: CleanupCategory, snapshots: Bool) async {
        states[category]?.pendingMeasurements = items.count
        await withTaskGroup(of: (String, FreedSpace?).self) { group in
            var queue = items[...]
            func startNext() {
                guard let item = queue.popFirst() else { return }
                group.addTask { @concurrent in
                    (item.id, try? DiskFreedMeasurer.measure(item.measurePaths) { try Task.checkCancellation() })
                }
            }
            for _ in 0..<4 { startNext() }
            for await (id, space) in group {
                guard !Task.isCancelled else { group.cancelAll(); return }
                if let space, let index = states[category]?.items.firstIndex(where: { $0.id == id }) {
                    states[category]?.items[index].frees = space.frees(snapshotsPresent: snapshots)
                    states[category]?.items[index].holds = space.allocated
                }
                states[category]?.pendingMeasurements -= 1
                startNext()
            }
        }
        states[category]?.items.sort(by: Self.displayOrder)
    }

    /// Largest first; unmeasured items last.
    nonisolated static func displayOrder(_ lhs: CleanupItem, _ rhs: CleanupItem) -> Bool {
        (lhs.frees ?? -1) > (rhs.frees ?? -1)
    }

    /// Removes the selected items in a category, one at a time, then rescans it.
    func removeSelected(in category: CleanupCategory) async {
        let targets = selectedItems(in: category)
        guard !targets.isEmpty, !isRemoving else { return }
        isRemoving = true
        var outcomes: [CleanupOutcome] = []
        for item in targets {
            do {
                let detail = try await CleanupExecutor.perform(item)
                outcomes.append(CleanupOutcome(item: item, succeeded: true, detail: detail))
            } catch {
                CleanupExecutor.log("FAILED \(item.category.rawValue) \(item.title) — \(error.localizedDescription)")
                outcomes.append(CleanupOutcome(item: item, succeeded: false, detail: error.localizedDescription))
            }
        }
        lastOutcomes = outcomes
        selection.subtract(targets.map(\.id))
        isRemoving = false
        refresh(category)
    }

    func dismissOutcomes() { lastOutcomes = [] }
}
