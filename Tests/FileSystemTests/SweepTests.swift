//
//  SweepTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/08/2026.

import Testing
import ReixABI
@testable import ReixFS

/// The block sweep, held to the run it finds rather than to how it finds it.
///
/// Written before the sweep was changed and passing then, which is the point of
/// it: what has to survive a faster scan is not a number but the answer. A
/// first-fit allocator that reports a different block is a different allocator,
/// and a fragmented disk is exactly where the difference would hide.
///
/// The patterns are poked straight onto the medium. Filling a disk with
/// one-block files to fragment it would cost a transaction each and minutes of
/// them, and what is under test is the reading of the map, not the writing of it.
@Suite("Block sweep", .serialized)
struct SweepTests {

    /// Two disks: one whose block count is a whole number of words, and one
    /// whose is not. The second is the one that catches a word-at-a-time scan
    /// reading the bits past the end of the disk, which are free and are not
    /// blocks.
    private static let evenSectors: UInt64 = 32768   // 4096 blocks, 64 words
    private static let oddSectors : UInt64 = 32760   // 4095 blocks, the last word short


    private func withDisk(
        _ sectors: UInt64,
        _ body: (inout FileSystem<MemoryDisk>, MemoryDisk, FSLayout.Plan) -> Void
    ) {
        let disk = MemoryDisk(sectors: sectors)

        let space = UnsafeMutableRawPointer.allocate(
            byteCount: FileSystem<MemoryDisk>.scratchBytes, alignment: 8
        )
        defer { space.deallocate() }

        guard let plan = FSLayout.Plan(sectorCount: sectors, sectorSize: 512),
              var fs = FileSystem.format(disk, scratch: space).disk
        else {
            Issue.record("a disk of \(sectors) sectors would not format")
            return
        }

        body(&fs, disk, plan)
    }


    /// Writes the bitmap as `used(block)` says, and nothing else.
    private func paint(
        _ disk: MemoryDisk,
        _ plan: FSLayout.Plan,
        _ used: (UInt32) -> Bool
    ) -> [Bool] {

        var taken = [Bool](repeating: false, count: Int(plan.totalBlocks))
        let base  = Int(plan.bitmapStart) * Int(FSLayout.blockSize)

        // Whole bytes, so the bits past the last block are written too: they are
        // part of the word a fast scan will load, and leaving them as the format
        // left them would be leaving the interesting case out.
        let bytes = (Int(plan.totalBlocks) + 7) / 8

        for byte in 0..<bytes {
            var value = UInt8(0)

            for bit in 0..<8 {
                let block = UInt32(byte * 8 + bit)
                guard block < plan.totalBlocks else { continue }

                if used(block) {
                    value |= (1 << UInt8(bit))
                    taken[Int(block)] = true
                }
            }

            disk.poke(value, at: base + byte)
        }

        return taken
    }


    /// First fit from `first`, a block at a time, which is the answer the sweep
    /// has to give whatever it does inside.
    private func firstFit(_ taken: [Bool], _ count: Int, from first: Int) -> Int? {
        var running = 0
        var start   = first

        for block in first..<taken.count {
            if taken[block] {
                running = 0
                start   = block + 1
                continue
            }

            running += 1
            if running == count { return start }
        }

        return nil
    }

    /// What `allocateRun` looks for: from where the last one came from, then from
    /// the beginning of the data region.
    private func expected(
        _ taken: [Bool], _ count: Int, hint: Int, dataStart: Int
    ) -> Int? {
        if hint > dataStart, let found = firstFit(taken, count, from: hint) { return found }
        return firstFit(taken, count, from: dataStart)
    }


