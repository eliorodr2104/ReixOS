import Testing
import ReixABI
@testable import ReixFS

/// The superblock's root over the sum region: moved by the transaction that
/// moves the region, checked by every mount that has no seal, and by a scrub.
@Suite("The sum region's root", .serialized)
struct SumRootTests {
    private static let sectors: UInt64 = 32768
    private static let block = Int(FSLayout.blockSize)

    @Test("the newer copy names the region's root and the older one is a step behind")
    func rootFollowsTheRegion() {
        withDisk { fs, disk in
            let formatted = copies(disk)
            #expect(formatted.a.root == formatted.b.root)
            #expect(disk.rootAgrees())

            changeRoot(&fs)
            let changed = copies(disk)
            let newer = changed.a.generation > changed.b.generation ? changed.a : changed.b
            let older = changed.a.generation > changed.b.generation ? changed.b : changed.a
            #expect(disk.rootAgrees())
            #expect(newer.root != formatted.a.root)
            #expect(older.root == formatted.a.root)

            // A change that moves no sum block moves no root and no superblock.
            #expect(fs.begin() == .ok)
            #expect(fs.finish(fs.stageStructuralBlock(fs.plan.bitmapStart, from: bitmap(&fs))) == .ok)
            #expect(copies(disk).a.generation == changed.a.generation)
            #expect(copies(disk).b.generation == changed.b.generation)

            #expect(fs.unmount() == .ok)
            #expect(disk.rootAgrees())
        }
    }


