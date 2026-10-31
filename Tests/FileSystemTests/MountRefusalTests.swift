//
//  MountRefusalTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/08/2026.


import Testing
import ReixABI
@testable import ReixFS

/// `FSMount` is not `Equatable` and does not need to be: what a test wants to
/// say is which refusal it got, and a function per answer says it more plainly
/// than an operator would.
func isOK(_ found: FSMount) -> Bool { if case .ok = found { return true }; return false }
func isBlank(_ found: FSMount) -> Bool { if case .blank = found { return true }; return false }
func isCorrupt(_ found: FSMount) -> Bool { if case .corrupt = found { return true }; return false }
func isUnusable(_ found: FSMount) -> Bool { if case .unusable = found { return true }; return false }
func isDeviceFailed(_ found: FSMount) -> Bool { if case .deviceFailed = found { return true }; return false }
func isDurabilityUnknown(_ found: FSMount) -> Bool {
    if case .durabilityUnknown = found { return true }; return false
}

func isUnrecognised(_ found: FSMount) -> Bool { if case .unrecognised = found { return true }; return false }


/// What mounting does to a disk it does not recognise, which used to be:
/// erase it.
///
/// `.notFormatted` led straight into `format()`, and everything that was not a
/// mountable disk arrived there together - an empty disk, a superblock with one
/// byte lost to a torn write, an image belonging to another system, and a disk
/// written by a future version of this one. The first of those is the only one
/// anybody should be willing to write over.
///
/// So every test here asserts two things: which answer came back, and that the
/// write count did not move. The second is the one that matters. `MemoryDisk`
/// counts its own traffic and `poke` goes behind its back, so "nothing was
/// written" is a number and not a hope.
@Suite("Refusing a disk instead of erasing it")
struct MountRefusalTests {

    private static let sectors: UInt64 = 4096   // 2 MiB


    private func withScratch(_ body: (UnsafeMutableRawPointer) -> Void) {
        let scratch = UnsafeMutableRawPointer.allocate(
            byteCount: FileSystem<MemoryDisk>.scratchBytes,
            alignment: 8
        )
        defer { scratch.deallocate() }

        body(scratch)
    }


    /// Damages the same offset in both superblocks.
    ///
    /// One whole copy is enough to mount from, which is the whole point of there
    /// being two: a torn write costs the newer copy and not the disk. So a test
    /// about a *disk* that cannot be read has to reach both, and the tests that
    /// reach one are about the surviving copy being used.
    private func pokeBoth(_ disk: MemoryDisk, _ byte: UInt8, at offset: Int) {
        let block = Int(FSLayout.blockSize)

        disk.poke(byte, at: Int(FSLayout.superblockA) * block + offset)
        disk.poke(byte, at: Int(FSLayout.superblockB) * block + offset)
    }

    private func pokeBoth(_ disk: MemoryDisk, _ value: UInt32, at offset: Int) {
        let block = Int(FSLayout.blockSize)

        disk.poke(value, at: Int(FSLayout.superblockA) * block + offset)
        disk.poke(value, at: Int(FSLayout.superblockB) * block + offset)
    }

    private func pokeBoth(_ disk: MemoryDisk, _ value: UInt64, at offset: Int) {
        let block = Int(FSLayout.blockSize)

        disk.poke(value, at: Int(FSLayout.superblockA) * block + offset)
        disk.poke(value, at: Int(FSLayout.superblockB) * block + offset)
    }


    /// A disk with a real file system on it, and the offset of a field on it.
    private func withFormatted(
        _ body: (MemoryDisk, UnsafeMutableRawPointer) -> Void
    ) {
        let disk = MemoryDisk(sectors: Self.sectors)

        withScratch { scratch in
            guard FileSystem.format(disk, scratch: scratch).disk != nil else {
                Issue.record("the fixture disk would not format")
                return
            }

            body(disk, scratch)
        }
    }


    // MARK: - Empty

    @Test("an empty disk reads as empty, and mounting one writes nothing")
    func emptyIsBlank() {
        let disk = MemoryDisk(sectors: Self.sectors)

        withScratch { scratch in
            let attempt = FileSystem.mount(disk, scratch: scratch)

            #expect(attempt.disk == nil)
            #expect(isBlank(attempt.found))

            // The whole correction in one number: mounting an empty disk used
            // to format it, and formatting is nothing but writes.
            #expect(disk.writes == 0)
        }
    }