    /// The sweep claims what it finds, and claiming is a staged write, so the
    /// call belongs inside a transaction. Abandoned afterwards: what is being
    /// compared is the block it chose.
    private func chosen(
        _ fs: inout FileSystem<MemoryDisk>,
        _ count: UInt32
    ) -> UInt32? {
        guard fs.begin() == .ok else {
            Issue.record("no transaction")
            return nil
        }

        let found = fs.allocateRun(count)
        fs.abort()

        guard case .taken(let start, _) = found else { return nil }
        return start
    }


    @Test("every pattern gives the block a bit-at-a-time first fit would")
    func equivalence() {
        for sectors in [Self.evenSectors, Self.oddSectors] {
            withDisk(sectors) { fs, disk, plan in

                let last = plan.totalBlocks - 1
                let data = plan.dataStart

                // Each case: what the map says, and the run lengths to ask for.
                let cases: [(String, (UInt32) -> Bool, [UInt32])] = [
                    ("empty",       { _ in false },                    [1, 2, 8, 64, 100]),
                    ("full",        { $0 >= data },                    [1, 2, 64]),
                    ("alternating", { $0 >= data && $0 % 2 == 1 },     [1, 2]),
                    ("word holes",  { $0 >= data && ($0 / 64) % 2 == 0 }, [1, 2, 64, 65]),
                    ("one hole at a word edge", { block in
                        block >= data && !(block >= 62 + data && block < 66 + data)
                    }, [1, 2, 4, 5]),
                    ("only the tail", { $0 >= data && $0 < last - 1 }, [1, 2, 3]),
                    ("all but one",   { $0 >= data && $0 != data + 1000 }, [1, 2]),
                ]

                for (name, used, counts) in cases {
                    for count in counts {
                        let taken = paint(disk, plan, used)
                        fs.dropCache()

                        let want = expected(
                            taken, Int(count),
                            hint: Int(fs.blockHint), dataStart: Int(data)
                        )
                        let got = chosen(&fs, count)

                        let note = "\(sectors) sectors, \(name), run of \(count): "
                            + "got \(String(describing: got)), wanted \(String(describing: want))"

                        #expect(got.map(Int.init) == want, "\(note)")
                    }
                }
            }
        }
    }


    @Test("a run is never found past the end of the disk")
    func nothingPastTheEnd() {
        withDisk(Self.oddSectors) { fs, disk, plan in

            // Everything used but the last two blocks. The word holding them
            // also holds the bits for blocks that do not exist, and those bits
            // are zero: a scan that trusted them would answer with a run of
            // three, of which one block is not on the disk.
            let last = plan.totalBlocks - 1
            _ = paint(disk, plan, { $0 >= plan.dataStart && $0 < last - 1 })
            fs.dropCache()

            #expect(chosen(&fs, 2) == last - 1)

            let taken = paint(disk, plan, { $0 >= plan.dataStart && $0 < last - 1 })
            #expect(taken.count == Int(plan.totalBlocks))
            fs.dropCache()

            #expect(chosen(&fs, 3) == nil, "a run ran off the end of the disk")
        }
    }


    @Test("the free count is the number of free blocks, however it is counted")
    func freeCount() {
        for sectors in [Self.evenSectors, Self.oddSectors] {
            withDisk(sectors) { fs, disk, plan in

                let data = plan.dataStart

                for (name, used) in [
                    ("empty",       { (_: UInt32) in false }),
                    ("full",        { $0 >= data }),
                    ("alternating", { $0 >= data && $0 % 2 == 1 }),
                    ("word holes",  { $0 >= data && ($0 / 64) % 2 == 0 }),
                    ("all but one", { $0 >= data && $0 != data + 7 }),
                ] {
                    let taken = paint(disk, plan, used)
                    fs.dropCache()

                    // Only the data region counts: the front of the disk is the
                    // file system's own and is never free.
                    var want = 0
                    for block in Int(data)..<taken.count where !taken[block] { want += 1 }

                    #expect(
                        Int(fs.freeBlocks()) == want,
                        "\(sectors) sectors, \(name): free count"
                    )
                }
            }
        }
    }
}
