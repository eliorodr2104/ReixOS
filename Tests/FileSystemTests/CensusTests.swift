//
//  CensusTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 31/10/2026.


import Testing
import ReixABI
@testable import ReixFS

/// One pass over the object table, whatever the size of the bitmap.
///
/// A scan builds the whole block map in the journal's arena and compares it with
/// the disk's afterwards. It used to build one bitmap block at a time, with a
/// pass of the table for each. The census that pass takes - the containers, and
/// what every record holds - is what the room walk and the seal are built from,
/// so a recovery is a few table lengths and not a product of two.
@Suite("A scan reads the table once", .serialized)
struct CensusTests {

    /// 256 MiB: two bitmap blocks and five hundred and twelve table blocks.
    private static let wide: UInt64 = 524288

    /// 2 MiB, for the sweeps that interrupt every request.
    private static let small: UInt64 = 4096


    private func withDisk(
        _ sectors: UInt64,
        _ body: (inout FileSystem<MemoryDisk>, MemoryDisk) -> Void
    ) {
        let disk  = MemoryDisk(sectors: sectors)
        let space = UnsafeMutableRawPointer.allocate(
            byteCount: FileSystem<MemoryDisk>.scratchBytes(sectorCount: sectors, sectorSize: 512),
            alignment: 8
        )
        defer { space.deallocate() }

        guard var fs = FileSystem.format(disk, scratch: space).disk else {
            Issue.record("format")
            return
        }

        body(&fs, disk)
    }

    private func file(
        _ fs: inout FileSystem<MemoryDisk>,
        _ name: StaticString,
        blocks: Int = 1,
        in folder: UInt32 = FSLayout.rootObject
    ) -> UInt32? {
        let made = fs.create(
            UnsafeRawPointer(name.utf8Start), length: name.utf8CodeUnitCount, kind: .file, in: folder
        )
        guard made.status == .ok else { return nil }

        let bytes = UnsafeMutableRawPointer.allocate(byteCount: blocks * Int(FSLayout.blockSize), alignment: 8)
        defer { bytes.deallocate() }
        bytes.initializeMemory(as: UInt8.self, repeating: 0x61, count: blocks * Int(FSLayout.blockSize))

        guard fs.write(made.object, at: 0, from: bytes, count: UInt64(blocks) * FSLayout.blockSize).status == .ok else {
            return nil
        }
        return made.object
    }

    /// Blocks claimed and owned by nobody, committed: crash residue made to order.
    private func leak(_ fs: inout FileSystem<MemoryDisk>, at start: UInt32, _ count: UInt32) {
        #expect(fs.begin() == .ok)
        #expect(fs.allocateAt(start, count: count) == .ok)
        #expect(fs.commit() == .ok)
    }


    // MARK: - One pass

    @Test("a scan reads every table block once and every bitmap block once")
    func scanIsOnePass() {
        withDisk(Self.wide) { fs, disk in
            #expect(fs.plan.bitmapBlocks == 2)
            #expect(file(&fs, "a.bin", blocks: 3) != nil)

            fs.dropCache()
            let before = disk.reads
            let findings = fs.scan(.blocks)

            #expect(findings.complete)
            // And not the sum region: a mounted volume knows what it holds, and
            // every read of one is checked.
            #expect(disk.reads - before == Int(fs.plan.tableBlocks) + Int(fs.plan.bitmapBlocks))
        }
    }


    @Test("a run across two bitmap blocks is one run to the scan")
    func runAcrossGroups() {
        withDisk(Self.wide) { fs, _ in
            // Sixteen blocks starting eight short of the second bitmap block.
            let edge = UInt32(FileSystem<MemoryDisk>.blocksPerBitmapBlock)
            fs.blockHint = edge - 8

            guard let object = file(&fs, "straddle.bin", blocks: 16),
                  let record = fs.object(object)
            else { Issue.record("file"); return }

            #expect(record.runs[0].start < edge && record.runs[0].start + record.runs[0].count > edge)

            let findings = fs.scan(.blocks)
            #expect(findings.complete)
            #expect(findings.reclaimable == 0)
            #expect(findings.ownedButFree == 0)
            #expect(findings.claimedTwice == 0)
        }
    }


