import Testing
import ReixABI
@testable import ReixFS

@Suite("Table blocks agree with the sum region", .serialized)
struct TableTrustTests {
    private enum Damage: CaseIterable { case stale, misdirected, rot }
    private static let block = Int(FSLayout.blockSize)

    @Test("a dirty mount refuses a stale, misdirected or rotted table without writing")
    func dirtyMountRefuses() {
        for damage in Damage.allCases {
            withDamage(damage) { _, disk in
                let before = disk.writes
                remount(disk) { fs, found in
                    #expect(fs == nil, "\(damage)")
                    #expect(isCorrupt(found), "\(damage): \(found)")
                }
                #expect(disk.writes == before, "\(damage)")
            }
        }
    }

    @Test("clean mounts refuse at the scan or the sealed table's first read")
    func cleanMountRefuses() {
        for damage in Damage.allCases {
            for sealed in [false, true] {
                withDamage(damage, clean: true) { fs, disk in
                    if !sealed { disk.unseal(fs.plan) }
                    let before = disk.writes
                    remount(disk) { again, found in
                        if sealed {
                            guard var again else { Issue.record("\(found)"); return }
                            #expect(again.readBlock(again.plan.tableStart + 1, into: again.metaBuffer) == .quarantined, "\(damage)")
                            #expect(again.corrupted)
                        } else {
                            #expect(again == nil, "\(damage)")
                            #expect(isCorrupt(found), "\(found)")
                        }
                    }
                    #expect(disk.writes == before + (sealed ? 1 : 0))
                }
            }
        }
    }

    @Test("every scrub refuses the table even before in-memory sums are known")
    func scrubRefuses() {
        for damage in Damage.allCases {
            for depth in [FileSystem<MemoryDisk>.Scrub.blocks, .everything, .data] {
                for known in [false, true] {
                    withDamage(damage) { fs, disk in
                        fs.sumsKnown = known
                        let before = disk.writes
                        var findings = fs.scan(depth)
                        #expect(!findings.complete && !findings.safeToServe, "\(damage) \(depth) \(known)")
                        #expect(fs.corrupted)
                        findings.reclaimable = 1
                        #expect(fs.repair(findings) == .notFound)
                        #expect(disk.writes == before)
                    }
                }
            }
        }
    }

    @Test("format and coalesced table changes keep every on-disk table sum true")
    func sumsFollowWrites() {
        withDisk { fs, disk in
            checkSums(fs, disk)
            #expect(fs.begin() == .ok)
            var root = fs.object(FSLayout.rootObject)!
            for _ in 0..<3 {
                root.created += 1
                #expect(fs.store(root, at: FSLayout.rootObject) == .ok)
                checkStagedSum(&fs)
            }
            #expect(fs.commit() == .ok)
            checkSums(fs, disk)
            fs.dropCache()
            #expect(fs.scan(.data).safeToServe)
            remount(disk) { again, found in
                #expect(again != nil, "\(found)")
            }
        }
    }

    @Test("aborting table and checksum images leaves their old home bytes")
    func abortKeepsBothOld() {
        withDisk { fs, disk in
            let table = disk.block(fs.plan.tableStart)
            let sum = disk.block(fs.sumBlock(of: fs.plan.tableStart))
            #expect(fs.begin() == .ok)
            var root = fs.object(FSLayout.rootObject)!
            root.created += 1
            #expect(fs.store(root, at: FSLayout.rootObject) == .ok)
            checkStagedSum(&fs)
            let writes = disk.writes
            fs.abort()
            #expect(disk.writes == writes)
            #expect(disk.block(fs.plan.tableStart) == table)
            #expect(disk.block(fs.sumBlock(of: fs.plan.tableStart)) == sum)
            fs.dropCache()
            #expect(fs.scan(.everything).safeToServe)
        }
    }

