//
//  DataSumTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 01/11/2026.
//

import Testing
@testable import ReixFS
import ReixABI

/// The checksum of every block of file data: where it lives on the disk, and
/// what a disk laid down before it had a place is told.
@Suite("File data checks itself", .serialized)
struct DataSumTests {

    /// 16 MiB, the Makefile's image.
    private static let sectors: UInt64 = 32768

    private static let block = Int(FSLayout.blockSize)


    private func withFileSystem(_ body: (inout FileSystem<MemoryDisk>, MemoryDisk) -> Void) {
        let disk    = MemoryDisk(sectors: Self.sectors)
        let scratch = UnsafeMutableRawPointer.allocate(
            byteCount: FileSystem<MemoryDisk>.scratchBytes, alignment: 8
        )
        defer { scratch.deallocate() }

        guard var fs = FileSystem.format(disk, scratch: scratch).disk else {
            Issue.record("a fresh disk could not be formatted")
            return
        }

        body(&fs, disk)
    }

    /// Mounts what is on `disk` with a file system that has never seen it.
    private func remount(
        _ disk: MemoryDisk,
        _ body: (inout FileSystem<MemoryDisk>?, FSMount) -> Void
    ) {
        let scratch = UnsafeMutableRawPointer.allocate(
            byteCount: FileSystem<MemoryDisk>.scratchBytes, alignment: 8
        )
        defer { scratch.deallocate() }

        let attempt = FileSystem.mount(disk, scratch: scratch)
        var mounted = attempt.disk
        body(&mounted, attempt.found)
    }


    // MARK: - The format

    @Test("the sum region sits between the table and the data, one checksum per block")
    func geometry() {
        guard let small = FSLayout.Plan(sectorCount: 32768, sectorSize: 512),
              let large = FSLayout.Plan(sectorCount: 2097152, sectorSize: 512)
        else { Issue.record("no plan"); return }

        #expect(small.sumStart == small.tableStart + small.tableBlocks)
        #expect(small.sumBlocks == 4)
        #expect(small.sealBlocks == 3)
        #expect(small.dataStart == 59)

        #expect(large.sumBlocks == 256)
        #expect(large.sealBlocks == 5)
        #expect(large.dataStart == 2336)
        #expect(UInt64(large.sumBlocks) * FSLayout.sumsPerBlock >= UInt64(large.totalBlocks))
    }


    @Test("a disk laid down before the sum region is refused as unrecognised, untouched")
    func diskBeforeTheSumsIsRefused() {
        withFileSystem { fs, disk in
            let plan = fs.plan

            // This build's superblock with the data where the sums now are: what
            // a disk made before them says, byte for byte apart from the name.
            for copy in [FSLayout.superblockA, FSLayout.superblockB] {
                var bytes = disk.block(copy)
                bytes.withUnsafeMutableBytes { raw in
                    var old = FSSuperblock(reading: raw.baseAddress!)
                    old.dataStart = plan.sumStart
                    old.write(to: raw.baseAddress!)
                }
                disk.put(bytes, block: copy)
            }

            let before = (disk.block(FSLayout.superblockA), disk.block(FSLayout.superblockB))
            let writes = disk.writes

            remount(disk) { again, found in
                #expect(again == nil)
                #expect(isUnrecognised(found), "\(found)")
            }

            #expect(disk.writes == writes)
            #expect(disk.block(FSLayout.superblockA) == before.0)
            #expect(disk.block(FSLayout.superblockB) == before.1)
        }
    }
}