    @Test("two records claiming a block in the second bitmap block are found")
    func doubleClaimInTheSecondGroup() {
        withDisk(Self.wide) { fs, disk in
            let edge = UInt32(FileSystem<MemoryDisk>.blocksPerBitmapBlock)
            fs.blockHint = edge + 100

            guard let first  = file(&fs, "one.bin"),
                  let second = file(&fs, "two.bin"),
                  let owner  = fs.object(first)
            else { Issue.record("files"); return }

            #expect(owner.runs[0].start > edge)

            let at = Int(fs.plan.tableStart) * Int(FSLayout.blockSize)
                + Int(second) * Int(FSLayout.objectSize) + 64
            disk.poke(owner.runs[0].start, at: at)
            fs.believeMedium()

            let findings = fs.scan(.blocks)
            #expect(findings.claimedTwice == 1)
            #expect(findings.reclaimable == 1)
            #expect(fs.corrupted)
        }
    }


    @Test("a repair rewrites every bitmap block from one rebuilt map")
    func repairCoversEveryGroup() {
        withDisk(Self.wide) { fs, disk in
            let edge = UInt32(FileSystem<MemoryDisk>.blocksPerBitmapBlock)
            leak(&fs, at: fs.plan.dataStart + 50, 3)
            leak(&fs, at: edge + 50, 5)

            let findings = fs.scan(.blocks)
            #expect(findings.reclaimable == 8)
            #expect(findings.repairable)

            fs.dropCache()
            let before = disk.reads
            #expect(fs.repair(findings) == .ok)

            // One more pass to rebuild the map, and not one per bitmap block.
            #expect(disk.reads - before <= Int(fs.plan.tableBlocks) + 4)

            let after = fs.scan(.blocks)
            #expect(after.complete)
            #expect(!after.changed)
        }
    }


    @Test("a dirty mount puts right a map and a room in one go")
    func dirtyMountMendsMapAndRoom() {
        // The map before the room. The other way round, the room's commit spent
        // the ticket the map repair needed and a disk with both was refused.
        withDisk(Self.small) { fs, disk in
            let made = fs.createContainer(
                UnsafeRawPointer(("box" as StaticString).utf8Start), length: 3,
                quota: 16, in: FSLayout.rootObject
            )
            guard made.status == .ok else { Issue.record("container"); return }

            leak(&fs, at: fs.plan.dataStart + 40, 2)

            // A room behind what is charged to it, left by the machine that went
            // away: `used` one short.
            let at = Int(fs.plan.tableStart) * Int(FSLayout.blockSize)
                + Int(made.object) * Int(FSLayout.objectSize) + 36
            disk.poke(UInt32(disk.byte(at: at)) + 1, at: at)

            let space = UnsafeMutableRawPointer.allocate(byteCount: FileSystem<MemoryDisk>.scratchBytes, alignment: 8)
            defer { space.deallocate() }

            let opened = FileSystem.mount(disk, scratch: space)
            guard var again = opened.disk else {
                Issue.record("a disk with both a leak and a room behind was refused: \(opened.found)")
                return
            }

            let findings = again.scan(.everything)
            #expect(findings.safeToServe)
            #expect(findings.wrongQuota == 0)
            #expect(!findings.changed)
        }
    }


    @Test("a dirty mount with nothing to mend still reads every name")
    func dirtyMountReadsNames() {
        withDisk(Self.small) { fs, disk in
            guard let first = file(&fs, "a.bin"), file(&fs, "b.bin") != nil,
                  let root = fs.object(FSLayout.rootObject)
            else { Issue.record("files"); return }

            // Two names for one object, the second written by a careful hand.
            let base = Int(root.runs[0].start) * Int(FSLayout.blockSize)
            for slot in 0..<Int(FSLayout.blockSize / FSLayout.entrySize) {
                let at = base + slot * Int(FSLayout.entrySize)
                guard disk.byte(at: at + 4) == 5, disk.byte(at: at) != UInt8(truncatingIfNeeded: first),
                      disk.byte(at: at + 8) == UInt8(ascii: "b") else { continue }
                disk.poke(first, at: at)
                disk.stampEntry(at: at)
            }

            mount(disk) { again, found in
                #expect(again == nil)
                #expect(isCorrupt(found), "\(found)")
            }
        }
    }


