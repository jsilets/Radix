import Foundation
import Testing
@testable import RadixCore

/// Known-answer tests on fresh files. Files made after the newest local snapshot
/// share no blocks with it, so the APFS private size is exact here.
@Suite struct DiskFreedMeasurerTests {
    private let mib: Int64 = 1 << 20

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskFreedMeasurerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeRandom(_ url: URL, mebibytes: Int) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var bytes = [UInt8](repeating: 0, count: mebibytes << 20)
        arc4random_buf(&bytes, bytes.count)
        try Data(bytes).write(to: url)
    }

    private func clone(_ source: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        #expect(clonefile(source.path, destination.path, 0) == 0)
    }

    /// Allocation rounds up to blocks, so compare within one MiB.
    private func expectMiB(_ bytes: Int64, _ expected: Int64, _ label: String) {
        #expect(abs(bytes - expected * mib) < mib, "\(label): \(bytes / mib) MiB, expected \(expected)")
    }

    @Test func projectClonedFromOutsideCacheFreesOnlyItsOwnFiles() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("cache"), project = root.appendingPathComponent("project")
        for index in 0..<4 {
            try writeRandom(cache.appendingPathComponent("f\(index)"), mebibytes: 5)
            try clone(cache.appendingPathComponent("f\(index)"), to: project.appendingPathComponent("node_modules/f\(index)"))
        }
        try writeRandom(project.appendingPathComponent("src/main"), mebibytes: 3)

        let projectOnly = try DiskFreedMeasurer.measure([project])
        expectMiB(projectOnly.now, 3, "project alone")
        expectMiB(projectOnly.allocated, 23, "project allocated")

        let together = try DiskFreedMeasurer.measure([project, cache])
        expectMiB(together.now, 23, "project and cache together")
    }

    @Test func hardLinkFreesOnlyWhenEveryLinkIsInside() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let inside = root.appendingPathComponent("inside"), outside = root.appendingPathComponent("outside")
        try writeRandom(inside.appendingPathComponent("a"), mebibytes: 4)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: inside.appendingPathComponent("a"), to: outside.appendingPathComponent("a"))
        try FileManager.default.linkItem(at: inside.appendingPathComponent("a"), to: inside.appendingPathComponent("b"))

        let insideOnly = try DiskFreedMeasurer.measure([inside])
        expectMiB(insideOnly.now, 0, "link outside keeps the data")
        expectMiB(insideOnly.allocated, 4, "two links inside count once")
        expectMiB(try DiskFreedMeasurer.measure([inside, outside]).now, 4, "all links inside")
    }

    @Test func modifiedCloneFreesOnlyItsChangedBlocks() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original"), copy = root.appendingPathComponent("copy")
        try writeRandom(original, mebibytes: 8)
        try clone(original, to: copy)
        let handle = try FileHandle(forWritingTo: copy)
        var changed = [UInt8](repeating: 0, count: 2 << 20)
        arc4random_buf(&changed, changed.count)
        try handle.write(contentsOf: Data(changed))
        try handle.close()

        expectMiB(try DiskFreedMeasurer.measure([copy]).now, 2, "only rewritten blocks are private")
    }
}