    @Test("a dirty mount still accepts an old table paired with its old sum block")
    func stalePairHasNoAnchor() {
        for clean in [false, true] {
            withDisk { fs, disk in
                let home = fs.plan.tableStart
                let table = disk.block(home)
                let sum = disk.block(fs.sumBlock(of: home))
                let old = fs.object(FSLayout.rootObject)!.created
                changeRoot(&fs)
                if clean { #expect(fs.unmount() == .ok) }
                disk.put(table, block: home)
                disk.put(sum, block: fs.sumBlock(of: home))
                remount(disk) { again, found in
                    if clean {
                        #expect(again == nil)
                        #expect(isCorrupt(found))
                    } else {
                        guard var again else { Issue.record("\(found)"); return }
                        #expect(again.object(FSLayout.rootObject)?.created == old)
                        #expect(again.scan(.data).safeToServe)
                    }
                }
            }
        }
    }

    @Test("a table-only change prints its cold-cache traffic")
    func tableChangeCost() {
        withDisk { fs, disk in
            fs.dropCache()
            let before = (disk.reads, disk.writes, disk.flushes)
            changeRoot(&fs)
            #expect((disk.reads - before.0, disk.writes - before.1, disk.flushes - before.2) == (2, 7, 4))
            print("table-only reads \(disk.reads - before.0) writes \(disk.writes - before.1) barriers \(disk.flushes - before.2)")
        }
    }

    private func checkStagedSum(_ fs: inout FileSystem<MemoryDisk>) {
        #expect(fs.readBlock(fs.plan.tableStart, into: fs.metaBuffer) == .ok)
        let actual = FSChecksum.over(fs.metaBuffer, count: Self.block)
        #expect(fs.dataSum(of: fs.plan.tableStart).sum == actual)
    }

    private func checkSums(_ fs: FileSystem<MemoryDisk>, _ disk: MemoryDisk) {
        for home in fs.plan.tableStart..<fs.plan.sumStart {
            let content = disk.block(home)
            let actual = content.withUnsafeBytes { FSChecksum.over($0.baseAddress!, count: Self.block) }
            let page = disk.block(fs.sumBlock(of: home))
            let expected = page.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: fs.sumOffset(of: home), as: UInt32.self) }
            #expect(actual == expected, "table \(home)")
        }
    }

    private func withDamage(_ damage: Damage, clean: Bool = false,
                            _ body: (inout FileSystem<MemoryDisk>, MemoryDisk) -> Void) {
        withDisk { fs, disk in
            let home = fs.plan.tableStart + 1
            let old = disk.block(home)
            changeTable(&fs, home, byte: 0x31)
            changeTable(&fs, home + 1, byte: 0x72)
            let other = disk.block(home + 1)
            if clean { #expect(fs.unmount() == .ok); #expect(fs.namedSeal != 0) }
            switch damage {
                case .stale: disk.put(old, block: home)
                case .misdirected: disk.put(other, block: home)
                case .rot:
                    let at = Int(home) * Self.block + 60
                    disk.poke(disk.byte(at: at) ^ 0x5A, at: at)
            }
            fs.dropCache()
            body(&fs, disk)
        }
    }

    private func changeTable(_ fs: inout FileSystem<MemoryDisk>, _ home: UInt32, byte: UInt8) {
        #expect(fs.readBlock(home, into: fs.metaBuffer) == .ok)
        fs.metaBuffer.storeBytes(of: byte, toByteOffset: 60, as: UInt8.self)
        #expect(fs.begin() == .ok)
        #expect(fs.finish(fs.stageStructuralBlock(home, from: fs.metaBuffer)) == .ok)
    }

    private func changeRoot(_ fs: inout FileSystem<MemoryDisk>) {
        var root = fs.object(FSLayout.rootObject)!
        root.created += 1
        #expect(fs.begin() == .ok)
        #expect(fs.finish(fs.store(root, at: FSLayout.rootObject)) == .ok)
    }

    private func withDisk(_ body: (inout FileSystem<MemoryDisk>, MemoryDisk) -> Void) {
        let disk = MemoryDisk(sectors: 32768)
        let space = UnsafeMutableRawPointer.allocate(byteCount: FileSystem<MemoryDisk>.scratchBytes, alignment: 8)
        defer { space.deallocate() }
        guard var fs = FileSystem.format(disk, scratch: space).disk else { Issue.record("format"); return }
        body(&fs, disk)
    }

    private func remount(_ disk: MemoryDisk, _ body: (FileSystem<MemoryDisk>?, FSMount) -> Void) {
        let space = UnsafeMutableRawPointer.allocate(byteCount: FileSystem<MemoryDisk>.scratchBytes, alignment: 8)
        defer { space.deallocate() }
        let mounted = FileSystem.mount(disk, scratch: space)
        body(mounted.disk, mounted.found)
    }

    private func isCorrupt(_ found: FSMount) -> Bool {
        if case .corrupt = found { return true }
        return false
    }
}