    @Test("formatting is a door of its own, and it works")
    func formatIsSeparateAndWorks() {
        let disk = MemoryDisk(sectors: Self.sectors)

        withScratch { scratch in
            let made = FileSystem.format(disk, scratch: scratch)

            #expect(made.made == .ok)
            #expect(made.disk != nil)
            #expect(disk.writes > 0)

            // And now it mounts, which is the pair of them working together.
            #expect(isOK(FileSystem.mount(disk, scratch: scratch).found))
        }
    }


    // MARK: - Ours, damaged

    @Test("a superblock with one byte of its magic lost is corrupt, not empty")
    func tornMagicIsCorrupt() {
        // The case that made this worth changing. One byte of the magic gone -
        // a write that did not finish - and the disk was classified as having
        // no file system, so the next mount erased everything on it.
        withFormatted { disk, scratch in
            pokeBoth(disk, UInt8(0), at: 0)

            let before  = disk.writes
            let attempt = FileSystem.mount(disk, scratch: scratch)

            #expect(attempt.disk == nil)
            #expect(isCorrupt(attempt.found))
            #expect(!isBlank(attempt.found))
            #expect(disk.writes == before)
        }
    }


    @Test("a superblock whose magic is gone entirely is still not an empty disk")
    func zeroedMagicIsNotBlank() {
        // Blank is the whole block and not the magic, which is what makes this
        // case answerable at all: everything else on block zero is still there,
        // so the disk plainly held a file system a moment ago.
        withFormatted { disk, scratch in
            pokeBoth(disk, UInt64(0), at: 0)

            let before  = disk.writes
            let attempt = FileSystem.mount(disk, scratch: scratch)

            #expect(isCorrupt(attempt.found))
            #expect(!isBlank(attempt.found))
            #expect(disk.writes == before)
        }
    }


    @Test("a superblock describing a disk this is not is corrupt")
    func wrongGeometryIsCorrupt() {
        // A resized image, or a bad block in the middle of block zero. The
        // magic is right and the arithmetic is not, and the old code called
        // that "not formatted" too.
        withFormatted { disk, scratch in
            pokeBoth(disk, UInt32(12345), at: FSSuperblockField.totalBlocks)

            let before  = disk.writes
            let attempt = FileSystem.mount(disk, scratch: scratch)

            #expect(isCorrupt(attempt.found))
            #expect(disk.writes == before)
        }
    }


    // MARK: - Somebody else's

    @Test("another system's disk is left exactly as it was found")
    func foreignDiskIsUntouched() {
        let disk = MemoryDisk(sectors: Self.sectors)

        // Something that is emphatically not ours, in the place our magic goes.
        let foreign: [UInt8] = Array("NOTREIXFS-DO-NOT-ERASE".utf8)
        for (index, byte) in foreign.enumerated() { disk.poke(byte, at: index) }

        withScratch { scratch in
            let attempt = FileSystem.mount(disk, scratch: scratch)

            #expect(attempt.disk == nil)
            #expect(isCorrupt(attempt.found))
            #expect(disk.writes == 0)

            // Byte for byte, because "nothing was written" is the promise.
            for (index, byte) in foreign.enumerated() {
                #expect(disk.byte(at: index) == byte)
            }
        }
    }


    // MARK: - Ours, in another layout

    @Test("a disk of ours in another layout is named, not overwritten")
    func otherLayoutIsNamed() {
        withFormatted { disk, scratch in
            // `REIXFS` and anything but the two zero bytes after it: what a disk
            // laid down by another build of this system says.
            let other = FSLayout.magicFamily | (UInt64(0x3239) << 48)   // "REIXFS92"
            pokeBoth(disk, other, at: FSSuperblockField.magic)

            let before  = disk.writes
            let attempt = FileSystem.mount(disk, scratch: scratch)

            #expect(attempt.disk == nil)
            #expect(isUnrecognised(attempt.found), "\(attempt.found)")
            #expect(disk.writes == before)
        }
    }


