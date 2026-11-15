import Foundation
import Testing
@testable import RadixCore

// Read-only scan of this Mac with every cleanup provider. Prints one line per item.
// Run: RADIX_CLEANUP_PROBE=1 swift test --filter CleanupScanProbe
@Suite struct CleanupScanProbe {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RADIX_CLEANUP_PROBE"] == "1"))
    func printItems() async throws {
        let snapshots = await DiskFreedMeasurer.localSnapshotCount() > 0
        var items = await WorktreeCleanupProvider.scan()
        items += await SimulatorCleanupProvider.scan().items
        items += await DockerCleanupProvider.scan().items
        items += await BuildOutputCleanupProvider.scan()
        for var item in items {
            if item.frees == nil, !item.measurePaths.isEmpty {
                item.frees = try DiskFreedMeasurer.measure(item.measurePaths).frees(snapshotsPresent: snapshots)
            }
            let size = item.frees.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "?"
            print("PROBE\t\(item.category.rawValue)\t\(item.safety)\t\(size)\t\(item.title)\t\(item.status)\t\(item.blockedReason ?? "")")
        }
    }
}
