//
//  StaleBytesTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/08/2026.


import Testing
import ReixABI
@testable import ReixFS

/// Reading a file and getting somebody else's bytes.
///
/// A growth took blocks and published them without touching them, so a write
/// that covered part of a block read the rest of it off the disk and kept it,
/// and a write past the end of a file left a gap made entirely of blocks it had
/// never written. Both are readable the moment the size grows past them, and
/// what is in them is whatever the last object to hold those blocks left there:
/// a deleted file, from this container or any other.
///
/// So every test here writes a pattern, deletes it, and then reads through a new
/// file looking for the pattern. And each one checks the pattern really is still
/// on the disk after the delete, because a test that cannot find it has proved
/// nothing.
@Suite("A new file reads as zero, not as the last one")
struct StaleBytesTests {

    private static let sectors: UInt64 = 4096   // 2 MiB
    private static let mark   : UInt8  = 0xA7


    private func withDisk(
        _ body: (inout FileSystem<MemoryDisk>, MemoryDisk) -> Void
    ) {
        let disk = MemoryDisk(sectors: Self.sectors)

        let scratch = UnsafeMutableRawPointer.allocate(
            byteCount: FileSystem<MemoryDisk>.scratchBytes,
            alignment: 8
        )
        defer { scratch.deallocate() }

        guard var fs = FileSystem.format(disk, scratch: scratch).disk else {
            Issue.record("the fixture disk would not format")
            return
        }

        body(&fs, disk)
    }


    private func make(
        _ fs: inout FileSystem<MemoryDisk>,
        _ name: StaticString
    ) -> UInt32? {
        let made = fs.create(
            UnsafeRawPointer(name.utf8Start),
            length: name.utf8CodeUnitCount,
            kind  : .file,
            in    : FSLayout.rootObject
        )
        guard made.status == .ok else {
            Issue.record("the fixture file would not be made")
            return nil
        }
        return made.object
    }


    private func drop(_ fs: inout FileSystem<MemoryDisk>, _ name: StaticString) -> FSStatus {
        fs.remove(
            UnsafeRawPointer(name.utf8Start),
            length: name.utf8CodeUnitCount,
            from  : FSLayout.rootObject
        )
    }


    /// Fills a file with the pattern, fills the rest of the disk with something
    /// else, then deletes the first one - so the *only* free blocks left on the
    /// disk are the ones holding the pattern.
    ///
    /// The filling is the whole point. Without it the allocator sweeps forward
    /// from where it last stopped, finds untouched blocks past the end of
    /// everything, and hands those out: the new file gets blocks that happen to
    /// be zero already, and every test below passes whatever the code does. That
    /// is a fixture proving nothing, so this one leaves the reuse no choice and
    /// then checks it has none.
    private func leaveRubbish(
        _ fs: inout FileSystem<MemoryDisk>,
        _ disk: MemoryDisk,
        blocks: Int
    ) -> Bool {

        guard let object = make(&fs, "old.bin") else { return false }

        let bytes = Int(FSLayout.blockSize) * blocks
        let payload = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 8)
        defer { payload.deallocate() }

        payload.initializeMemory(as: UInt8.self, repeating: Self.mark, count: bytes)

        guard fs.write(
            object, at: 0, from: UnsafeRawPointer(payload), count: UInt64(bytes)
        ).status == .ok else {
            Issue.record("the fixture file would not be filled")
            return false
        }

        // Everything else, so that nothing but the pattern is free afterwards.
        // One extent, one call, because eight extents is the limit and a filler
        // taken a block at a time would hit it.
        let spare = fs.freeBlocks()
        guard spare > 1 else {
            Issue.record("the fixture disk is too small to fill")
            return false
        }

        guard let filler = make(&fs, "filler.bin") else { return false }

        let fill = Int(FSLayout.blockSize) * Int(spare)
        let rest = UnsafeMutableRawPointer.allocate(byteCount: fill, alignment: 8)
        defer { rest.deallocate() }

        rest.initializeMemory(as: UInt8.self, repeating: 0x5C, count: fill)

        guard fs.write(
            filler, at: 0, from: UnsafeRawPointer(rest), count: UInt64(fill)
        ).status == .ok else {
            Issue.record("the rest of the disk would not be filled")
            return false
        }

        #expect(fs.freeBlocks() == 0)

        guard drop(&fs, "old.bin") == .ok else {
            Issue.record("the fixture file would not be removed")
            return false
        }

