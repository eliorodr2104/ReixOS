//
//  EntryCheckTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 31/10/2026.


import Testing
import ReixABI
@testable import ReixFS

/// A directory entry carries a check over its own bytes.
///
/// A mount that believes its seal never walks the folders, so a name that
/// rotted while the disk was shut down has to be caught by the first read of
/// it. Free is every byte zero; a name is one whose check adds up; anything
/// else is a slot something damaged, and is neither walked past nor written
/// over.
@Suite("A directory entry checks itself")
struct EntryCheckTests {

    private func entry(_ text: StaticString, object: UInt32 = 7) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: Int(FSLayout.entrySize))
        guard let made = FSEntry(object: object, name: UnsafeRawPointer(text.utf8Start), length: text.utf8CodeUnitCount) else {
            Issue.record("not a name: \(text)")
            return bytes
        }
        bytes.withUnsafeMutableBytes { made.write(to: $0.baseAddress!) }
        return bytes
    }

    private func standing(_ bytes: [UInt8]) -> FSEntry.Standing {
        bytes.withUnsafeBytes { FSEntry(reading: $0.baseAddress!).standing }
    }


    @Test("a name written is a name read, object and letters both")
    func roundTrip() {
        let bytes = entry("notes.txt", object: 41)
        let read  = bytes.withUnsafeBytes { FSEntry(reading: $0.baseAddress!) }

        #expect(read.standing == .named)
        #expect(read.object == 41)

        let name = "notes.txt" as StaticString
        #expect(read.matches(UnsafeRawPointer(name.utf8Start), length: name.utf8CodeUnitCount))
    }


    @Test("a free entry is every byte zero, and written as one")
    func freeIsZero() {
        #expect(standing([UInt8](repeating: 0, count: Int(FSLayout.entrySize))) == .free)

        var bytes = [UInt8](repeating: 0xEE, count: Int(FSLayout.entrySize))
        bytes.withUnsafeMutableBytes { FSEntry().write(to: $0.baseAddress!) }
        #expect(bytes.allSatisfy { $0 == 0 })
    }


    @Test("a free slot holding anything at all is not free")
    func dirtyFreeSlotIsImpossible() {
        // A name whose length byte was lost: the letters are still there.
        var lost = entry("gone.bin")
        lost[4] = 0
        #expect(standing(lost) == .impossible)

        // And one stray byte anywhere in an otherwise empty slot.
        for at in 0..<Int(FSLayout.entrySize) {
            var bytes = [UInt8](repeating: 0, count: Int(FSLayout.entrySize))
            bytes[at] = 1
            #expect(standing(bytes) == .impossible, "byte \(at)")
        }
    }


    @Test("every single bit flipped in a name is caught")
    func everyBitFlipIsCaught() {
        let good = entry("a-long-enough-name.dat", object: 0x0102_0304)
        #expect(standing(good) == .named)

        for bit in 0..<(Int(FSLayout.entrySize) * 8) {
            var bytes = good
            bytes[bit / 8] ^= UInt8(1) << UInt8(bit % 8)
            #expect(standing(bytes) == .impossible, "bit \(bit)")
        }
    }


    @Test("an entry with the old zero padding is not a name")
    func uncheckedEntryIsImpossible() {
        // What a disk laid down before the check holds: the same bytes, no check.
        var bytes = entry("old.txt")
        for at in FSEntry.checkOffset..<(FSEntry.checkOffset + FSEntry.checkWidth) { bytes[at] = 0 }
        #expect(standing(bytes) == .impossible)
    }


    @Test("a damaged entry is neither walked past nor written over")
    func damagedEntryHoldsTheFolder() {
        let disk  = MemoryDisk(sectors: 4096)
        let space = UnsafeMutableRawPointer.allocate(byteCount: FileSystem<MemoryDisk>.scratchBytes, alignment: 8)
        defer { space.deallocate() }

        guard var fs = FileSystem.format(disk, scratch: space).disk else { Issue.record("format"); return }

        for name in ["a.txt", "b.txt"] as [StaticString] {
            #expect(fs.create(
                UnsafeRawPointer(name.utf8Start), length: name.utf8CodeUnitCount,
                kind: .file, in: FSLayout.rootObject
            ).status == .ok)
        }

        guard let root = fs.object(FSLayout.rootObject) else { Issue.record("root"); return }
        let at = Int(root.runs[0].start) * Int(FSLayout.blockSize)

        // The first entry's object number, by one bit: the kind of change that
        // would hand a name somebody else's file.
        disk.poke(disk.byte(at: at) ^ 0x02, at: at)

        let writes = disk.writes
        let name = "c.txt" as StaticString
        #expect(fs.create(
            UnsafeRawPointer(name.utf8Start), length: name.utf8CodeUnitCount,
            kind: .file, in: FSLayout.rootObject
        ).status == .quarantined)
        #expect(fs.corrupted)
        #expect(disk.writes == writes)
    }
}
