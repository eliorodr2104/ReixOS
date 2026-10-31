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
/// what every record holds - is what the room walk is built from, so a recovery
/// is a few table lengths and not a product of two.
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
        let ceiling = UInt64(FSLayout.maxSupportedBlocksV02) * (FSLayout.blockSize / 512)
        #expect(FileSystem<MemoryDisk>.scratchBytes
                == FileSystem<MemoryDisk>.scratchBytes(sectorCount: ceiling, sectorSize: 512))
        #expect(FileSystem<MemoryDisk>.scratchBytes(sectorCount: 32768, sectorSize: 512) == 104 * 1024)
    }


    private func mount(_ disk: MemoryDisk, _ body: (inout FileSystem<MemoryDisk>?, FSMount) -> Void) {
        let space = UnsafeMutableRawPointer.allocate(byteCount: FileSystem<MemoryDisk>.scratchBytes, alignment: 8)
        defer { space.deallocate() }

        let opened = FileSystem.mount(disk, scratch: space)
        var fs = opened.disk
        body(&fs, opened.found)
    }
}