    @Test("names past one page of objects are scrubbed whole")
    func namesPastOnePage() {
        // 1 GiB: sixty-five thousand object slots, two pages of target bits.
        let sectors: UInt64 = 2097152

        withDisk(sectors) { fs, disk in
            #expect(fs.plan.objectCount > UInt32(FSLayout.blockSize * 8))

            fs.objectHint = UInt32(FSLayout.blockSize * 8) + 100

            guard let first = file(&fs, "x.bin"),
                  file(&fs, "y.bin") != nil,
                  let root = fs.object(FSLayout.rootObject)
            else { Issue.record("files"); return }

            #expect(first > UInt32(FSLayout.blockSize * 8))

            // The second name pointed at the first one's object.
            let base = Int(root.runs[0].start) * Int(FSLayout.blockSize)
            for slot in 0..<Int(FSLayout.blockSize / FSLayout.entrySize) {
                let at = base + slot * Int(FSLayout.entrySize)
                guard disk.byte(at: at + 4) == 5, disk.byte(at: at + 8) == UInt8(ascii: "y") else { continue }
                disk.poke(first, at: at)
                disk.stampEntry(at: at)
            }

            let findings = fs.scan(.everything)
            #expect(findings.complete)
            #expect(findings.nameScrubState == .complete)
            #expect(findings.duplicateTargets == 1)
        }
    }


    // MARK: - Scratch

