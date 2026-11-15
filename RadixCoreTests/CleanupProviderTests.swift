import Foundation
import Testing
@testable import RadixCore

@Suite struct CleanupParserTests {
    @Test func simulatorDevicesParseStatusAndSafety() {
        let now = try! Date("2026-11-14T00:00:00Z", strategy: .iso8601)
        let json = """
        {"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-26-5":[
          {"dataPath":"/tmp/sims/AAA/data","udid":"AAA","lastUsedAt":"2026-09-01T00:00:00Z","isAvailable":true,"state":"Shutdown","name":"iPhone Old"},
          {"dataPath":"/tmp/sims/BBB/data","udid":"BBB","lastUsedAt":"2026-11-13T00:00:00Z","isAvailable":true,"state":"Booted","name":"iPhone Now"},
          {"dataPath":"/tmp/sims/CCC/data","udid":"CCC","isAvailable":false,"state":"Shutdown","name":"iPhone Orphan"}]}}
        """
        let items = Dictionary(uniqueKeysWithValues: SimulatorCleanupProvider.parseDevices(json, now: now).map { ($0.title, $0) })
        #expect(items["iPhone Old"]?.safety == .safe)
        #expect(items["iPhone Old"]?.status == "Unused for 74 days")
        #expect(items["iPhone Old"]?.subtitle == "iOS 26.5")
        #expect(items["iPhone Old"]?.measurePaths.map(\.standardizedFileURL.path) == ["/tmp/sims/AAA"])
        #expect(items["iPhone Now"]?.blockedReason == "Running now")
        #expect(items["iPhone Orphan"]?.status == "Its runtime is not installed")
    }

    @Test func simulatorRuntimeUsesReportedSize() {
        let json = """
        {"E6A7":{"identifier":"E6A7","runtimeIdentifier":"com.apple.CoreSimulator.SimRuntime.iOS-26-5",
                 "sizeBytes":8494282293,"deletable":true,"lastUsedAt":"2026-11-04T20:09:09Z"}}
        """
        let item = SimulatorCleanupProvider.parseRuntimes(json, deviceCounts: ["com.apple.CoreSimulator.SimRuntime.iOS-26-5": 11]).first
        #expect(item?.title == "iOS 26.5 runtime")
        #expect(item?.frees == 8_494_282_293)
        #expect(item?.subtitle.hasPrefix("11 devices use it") == true)
        #expect(item?.action == .deleteSimulatorRuntime(identifier: "E6A7"))
    }

    @Test func dockerVolumesImagesAndCache() {
        let json = """
        {"Volumes":[
           {"Name":"backend_postgres","Links":"1","Size":"17.09GB","Labels":"com.docker.compose.project=backend,com.docker.compose.volume=postgres"},
           {"Name":"0c1fcd4cfc70ed884ea2","Links":"0","Size":"60B","Labels":"com.docker.volume.anonymous="},
           {"Name":"live_data","Links":"1","Size":"1.374kB","Labels":""}],
         "Containers":[
           {"Names":"backend-postgres-1","Mounts":"backend_postgres","State":"exited"},
           {"Names":"live-1","Mounts":"other,live_data","State":"running"}],
         "Images":[
           {"Repository":"timescale/timescaledb-ha","Containers":"0","UniqueSize":"2.941GB"},
           {"Repository":"redis","Containers":"1","UniqueSize":"40MB"}],
         "BuildCache":[{"Size":"1.5GB","InUse":false},{"Size":"9GB","InUse":true}]}
        """
        let items = Dictionary(uniqueKeysWithValues: DockerCleanupProvider.parse(json).map { ($0.id, $0) })
        let postgres = items["docker-volume:backend_postgres"]
        #expect(postgres?.frees == 17_090_000_000)
        #expect(postgres?.safety == .holdsData)
        #expect(postgres?.subtitle == "Compose project backend")
        #expect(postgres?.action == .deleteDockerVolume(name: "backend_postgres", stoppedContainers: ["backend-postgres-1"]))
        #expect(items["docker-volume:0c1fcd4cfc70ed884ea2"]?.safety == .review)
        #expect(items["docker-volume:live_data"]?.blockedReason == "A running container uses it")
        #expect(items["docker-images"]?.frees == 2_941_000_000)
        #expect(items["docker-buildcache"]?.frees == 1_500_000_000)
    }

    @Test func worktrunkPruneJSONKeysByWorktreePath() {
        let json = """
        [{"branch":"old","path":null,"kind":"branch_only","reason":"ancestor of","target":"origin/main"},
         {"branch":"feat","path":"/tmp/repo-feat","kind":"worktree","reason":"all changes in","target":"origin/main"}]
        """
        let merged = WorktreeCleanupProvider.parseWorktrunkPrune(json)
        #expect(merged.count == 1)
        #expect(merged["/tmp/repo-feat"] == .init(reason: "all changes in", target: "origin/main"))
    }

