import Foundation
import Testing
@testable import RadixCore

// Prints the allocated size that Radix's scan engine reports for each path in
// RADIX_PARITY_PATHS (colon-separated), so it can be compared with `disk-real`.
// Run: RADIX_PARITY_PATHS=/a:/b swift test --filter DiskRealParityProbe
@Suite struct DiskRealParityProbe {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RADIX_PARITY_PATHS"] != nil))
    func printAllocatedSizes() async throws {
        let paths = (ProcessInfo.processInfo.environment["RADIX_PARITY_PATHS"] ?? "")
            .split(separator: ":").map(String.init)
        var options = ScanOptions()
        options.autoSummarizeDirectories = false
        for path in paths {
            let engine = ScanEngine()
            var snapshot: ScanSnapshot?
            let started = Date()
            for try await event in engine.scan(target: ScanTarget(url: URL(fileURLWithPath: path)), options: options) {
                if case .finished(let finished) = event { snapshot = finished }
            }
            let root = try #require(snapshot).treeStore.root
            let seconds = Date().timeIntervalSince(started)
            print("RADIX_PARITY\t\(root.allocatedSize)\t\(root.logicalSize)\t\(String(format: "%.1f", seconds))s\t\(path)")
        }
    }
}
