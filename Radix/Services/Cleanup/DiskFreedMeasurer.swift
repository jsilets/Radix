import Darwin
import Foundation

/// How much disk space deleting a set of paths gives back on APFS.
///
/// A plain allocated-size sum (what `du` and the disk map report) counts every APFS
/// clone and every hard link at full size. bun, pnpm, and Xcode create both, so that
/// sum can be many times what a delete frees. This is the Swift form of the
/// `disk-real` tool in harness-parity.
nonisolated struct FreedSpace: Sendable, Equatable {
    /// Bytes only these paths hold. A delete frees at least this much right now.
    var now: Int64 = 0
    /// Estimate of what returns once local snapshots are purged. Equals `now` when
    /// no snapshot exists. It overcounts a clone that was modified after it was made.
    var later: Int64 = 0
    /// Allocated bytes with hard links counted once.
    var allocated: Int64 = 0
    var fileCount: Int = 0

    /// The number to show as "Frees".
    func frees(snapshotsPresent: Bool) -> Int64 { snapshotsPresent ? later : now }

    static func + (lhs: FreedSpace, rhs: FreedSpace) -> FreedSpace {
        FreedSpace(
            now: lhs.now + rhs.now,
            later: lhs.later + rhs.later,
            allocated: lhs.allocated + rhs.allocated,
            fileCount: lhs.fileCount + rhs.fileCount
        )
    }
}

nonisolated enum DiskFreedMeasurer {
    private struct FileShare {
        var allocated: Int64
        var privateBytes: Int64
        var cloneID: UInt64
        var cloneRefs: UInt32
        var seen: UInt32 = 0
        var links: UInt32 = 0
    }

    private struct InodeKey: Hashable {
        let device: dev_t
        let inode: ino_t
    }

    private struct CloneGroup {
        var members: UInt32
        var seen: UInt32 = 0
        var shared: Int64 = 0
    }

    /// Measures all paths as one set: deleting them together.
    /// - Parameter cancellationCheck: called every 512 files; throw to stop.
    static func measure(_ urls: [URL], cancellationCheck: () throws -> Void = {}) throws -> FreedSpace {
        var result = FreedSpace()
        var linked: [InodeKey: FileShare] = [:]
        var clones: [InodeKey: CloneGroup] = [:]

        func addClone(device: dev_t, id: UInt64, refs: UInt32, shared: Int64) {
            let key = InodeKey(device: device, inode: ino_t(id))
            var group = clones[key] ?? CloneGroup(members: refs)
            group.seen += 1
            group.shared = max(group.shared, shared)
            clones[key] = group
        }

        let existing = urls.map(\.path).filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty else { return result }
        var cPaths: [UnsafeMutablePointer<CChar>?] = existing.map { strdup($0) } + [nil]
        defer { cPaths.forEach { free($0) } }
        guard let fts = fts_open(&cPaths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return result }
        defer { fts_close(fts) }

        var counter = 0
        while let entry = fts_read(fts) {
            let info = Int32(entry.pointee.fts_info)
            if info == FTS_DP || info == FTS_DNR || info == FTS_ERR || info == FTS_NS { continue }
            guard let statPointer = entry.pointee.fts_statp else { continue }
            let st = statPointer.pointee
            let allocated = Int64(st.st_blocks) * 512
            guard (st.st_mode & S_IFMT) == S_IFREG else {
                result.allocated += allocated
                result.now += allocated
                result.later += allocated
                continue
            }
            counter += 1
            if counter.isMultiple(of: 512) { try cancellationCheck() }
            result.fileCount += 1

            let path = String(cString: entry.pointee.fts_path)
            let attributes = cloneAttributes(path: path)
            let privateBytes = min(attributes?.privateBytes ?? allocated, allocated)
            let cloneID = attributes?.cloneID ?? 0
            let cloneRefs = attributes?.cloneRefs ?? 1

            if st.st_nlink > 1 {
                let key = InodeKey(device: st.st_dev, inode: st.st_ino)
                var share = linked[key] ?? FileShare(
                    allocated: allocated, privateBytes: privateBytes,
                    cloneID: cloneID, cloneRefs: cloneRefs, links: UInt32(st.st_nlink)
                )
                if share.seen == 0 { result.allocated += allocated }
                share.seen += 1
                linked[key] = share
                continue
            }
            result.allocated += allocated
            result.now += privateBytes
            result.later += cloneRefs <= 1 ? allocated : privateBytes
            if cloneRefs > 1 {
                addClone(device: st.st_dev, id: cloneID, refs: cloneRefs, shared: allocated - privateBytes)
            }
        }

        // A hard-linked file comes back only if every link to it was inside the set.
        for (key, share) in linked where share.seen >= share.links {
            result.now += share.privateBytes
            result.later += share.cloneRefs <= 1 ? share.allocated : share.privateBytes
            if share.cloneRefs > 1 {
                addClone(device: key.device, id: share.cloneID, refs: share.cloneRefs,
                         shared: share.allocated - share.privateBytes)
            }
        }
        // A clone group's shared blocks come back once if all its members were inside.
        for group in clones.values where group.seen >= group.members {
            result.now += group.shared
            result.later += group.shared
        }
        return result
    }

    private struct CloneAttributes {
        let privateBytes: Int64
        let cloneID: UInt64?
        let cloneRefs: UInt32?
    }

    /// Reads the APFS private size, clone ID, and clone member count of one file.
    private static func cloneAttributes(path: String) -> CloneAttributes? {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        request.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE | ATTR_CMNEXT_CLONEID | ATTR_CMNEXT_CLONE_REFCNT)
        var buffer = [UInt8](repeating: 0, count: 64)
        let status = buffer.withUnsafeMutableBytes { raw in
            getattrlist(path, &request, raw.baseAddress, raw.count,
                        UInt32(FSOPT_NOFOLLOW) | UInt32(FSOPT_ATTR_CMN_EXTENDED))
        }
        guard status == 0 else { return nil }
        return buffer.withUnsafeBytes { raw -> CloneAttributes? in
            // Layout: UInt32 length, attribute_set_t (five UInt32), then the returned
            // attributes in bit order. An attribute the volume does not report is absent.
            let returnedFork = raw.loadUnaligned(fromByteOffset: 4 + 16, as: UInt32.self)
            var offset = 24
            guard returnedFork & UInt32(ATTR_CMNEXT_PRIVATESIZE) != 0 else { return nil }
            let privateBytes = raw.loadUnaligned(fromByteOffset: offset, as: Int64.self)
            offset += 8
            var cloneID: UInt64?
            if returnedFork & UInt32(ATTR_CMNEXT_CLONEID) != 0 {
                cloneID = raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
                offset += 8
            }
            var cloneRefs: UInt32?
            if returnedFork & UInt32(ATTR_CMNEXT_CLONE_REFCNT) != 0 {
                cloneRefs = raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
            }
            return CloneAttributes(privateBytes: privateBytes, cloneID: cloneID, cloneRefs: cloneRefs)
        }
    }

    /// Local APFS snapshots on the startup volume (Time Machine takes them hourly).
    @concurrent
    static func localSnapshotCount() async -> Int {
        guard let result = try? await CommandRunner.run("tmutil", ["listlocalsnapshots", "/"], timeout: 10) else { return 0 }
        return result.stdout.split(separator: "\n").filter { $0.hasSuffix(".local") }.count
    }
}