    @Test("one lost copy is not a lost disk, unless the copy left names an older region")
    func olderCopyAlone() {
        for moment in ["formatted", "changed", "unmounted"] {
            for lost in [FSLayout.superblockA, FSLayout.superblockB] {
                withDisk { fs, disk in
                    if moment != "formatted" { changeRoot(&fs) }
                    if moment == "unmounted" { #expect(fs.unmount() == .ok) }

                    let both = copies(disk)
                    let left = lost == FSLayout.superblockA ? both.b : both.a
                    let newer = both.a.generation > both.b.generation ? FSLayout.superblockA : FSLayout.superblockB
                    disk.poke(UInt8(0x5A), at: Int(lost) * Self.block + FSSuperblockField.commit)

                    let writes = disk.writes
                    remount(disk) { again, found in
                        let where_ = "\(moment), copy \(lost) lost"

                        // Only right after a change is the other copy a region behind.
                        if moment == "changed" && lost == newer {
                            #expect(again == nil, "\(where_)")
                            #expect(isCorrupt(found), "\(where_): \(found)")
                            #expect(disk.writes == writes)
                        } else {
                            #expect(again != nil, "\(where_): \(found)")
                            #expect(left.root == regionRoot(disk))
                        }
                    }
                }
            }
        }
    }


    @Test("a write torn at any request of a table change leaves a disk whose root agrees")
    func tornAtEveryRequest() {
        var requests = 0
        withDisk { fs, disk in
            let before = disk.reads + disk.writes + disk.flushes
            changeRoot(&fs)
            requests = disk.reads + disk.writes + disk.flushes - before
        }
        #expect(requests > 0)

        // A tear lands the first half of a block, which holds every field of a
        // superblock: the root image is on the medium and the device said no.
        var landedEarly = 0

        for stop in 1...requests {
            withDisk { fs, disk in
                let old = fs.object(FSLayout.rootObject)!.created
                let generation = max(copies(disk).a.generation, copies(disk).b.generation)
                disk.tearOnly(stop)
                changeRoot(&fs, expecting: nil)
                disk.recover()

                let header = disk.block(FSLayout.journalHeaderBlock).withUnsafeBytes {
                    FSJournal(reading: $0.baseAddress!)
                }
                let newest = max(copies(disk).a.generation, copies(disk).b.generation)
                if header.state == .committed, newest > generation { landedEarly += 1 }

                remount(disk) { again, found in
                    guard var again else { Issue.record("stop \(stop): \(found)"); return }
                    let created = again.object(FSLayout.rootObject)?.created
                    #expect(created == old || created == old + 1, "stop \(stop)")
                    #expect(disk.rootAgrees(), "stop \(stop)")
                    #expect(again.scan(.data).safeToServe, "stop \(stop)")
                }
            }
        }

        // The sweep reached the root image's own write: it landed while the
        // journal still held the transaction, and the next mount agreed anyway.
        #expect(landedEarly > 0)
    }


    @Test("a data scrub reads the whole region and refuses a page nothing uses")
    func scrubFindsTheRegion() {
        withDisk { fs, disk in
            let home = fs.plan.dataStart - 1
            let at = Int(home) * Self.block + 400
            disk.poke(disk.byte(at: at) ^ 0x10, at: at)

            let writes = disk.writes
            #expect(fs.scan(.everything).safeToServe)

            var findings = fs.scan(.data)
            #expect(!findings.complete && !findings.safeToServe)
            #expect(fs.corrupted)
            findings.reclaimable = 1
            #expect(fs.repair(findings) == .notFound)
            #expect(disk.writes == writes)
        }
    }


    @Test("a seal whose sum checksums are not the superblock's root is refused")
    func sealContradictsRoot() {
        withDisk { fs, disk in
            changeRoot(&fs)
            #expect(fs.unmount() == .ok)
            #expect(fs.namedSeal != 0)

            // The clean copy, rewritten whole with another root: still a whole
            // superblock naming the same seal, so only the cross-check sees it.
            let both = copies(disk)
            let newer = both.a.generation > both.b.generation ? FSLayout.superblockA : FSLayout.superblockB
            var bytes = disk.block(newer)
            bytes.withUnsafeMutableBytes { raw in
                var copy = FSSuperblock(reading: raw.baseAddress!)
                copy.sumRoot &+= 1
                copy.write(to: raw.baseAddress!)
            }
            disk.put(bytes, block: newer)

            let writes = disk.writes
            remount(disk) { again, found in
                #expect(again == nil)
                #expect(isCorrupt(found), "\(found)")
            }
            #expect(disk.writes == writes)
        }
    }


    @Test("an intent a settle could not stage in one transaction does not fit")
    func intentFitsOneSettle() {
        // Sixty-four mebibytes: sixteen sum blocks, so runs can reach sixteen.
        guard let plan = FSLayout.Plan(sectorCount: 131072, sectorSize: 512) else {
            Issue.record("plan"); return
        }
        #expect(plan.sumBlocks == 16)

        let per = UInt32(FSLayout.sumsPerBlock)
        var crossing = FSJournal.Intent()
        for home in UInt32(1)...8 {
            _ = crossing.add(home * per - 1)
            _ = crossing.add(home * per)
        }
        #expect(crossing.count == 8 && crossing.blocks == 16)
        #expect(!crossing.fits(plan))

        var inside = FSJournal.Intent()
        for home in UInt32(1)...7 {
            _ = inside.add(home * per - 1)
            _ = inside.add(home * per)
        }
        _ = inside.add(9 * per + 1)
        #expect(inside.count == 8 && inside.blocks == 15)
        #expect(inside.fits(plan))
    }


    // MARK: - Fixtures

    private struct Copy { let generation: UInt64; let root: UInt32 }

    private func copies(_ disk: MemoryDisk) -> (a: Copy, b: Copy) {
        func read(_ copy: UInt32) -> Copy {
            disk.block(copy).withUnsafeBytes {
                let found = FSSuperblock(reading: $0.baseAddress!)
                return Copy(generation: found.generation, root: found.sumRoot)
            }
        }
        return (read(FSLayout.superblockA), read(FSLayout.superblockB))
    }

    private func regionRoot(_ disk: MemoryDisk) -> UInt32 {
        guard let plan = FSLayout.Plan(sectorCount: disk.sectorCount, sectorSize: 512) else { return 0 }
        let medium = (0..<Int(plan.dataStart)).flatMap { disk.block(UInt32($0)) }
        return medium.withUnsafeBytes { sumRoot(of: $0.baseAddress!, plan) }
    }

    private func bitmap(_ fs: inout FileSystem<MemoryDisk>) -> UnsafeRawPointer {
        #expect(fs.readBlock(fs.plan.bitmapStart, into: fs.dataBuffer) == .ok)
        return UnsafeRawPointer(fs.dataBuffer)
    }

    private func changeRoot(_ fs: inout FileSystem<MemoryDisk>, expecting status: FSStatus? = .ok) {
        guard var root = fs.object(FSLayout.rootObject) else { Issue.record("root"); return }
        root.created += 1
        guard fs.begin() == .ok else { return }
        let done = fs.finish(fs.store(root, at: FSLayout.rootObject))
        if let status { #expect(done == status) }
    }

    private func withDisk(_ body: (inout FileSystem<MemoryDisk>, MemoryDisk) -> Void) {
        let disk = MemoryDisk(sectors: Self.sectors)
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