    @Test("a geometry's scratch is what it asks for, and all it touches")
    func scratchIsEnough() {
        for sectors in [Self.small, 32768, Self.wide] as [UInt64] {
            let bytes  = FileSystem<MemoryDisk>.scratchBytes(sectorCount: sectors, sectorSize: 512)
            let guard_ = Int(FSLayout.blockSize)
            let space  = UnsafeMutableRawPointer.allocate(byteCount: bytes + guard_, alignment: 8)
            defer { space.deallocate() }
            space.advanced(by: bytes).initializeMemory(as: UInt8.self, repeating: 0xA5, count: guard_)

            let disk = MemoryDisk(sectors: sectors)
            guard var fs = FileSystem.format(disk, scratch: space).disk else { Issue.record("format"); continue }

            _ = fs.createContainer(UnsafeRawPointer(("box" as StaticString).utf8Start), length: 3, quota: 8, in: FSLayout.rootObject)
            _ = file(&fs, "a.bin", blocks: 4)
            _ = fs.scan(.everything)
            #expect(fs.unmount() == .ok)

            for _ in 0..<2 {
                guard var again = FileSystem.mount(disk, scratch: space).disk else { Issue.record("mount"); break }
                _ = again.scan(.everything)
                _ = again.putRight()
            }

            let untouched = (0..<guard_).allSatisfy {
                space.load(fromByteOffset: bytes + $0, as: UInt8.self) == 0xA5
            }
            #expect(untouched, "\(sectors) sectors: written past its scratch")
        }

        // The fixed size is the largest declared geometry's, and covers it.
        let ceiling = UInt64(FSLayout.maxSupportedBlocks) * (FSLayout.blockSize / 512)
        #expect(FileSystem<MemoryDisk>.scratchBytes
                == FileSystem<MemoryDisk>.scratchBytes(sectorCount: ceiling, sectorSize: 512))
        #expect(FileSystem<MemoryDisk>.scratchBytes(sectorCount: 32768, sectorSize: 512) == 108 * 1024)
    }


    // MARK: - Interrupted recovery

    /// A 2 MiB disk left dirty with a leak and a room behind, so that a mount
    /// repairs the map, mends the room and scans it all again.
    private func dirtyFixture(_ body: (MemoryDisk, [UInt32]) -> Void) {
        withDisk(Self.small) { fs, disk in
            let made = fs.createContainer(
                UnsafeRawPointer(("box" as StaticString).utf8Start), length: 3,
                quota: 16, in: FSLayout.rootObject
            )
            guard made.status == .ok,
                  let a = file(&fs, "a.bin", blocks: 2),
                  let b = file(&fs, "b.bin", in: made.object)
            else { Issue.record("fixture"); return }

            leak(&fs, at: fs.plan.dataStart + 40, 2)

            let at = Int(fs.plan.tableStart) * Int(FSLayout.blockSize)
                + Int(made.object) * Int(FSLayout.objectSize) + 36
            disk.poke(UInt32(disk.byte(at: at)) + 1, at: at)

            body(disk, [a, b])
        }
    }

    private func mount(_ disk: MemoryDisk, _ body: (inout FileSystem<MemoryDisk>?, FSMount) -> Void) {
        let space = UnsafeMutableRawPointer.allocate(byteCount: FileSystem<MemoryDisk>.scratchBytes, alignment: 8)
        defer { space.deallocate() }

        let opened = FileSystem.mount(disk, scratch: space)
        var fs = opened.disk
        body(&fs, opened.found)
    }


    @Test("a recovery interrupted at any request is finished by the next mount")
    func interruptedRecoveryIsFinished() {
        var requests = 0
        dirtyFixture { disk, _ in
            let before = disk.reads + disk.writes + disk.flushes
            mount(disk) { fs, found in #expect(fs != nil, "\(found)") }
            requests = disk.reads + disk.writes + disk.flushes - before
        }
        #expect(requests > 20)

        for stop in 1...(requests + 1) {
            dirtyFixture { disk, files in
                disk.failAfter(stop)
                mount(disk) { _, _ in }
                disk.recover()

                mount(disk) { fs, found in
                    guard var fs else {
                        Issue.record("stop \(stop): not finished, \(found)")
                        return
                    }

                    let findings = fs.scan(.everything)
                    #expect(findings.safeToServe, "stop \(stop)")
                    #expect(findings.wrongQuota == 0 && !findings.changed, "stop \(stop)")

                    for object in files {
                        let bytes = UnsafeMutableRawPointer.allocate(byteCount: Int(FSLayout.blockSize), alignment: 8)
                        defer { bytes.deallocate() }
                        #expect(fs.read(object, at: 0, into: bytes, count: FSLayout.blockSize).bytes == FSLayout.blockSize)
                        #expect(bytes.load(fromByteOffset: 9, as: UInt8.self) == 0x61, "stop \(stop)")
                    }
                }
            }
        }
    }


    @Test("a power cut anywhere in a recovery is finished by the next mount")
    func powerCutDuringRecovery() {
        let sectors = Self.small

        // Left dirty with a leak and a room behind, on a disk that loses what it
        // had not flushed.
        func fixture(_ body: (CrashDisk, [UInt32]) -> Void) {
            let disk  = CrashDisk(sectors: sectors)
            let space = UnsafeMutableRawPointer.allocate(byteCount: FileSystem<CrashDisk>.scratchBytes, alignment: 8)
            defer { space.deallocate() }

            guard var fs = FileSystem.format(disk, scratch: space).disk else { Issue.record("format"); return }

            let box = fs.createContainer(
                UnsafeRawPointer(("box" as StaticString).utf8Start), length: 3, quota: 16, in: FSLayout.rootObject
            )
            let name = "a.bin" as StaticString
            let made = fs.create(UnsafeRawPointer(name.utf8Start), length: name.utf8CodeUnitCount, kind: .file, in: FSLayout.rootObject)
            guard box.status == .ok, made.status == .ok else { Issue.record("fixture"); return }

            let bytes = UnsafeMutableRawPointer.allocate(byteCount: Int(FSLayout.blockSize), alignment: 8)
            defer { bytes.deallocate() }
            bytes.initializeMemory(as: UInt8.self, repeating: 0x61, count: Int(FSLayout.blockSize))
            #expect(fs.write(made.object, at: 0, from: bytes, count: FSLayout.blockSize).status == .ok)

            #expect(fs.begin() == .ok)
            #expect(fs.allocateAt(fs.plan.dataStart + 40, count: 2) == .ok)
            #expect(fs.commit() == .ok)
            #expect(fs.barrier() == .ok)

            let at = Int(fs.plan.tableStart) * Int(FSLayout.blockSize)
                + Int(box.object) * Int(FSLayout.objectSize) + 36
            disk.poke(UInt32(disk.byte(at: at)) + 1, at: at)

            body(disk, [made.object])
        }

        var requests = 0
        fixture { disk, _ in
            let space = UnsafeMutableRawPointer.allocate(byteCount: FileSystem<CrashDisk>.scratchBytes, alignment: 8)
            defer { space.deallocate() }
            let before = disk.reads + disk.writes + disk.flushes
            #expect(FileSystem.mount(disk, scratch: space).disk != nil)
            requests = disk.reads + disk.writes + disk.flushes - before
        }
        #expect(requests > 20)

        for stop in 1...(requests + 1) {
            for policy in [CrashDisk.Survivors.nothing, .everything, .permuted(3)] {
                fixture { disk, files in
                    let space = UnsafeMutableRawPointer.allocate(byteCount: FileSystem<CrashDisk>.scratchBytes, alignment: 8)
                    defer { space.deallocate() }

                    disk.failAfter(stop)
                    _ = FileSystem.mount(disk, scratch: space)
                    disk.powerCut(keeping: policy)

                    let restarted = CrashDisk(restarting: disk)
                    guard var again = FileSystem.mount(restarted, scratch: space).disk else {
                        Issue.record("stop \(stop), \(policy): not finished")
                        return
                    }

                    let findings = again.scan(.everything)
                    #expect(findings.safeToServe && findings.wrongQuota == 0, "stop \(stop), \(policy)")

                    let bytes = UnsafeMutableRawPointer.allocate(byteCount: Int(FSLayout.blockSize), alignment: 8)
                    defer { bytes.deallocate() }
                    #expect(again.read(files[0], at: 0, into: bytes, count: FSLayout.blockSize).bytes == FSLayout.blockSize)
                    #expect(bytes.load(fromByteOffset: 9, as: UInt8.self) == 0x61, "stop \(stop), \(policy)")
                }
            }
        }
    }


    @Test("a repair cut between two bitmap blocks is finished by the next mount")
    func repairCutBetweenGroups() {
        // A leak in each of two bitmap blocks, one transaction each, so a cut
        // can land with the first rewritten and the second not.
        func fixture(_ body: (MemoryDisk) -> Void) {
            withDisk(Self.wide) { fs, disk in
                let edge = UInt32(FileSystem<MemoryDisk>.blocksPerBitmapBlock)
                #expect(file(&fs, "a.bin") != nil)
                leak(&fs, at: fs.plan.dataStart + 50, 3)
                leak(&fs, at: edge + 50, 5)
                body(disk)
            }
        }

        guard let plan = FSLayout.Plan(sectorCount: Self.wide, sectorSize: 512) else { return }

        // Two superblocks and the journal header, then the census and the sum
        // region it learns: the repair's first request comes straight after.
        let first = 3 + Int(plan.tableBlocks) + Int(plan.bitmapBlocks) + Int(plan.sumBlocks) + 1

        var cut = 0
        for stop in first...(first + 24) {
            fixture { disk in
                let before = disk.writes
                disk.failAfter(stop)
                mount(disk) { _, _ in }
                disk.recover()
                if disk.writes > before { cut += 1 }

                mount(disk) { fs, found in
                    guard var fs else { Issue.record("stop \(stop): \(found)"); return }
                    let findings = fs.scan(.blocks)
                    #expect(findings.complete && !findings.changed, "stop \(stop)")
                }
            }
        }
        #expect(cut > 0)
    }
}
