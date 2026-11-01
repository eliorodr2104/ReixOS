//
//  BlockSumTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 31/10/2026.


import Testing
import ReixABI
@testable import ReixFS

/// Every bitmap and table block is checked against what this process last
/// knew to be there, on every read off the medium.
///
/// It is what lets a clean mount skip the table, and it holds for the whole of a
/// mount: a block that changed behind the file system's back - rot, a write the
/// disk lost, another hand - is refused the first time it is read rather than
/// believed. These tests are about where the knowing comes from and that a
/// refused write does not make the file system disbelieve its own disk.
@Suite("A metadata block read is the one last written")
struct BlockSumTests {

    private static let sectors: UInt64 = 4096


    private func withDisk(_ body: (inout FileSystem<MemoryDisk>, MemoryDisk) -> Void) {
        let disk  = MemoryDisk(sectors: Self.sectors)
        let space = UnsafeMutableRawPointer.allocate(byteCount: FileSystem<MemoryDisk>.scratchBytes, alignment: 8)
        defer { space.deallocate() }

        guard var fs = FileSystem.format(disk, scratch: space).disk else {
            Issue.record("format")
            return
        }

        body(&fs, disk)
    }

    private func file(_ fs: inout FileSystem<MemoryDisk>, _ name: StaticString, blocks: Int = 1) -> UInt32? {
        let made = fs.create(
            UnsafeRawPointer(name.utf8Start), length: name.utf8CodeUnitCount,
            kind: .file, in: FSLayout.rootObject
        )
        guard made.status == .ok else { return nil }

        let bytes = UnsafeMutableRawPointer.allocate(byteCount: blocks * Int(FSLayout.blockSize), alignment: 8)
        defer { bytes.deallocate() }
        bytes.initializeMemory(as: UInt8.self, repeating: 0x3C, count: blocks * Int(FSLayout.blockSize))

        guard fs.write(made.object, at: 0, from: bytes, count: UInt64(blocks) * FSLayout.blockSize).status == .ok else {
            return nil
        }
        return made.object
    }

    /// A byte of the root record no rule reads, so only the checksum can see it.
    private func spareRootByte(_ plan: FSLayout.Plan) -> Int {
        Int(plan.tableStart) * Int(FSLayout.blockSize) + 60
    }


    @Test("a format knows every checksum, so a table block changed after it is refused")
    func formatKnowsEverySum() {
        withDisk { fs, disk in
            #expect(fs.sumsKnown)

            disk.poke(UInt8(0x55), at: spareRootByte(fs.plan))
            fs.dropCache()

            #expect(fs.object(FSLayout.rootObject) == nil)
            #expect(fs.corrupted)
        }
    }


    @Test("a bitmap block changed under a live mount is refused before anything comes out of it")
    func changedBitmapIsRefusedBeforeAllocation() {
        withDisk { fs, disk in
            guard let object = file(&fs, "a.bin") else { Issue.record("file"); return }
            guard let record = fs.object(object) else { return }

            // The file's own block, marked free: the direction that hands one block
            // to two files if it is believed.
            let block = Int(record.runs[0].start)
            let at    = Int(fs.plan.bitmapStart) * Int(FSLayout.blockSize) + block / 8
            disk.poke(disk.byte(at: at) & ~(UInt8(1) << UInt8(block % 8)), at: at)
            fs.dropCache()

            // A growth, which has to read the map to find its block.
            let bytes = UnsafeMutableRawPointer.allocate(byteCount: Int(FSLayout.blockSize), alignment: 8)
            defer { bytes.deallocate() }
            bytes.initializeMemory(as: UInt8.self, repeating: 1, count: Int(FSLayout.blockSize))

            let writes = disk.writes
            #expect(fs.write(object, at: FSLayout.blockSize, from: bytes, count: FSLayout.blockSize).status == .quarantined)
            #expect(fs.corrupted)
            #expect(disk.writes == writes)
        }
    }


    @Test("a write the device refused leaves the checksum of what is still there")
    func refusedWriteKeepsTheOldSum() {
        // Every request of a create in turn, so that one of them is a home write
        // of a table or bitmap block the device turns away.
        var requests = 0
        withDisk { fs, disk in
            let before = disk.reads + disk.writes + disk.flushes
            _ = file(&fs, "probe.bin")
            requests = disk.reads + disk.writes + disk.flushes - before
        }
        #expect(requests > 8)

        for stop in 1...requests {
            withDisk { fs, disk in
                disk.failAfter(stop)
                _ = file(&fs, "probe.bin")
                disk.recover()

                // Every bitmap and table block read again off the medium. None of
                // them may disagree with what this process thinks it wrote.
                fs.dropCache()
                var findings = FileSystem<MemoryDisk>.Findings()
                #expect(fs.scanBlocks(&findings) != nil, "stop \(stop)")
                #expect(!fs.corrupted, "stop \(stop): a refused write was disbelieved")
            }
        }
    }


    @Test("a dirty mount learns every checksum from its scan, and checks every read after")
    func dirtyMountLearnsSums() {
        withDisk { fs, disk in
            #expect(file(&fs, "a.bin") != nil)

            // Never unmounted: the next mount recovers.
            let space = UnsafeMutableRawPointer.allocate(byteCount: FileSystem<MemoryDisk>.scratchBytes, alignment: 8)
            defer { space.deallocate() }

            guard var again = FileSystem.mount(disk, scratch: space).disk else {
                Issue.record("dirty mount refused")
                return
            }
            #expect(again.wasDirty)
            #expect(again.sumsKnown)

            disk.poke(UInt8(0x55), at: spareRootByte(again.plan))
            again.dropCache()

            #expect(again.object(FSLayout.rootObject) == nil)
            #expect(again.corrupted)
        }
    }


    @Test("a dirty mount judges a table block against the sum region before learning it")
    func unknownTableSumsAreJudged() {
        withDisk { fs, disk in
            #expect(file(&fs, "a.bin") != nil)

            // Without a seal, plausible table bytes still need their on-disk sum.
            fs.sumsKnown = false
            disk.poke(UInt8(0x55), at: spareRootByte(fs.plan))
            fs.dropCache()

            #expect(fs.object(FSLayout.rootObject) == nil)
            #expect(fs.corrupted)

        }
    }
}