    @Test("one damaged copy is not a damaged disk")
    func oneCopyIsEnough() {
        // Why there are two. A superblock update writes the copy it is not
        // reading from, so a power cut in the middle of one costs the newer copy
        // and leaves the older one whole - and the older one still says where
        // everything is.
        withFormatted { disk, scratch in
            let block = Int(FSLayout.blockSize)

            // The copy `format` wrote second, which is the one a mount would
            // pick: the higher generation.
            disk.poke(UInt8(0), at: Int(FSLayout.superblockB) * block)

            let attempt = FileSystem.mount(disk, scratch: scratch)

            #expect(attempt.disk != nil)
            #expect(isOK(attempt.found))
        }

        // And the other way round, so neither copy is the special one.
        withFormatted { disk, scratch in
            let block = Int(FSLayout.blockSize)
            disk.poke(UInt8(0), at: Int(FSLayout.superblockA) * block)

            #expect(isOK(FileSystem.mount(disk, scratch: scratch).found))
        }
    }


    @Test("the magic this build writes is its name and nothing after it")
    func magicIsTheNameAlone() {
        // A guard on the two constants drifting apart, and on a version
        // creeping back into the two bytes after the name.
        #expect(FSLayout.magic & 0x0000_FFFF_FFFF_FFFF == FSLayout.magicFamily)
        #expect(FSLayout.magic >> 48 == 0)
    }


    @Test("a disk laid down before the seal region is refused as unrecognised, untouched")
    func diskBeforeTheSealIsRefused() {
        // `REIXFS02`, with the table where this build keeps the seal: what an
        // image made by an earlier build holds, byte for byte.
        let disk = MemoryDisk(sectors: Self.sectors)
        guard let plan = FSLayout.Plan(sectorCount: Self.sectors, sectorSize: 512) else { return }

        var old = [UInt8](repeating: 0, count: Int(FSLayout.blockSize))
        old.withUnsafeMutableBytes { raw in
            let base = raw.baseAddress!
            let table = plan.bitmapStart + plan.bitmapBlocks

            base.storeBytes(of: UInt64(0x3230_5346_5849_4552), toByteOffset: 0, as: UInt64.self)
            for (at, value) in [
                (8, UInt32(FSLayout.blockSize)), (12, plan.totalBlocks),
                (16, plan.bitmapStart), (20, plan.bitmapBlocks),
                (24, table), (28, plan.tableBlocks), (32, table + plan.tableBlocks),
                (36, plan.objectCount), (40, 0), (44, 0),
                (80, FSLayout.journalStart), (84, FSLayout.journalBlocks),
                (88, FSSuperblock.completeMarker),
            ] {
                base.storeBytes(of: value, toByteOffset: at, as: UInt32.self)
            }
            base.storeBytes(of: UInt64(2), toByteOffset: 72, as: UInt64.self)
            base.storeBytes(
                of: FSChecksum.over(base, count: 96, zeroing: 92), toByteOffset: 92, as: UInt32.self
            )
        }
        disk.put(old, block: FSLayout.superblockA)
        disk.put(old, block: FSLayout.superblockB)

        withScratch { scratch in
            let attempt = FileSystem.mount(disk, scratch: scratch)

            #expect(attempt.disk == nil)
            #expect(isUnrecognised(attempt.found), "\(attempt.found)")
        }

        #expect(disk.writes == 0)
        #expect(disk.block(FSLayout.superblockA) == old)
        #expect(disk.block(FSLayout.superblockB) == old)
    }


    // MARK: - No disk at all

    @Test("a disk that will not answer is not mistaken for an empty one")
    func silentDeviceIsNotBlank() {
        let disk = MemoryDisk(sectors: Self.sectors)
        disk.failFrom = 1

        withScratch { scratch in
            let attempt = FileSystem.mount(disk, scratch: scratch)

            #expect(attempt.disk == nil)
            #expect(isDeviceFailed(attempt.found))
            #expect(!isBlank(attempt.found))
            #expect(disk.writes == 0)
        }
    }


    // MARK: - The mark

    @Test("a refused disk never gets the mounted mark either")
    func refusedDiskIsNotMarked() {
        // The mark is a write, and the only one a successful mount does. A disk
        // that was refused must not come back looking like it was mounted once
        // and never let go.
        withFormatted { disk, scratch in
            pokeBoth(disk, UInt8(0), at: 0)

            let writesBefore = disk.writes
            let markBefore   = disk.byte(at: FSSuperblockField.state)

            _ = FileSystem.mount(disk, scratch: scratch)

            #expect(disk.writes == writesBefore)
            #expect(disk.byte(at: FSSuperblockField.state) == markBefore)
        }
    }
}