        // Exactly the pattern's blocks are free, so a new file has nowhere else
        // to go. If this number is anything but `blocks`, the tests below are
        // not testing reuse and say so here rather than passing quietly.
        #expect(
            fs.freeBlocks() == UInt32(blocks),
            "the free blocks are not exactly the deleted file's, so reuse is not forced"
        )

        // And the bytes are still in them. Nothing zeroes on release, and nothing
        // should: it would cost a write per block of every delete to fix a leak
        // that belongs to whoever takes the blocks next.
        var found = 0
        for at in 0..<Int(Self.sectors * 512) where disk.byte(at: at) == Self.mark {
            found += 1
        }

        #expect(found >= bytes, "the pattern is not on the disk, so this proves nothing")

        return found >= bytes && fs.freeBlocks() == UInt32(blocks)
    }


    /// Every byte of `object` from 0 to `size`, checked against `expected`.
    private func readWhole(
        _ fs: inout FileSystem<MemoryDisk>,
        _ object: UInt32,
        size: UInt64,
        _ expected: (Int) -> UInt8
    ) -> Bool {

        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: 8
        )
        defer { buffer.deallocate() }

        buffer.initializeMemory(as: UInt8.self, repeating: 0xFF, count: Int(size))

        var moved = UInt64(0)
        while moved < size {
            let step = fs.read(
                object,
                at   : moved,
                into : buffer.advanced(by: Int(moved)),
                count: size - moved
            )
            guard step.status == .ok, step.bytes > 0 else {
                Issue.record("the file would not read back at \(moved)")
                return false
            }
            moved += step.bytes
        }

        let got = buffer.assumingMemoryBound(to: UInt8.self)

        for at in 0..<Int(size) where got[at] != expected(at) {
            Issue.record("byte \(at) is \(got[at]), wanted \(expected(at))")
            return false
        }

        return true
    }


    // MARK: - The gap

    @Test("a write past the end leaves zeros behind it, not the last file's bytes")
    func sparseWriteReadsAsZero() {
        withDisk { fs, disk in
            guard leaveRubbish(&fs, disk, blocks: 6) else { return }

            guard let object = make(&fs, "new.bin") else { return }

            // Four blocks in, so the gap is three whole blocks of somebody
            // else's data plus the head of a fourth.
            let offset = FSLayout.blockSize * 3 + 100
            let word   = "here" as StaticString

            let written = fs.write(
                object,
                at   : offset,
                from : UnsafeRawPointer(word.utf8Start),
                count: 4
            )
            #expect(written.status == .ok)
            #expect(written.bytes == 4)

            // The whole interval, from byte zero. Everything but the four bytes
            // written has to be zero, and in particular none of it may be the
            // pattern.
            #expect(readWhole(&fs, object, size: offset + 4) { at in
                at >= Int(offset) ? word.utf8Start[at - Int(offset)] : 0
            })
        }
    }


    // MARK: - The head and the tail of one block

    @Test("the rest of a partly written block reads as zero")
    func partialBlockReadsAsZero() {
        // No gap of whole blocks here: one block, ten bytes written at the front
        // and ten near the back. Everything between them was never written by
        // this file, and the block it is in belonged to the deleted one.
        withDisk { fs, disk in
            guard leaveRubbish(&fs, disk, blocks: 4) else { return }

            guard let object = make(&fs, "new.bin") else { return }

            let head = "0123456789" as StaticString
            #expect(fs.write(
                object, at: 0, from: UnsafeRawPointer(head.utf8Start), count: 10
            ).status == .ok)

            let tailAt = FSLayout.blockSize - 20
            let tail   = "abcdefghij" as StaticString
            #expect(fs.write(
                object, at: tailAt, from: UnsafeRawPointer(tail.utf8Start), count: 10
            ).status == .ok)

            #expect(readWhole(&fs, object, size: tailAt + 10) { at in
                if at < 10 { return head.utf8Start[at] }
                if at >= Int(tailAt) { return tail.utf8Start[at - Int(tailAt)] }
                return 0
            })
        }
    }


    // MARK: - Growing into a block the file already touched

    @Test("extending inside a block the file already had keeps its own bytes")
    func extendingWithinABlockKeepsItsOwn() {
        // The other direction, and the reason the line is drawn per block rather
        // than per byte: a block this file has already reached holds its own
        // data below the size, and zeroing it wholesale would throw that away.
        withDisk { fs, disk in
            guard leaveRubbish(&fs, disk, blocks: 4) else { return }

            guard let object = make(&fs, "new.bin") else { return }

            let word = "keepme" as StaticString
            #expect(fs.write(
                object, at: 0, from: UnsafeRawPointer(word.utf8Start), count: 6
            ).status == .ok)

            // Still inside block zero, past the six bytes already there.
            let later = "later" as StaticString
            #expect(fs.write(
                object, at: 2000, from: UnsafeRawPointer(later.utf8Start), count: 5
            ).status == .ok)

            #expect(readWhole(&fs, object, size: 2005) { at in
                if at < 6 { return word.utf8Start[at] }
                if at >= 2000 { return later.utf8Start[at - 2000] }
                return 0
            })
        }
    }


    // MARK: - Many blocks of gap

    @Test("a long gap over reused blocks reads as zero end to end")
    func longGapReadsAsZero() {
        withDisk { fs, disk in
            guard leaveRubbish(&fs, disk, blocks: 8) else { return }

            guard let object = make(&fs, "new.bin") else { return }

            let offset = FSLayout.blockSize * 7
            let one    = "x" as StaticString

            #expect(fs.write(
                object, at: offset, from: UnsafeRawPointer(one.utf8Start), count: 1
            ).status == .ok)

            #expect(readWhole(&fs, object, size: offset + 1) { at in
                at == Int(offset) ? one.utf8Start[0] : 0
            })
        }
    }


    // MARK: - And once more after a remount

    @Test("the zeros are on the disk, not in a buffer")
    func zerosSurviveARemount() {
        let disk = MemoryDisk(sectors: Self.sectors)

        let scratch = UnsafeMutableRawPointer.allocate(
            byteCount: FileSystem<MemoryDisk>.scratchBytes, alignment: 8
        )
        defer { scratch.deallocate() }

        guard var fs = FileSystem.format(disk, scratch: scratch).disk else {
            Issue.record("the fixture disk would not format")
            return
        }

        guard leaveRubbish(&fs, disk, blocks: 6) else { return }
        guard let object = make(&fs, "new.bin") else { return }

        let offset = FSLayout.blockSize * 4 + 7
        let word   = "ok" as StaticString

        #expect(fs.write(
            object, at: offset, from: UnsafeRawPointer(word.utf8Start), count: 2
        ).status == .ok)
        #expect(fs.unmount() == .ok)

        guard var again = FileSystem.mount(disk, scratch: scratch).disk else {
            Issue.record("the disk would not mount again")
            return
        }

        #expect(readWhole(&again, object, size: offset + 2) { at in
            at >= Int(offset) ? word.utf8Start[at - Int(offset)] : 0
        })
    }
}