    @Test func worktreeListDropsMainAndReadsFlags() {
        let porcelain = """
        worktree /repo
        HEAD 1111
        branch refs/heads/main

        worktree /repo/.worktrees/a
        HEAD 2222
        branch refs/heads/feat/a
        locked agent is running

        worktree /tmp/gone
        HEAD 3333
        detached
        prunable gitdir file points to non-existent location

        """
        let worktrees = GitCheckouts.parseWorktreeList(porcelain)
        #expect(worktrees.map(\.path.path) == ["/repo/.worktrees/a", "/tmp/gone"])
        #expect(worktrees[0].branch == "feat/a" && worktrees[0].isLocked)
        #expect(worktrees[1].branch == nil && worktrees[1].isPrunable)
    }

    @Test func dockerSizesUseDecimalUnits() {
        #expect(DockerCleanupProvider.parseSize("17.09GB") == 17_090_000_000)
        #expect(DockerCleanupProvider.parseSize("1.374kB") == 1_374)
        #expect(DockerCleanupProvider.parseSize("60B") == 60)
        #expect(DockerCleanupProvider.parseSize("N/A") == nil)
    }
}

/// Runs the worktree provider, backup, and removal on a real temporary git setup.
@Suite(.serialized) struct WorktreeCleanupIntegrationTests {
    private func git(_ arguments: [String], in directory: URL) async throws -> String {
        let result = try await CommandRunner.run("git", arguments, in: directory)
        #expect(result.succeeded, "git \(arguments.joined(separator: " ")): \(result.stderr)")
        return result.stdout
    }

    private func commit(_ file: String, in directory: URL) async throws {
        try UUID().uuidString.write(to: directory.appendingPathComponent(file), atomically: true, encoding: .utf8)
        _ = try await git(["add", file], in: directory)
        _ = try await git(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", file], in: directory)
    }

    /// A bare remote, a clone of it, and three worktrees: merged, dirty, and unpushed.
    private func makeFixture() async throws -> (root: URL, repo: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WorktreeCleanup-\(UUID().uuidString)")
        let remote = root.appendingPathComponent("remote.git"), repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try await git(["init", "-q", "--bare", "-b", "main", remote.path], in: root)
        _ = try await git(["clone", "-q", remote.path, repo.path], in: root)
        _ = try await git(["checkout", "-q", "-b", "main"], in: repo)
        try await commit("base", in: repo)
        _ = try await git(["push", "-q", "-u", "origin", "main"], in: repo)
        _ = try await git(["remote", "set-head", "origin", "main"], in: repo)

        for name in ["merged", "dirty", "unpushed"] {
            _ = try await git(["worktree", "add", "-q", "-b", name, root.appendingPathComponent(name).path], in: repo)
        }
        let merged = root.appendingPathComponent("merged")
        try await commit("feature", in: merged)
        _ = try await git(["merge", "-q", "--ff-only", "merged"], in: repo)
        _ = try await git(["push", "-q", "origin", "main"], in: repo)
        try "edit".write(to: root.appendingPathComponent("dirty/scratch.txt"), atomically: true, encoding: .utf8)
        try await commit("local-only", in: root.appendingPathComponent("unpushed"))
        return (root, repo)
    }

    @Test func classifiesSavesAndRemoves() async throws {
        let (root, repo) = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try #require(await GitCheckouts.repository(at: repo))
        let items = Dictionary(uniqueKeysWithValues: await WorktreeCleanupProvider.items(for: repository).map { ($0.title, $0) })

        #expect(items["merged"]?.safety == .safe)
        #expect(items["merged"]?.status.hasPrefix("Merged") == true)
        #expect(items["dirty"]?.safety == .holdsData)
        #expect(items["dirty"]?.status == "1 uncommitted file")
        #expect(items["unpushed"]?.safety == .holdsData)
        #expect(items["unpushed"]?.status == "1 commit on no remote")

        // Backup: the unpushed commit lands in a bundle that git can read back.
        let archive = root.appendingPathComponent("archive")
        let saved = try await LocalWorkSaver.save(root.appendingPathComponent("unpushed"), into: archive)
        let bundle = saved.appendingPathComponent("local.bundle")
        #expect(FileManager.default.fileExists(atPath: bundle.path))
        let heads = try await git(["bundle", "list-heads", bundle.path], in: root)
        #expect(heads.contains("HEAD"))

        // Removal of the merged worktree also deletes its branch.
        let detail = try await CleanupExecutor.perform(try #require(items["merged"]))
        #expect(detail.contains("deleted merged branch merged"))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("merged").path))
        let branches = try await git(["branch", "--list", "merged"], in: repo)
        #expect(branches.isEmpty)
    }

    @Test func buildOutputFindsOnlyRebuildableFolders() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BuildOutput-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = FileManager.default
        for folder in ["node_modules/pkg", "apps/web/.next/cache", "crates/a/target/debug", "notes/target", "src"] {
            try manager.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try "".write(to: root.appendingPathComponent("crates/a/Cargo.toml"), atomically: true, encoding: .utf8)
        // The folder listing may report /private/var where the test holds /var, so cut at the unique name.
        let found = Set(BuildOutputCleanupProvider.outputFolders(in: root).map {
            String($0.path.components(separatedBy: root.lastPathComponent + "/").last ?? "")
        })
        // "notes/target" has no Cargo.toml beside it, so it is not build output.
        #expect(found == ["node_modules", "apps/web/.next", "crates/a/target"], "found \(found.sorted())")
    }
}
