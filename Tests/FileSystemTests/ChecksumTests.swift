//
//  ChecksumTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 04/11/2026.
//

import Testing
import ReixABI
@testable import ReixFS

/// Independent of the byte and word tables the format uses.
private func reference(_ bytes: [UInt8], continuing: UInt32 = 0) -> UInt32 {
    var crc = ~continuing
    for byte in bytes {
        crc ^= UInt32(byte)
        for _ in 0..<8 {
            crc = crc & 1 == 0 ? crc >> 1 : (crc >> 1) ^ 0x82F6_3B78
        }
    }
    return ~crc
}

private struct Dice {
    private var state: UInt64

    init(_ seed: UInt64) { state = seed | 1 }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

private func crc(
    _ bytes   : [UInt8],
    zeroing   : Int = -1,
    width     : Int = 4,
    continuing: UInt32 = 0
) -> UInt32 {
    let backing = bytes.isEmpty ? [UInt8(0)] : bytes
    return backing.withUnsafeBytes {
        FSChecksum.over(
            $0.baseAddress!, count: bytes.count, zeroing: zeroing,
            width: width, continuing: continuing
        )
    }
}

@Suite("CRC32C, the format's one checksum")
struct ChecksumTests {

    @Test("the RFC 3720 vectors, and the check value")
    func standardVectors() {
        #expect(FSChecksum.empty == 0)
        #expect(crc([]) == FSChecksum.empty)
        let pdu: [UInt8] = [
            0x01, 0xC0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0,
            0x14, 0, 0, 0, 0, 0, 0x04, 0,
            0, 0, 0, 0x14, 0, 0, 0, 0x18,
            0x28, 0, 0, 0, 0, 0, 0, 0,
            0x02, 0, 0, 0, 0, 0, 0, 0,
        ]
        for (bytes, want): ([UInt8], UInt32) in [
            ([UInt8](repeating: 0, count: 32), 0x8A91_36AA),
            ([UInt8](repeating: 0xFF, count: 32), 0x62A8_AB43),
            ((0..<32).map { UInt8($0) }, 0x46DD_794E),
            ((0..<32).reversed().map { UInt8($0) }, 0x113F_DB5C),
            (pdu, 0xD996_3A56),
            (Array("123456789".utf8), 0xE306_9283),
            ([], 0),
        ] {
            #expect(crc(bytes) == want)
        }
    }

    @Test("the table agrees with a bit at a time, at every length and alignment")
    func agreesBitForBit() {
        var dice  = Dice(7)
        let bytes = (0..<4200).map { _ in UInt8(truncatingIfNeeded: dice.next()) }
        bytes.withUnsafeBytes { raw in
            for seed: UInt32 in [0, 0x1234_5678] {
                for start in 0..<16 {
                    for count in 0...80 {
                        #expect(FSChecksum.over(raw.baseAddress! + start, count: count, continuing: seed)
                            == reference(Array(bytes[start..<(start + count)]), continuing: seed))
                    }
                }
                for start in 0..<8 {
                    for count in [4095, 4096, 4097] {
                        #expect(FSChecksum.over(raw.baseAddress! + start, count: count, continuing: seed)
                            == reference(Array(bytes[start..<(start + count)]), continuing: seed))
                    }
                }
            }
        }
    }

    @Test("pieces continue the checksum of one whole block")
    func continuesAcrossPieces() {
        var dice  = Dice(19)
        let bytes = (0..<4096).map { _ in UInt8(truncatingIfNeeded: dice.next()) }
        let whole = crc(bytes)
        for split in [0, 1, 7, 8, 9, 63, 64, 4095, 4096] {
            let head = crc(Array(bytes[..<split]))
            #expect(crc(Array(bytes[split...]), continuing: head) == whole)
        }
    }

    @Test("the window reads as zero wherever it falls")
    func zeroedWindow() {
        for (count, zeroing, width) in [
            (64, 5, 3), (112, 108, 4), (4096, 36, 4), (64, 0, 4),
            (64, 62, 4), (64, 64, 4), (20, 2, 12), (64, 80, 4),
            (0, 0, 4), (64, 2, 0), (64, 2, -1),
        ] {
            var dice   = Dice(31)
            var source = (0..<count).map { _ in UInt8(truncatingIfNeeded: dice.next()) }
            let head   = min(zeroing, count)
            let hole   = max(0, min(width, count - head))
            for at in head..<(head + hole) { source[at] = 0xFF }
            var zeroed = source
            for at in head..<(head + hole) { zeroed[at] = 0 }
            #expect(crc(source, zeroing: zeroing, width: width) == reference(zeroed))
        }
    }

    @Test("every single bit of a block is covered")
    func everyBitFlipCaught() {
        var dice  = Dice(43)
        var bytes = (0..<4096).map { _ in UInt8(truncatingIfNeeded: dice.next()) }
        let whole = crc(bytes)
        for bit in 0..<(4096 * 8) {
            let mask = UInt8(1) << (bit % 8)
            bytes[bit / 8] ^= mask
            #expect(crc(bytes) != whole)
            bytes[bit / 8] ^= mask
        }
    }

    @Test("every burst of up to thirty-two bits is caught")
    func everyShortBurstCaught() {
        var dice  = Dice(59)
        var bytes = (0..<4096).map { _ in UInt8(truncatingIfNeeded: dice.next()) }
        let whole = crc(bytes)
        let bits  = bytes.count * 8
        let starts = Array(0..<512) + Array(stride(from: 512, to: bits - 512, by: 61))
            + Array((bits - 512)..<bits)
        for width in 1...32 {
            for start in starts where start + width <= bits {
                var mask = [UInt8](repeating: 0, count: 5)
                for bit in 0..<width where bit == 0 || bit == width - 1 || dice.next() & 1 != 0 {
                    let at = start % 8 + bit
                    mask[at / 8] ^= UInt8(1) << (at % 8)
                }
                for at in mask.indices where start / 8 + at < bytes.count {
                    bytes[start / 8 + at] ^= mask[at]
                }
                #expect(crc(bytes) != whole)
                for at in mask.indices where start / 8 + at < bytes.count {
                    bytes[start / 8 + at] ^= mask[at]
                }
            }
        }
    }
}

@Suite("Every checksummed record is CRC32C on the disk")
struct ChecksumLayoutTests {

    private func withFormatted(
        _ body: (inout FileSystem<MemoryDisk>, MemoryDisk) -> Void
    ) {
        let disk    = MemoryDisk(sectors: 4096)
        let scratch = UnsafeMutableRawPointer.allocate(
            byteCount: FileSystem<MemoryDisk>.scratchBytes, alignment: 8
        )
        defer { scratch.deallocate() }
        guard var fs = FileSystem.format(disk, scratch: scratch).disk else {
            Issue.record("the fixture disk would not format")
            return
        }
        body(&fs, disk)
    }

    private func word(_ bytes: [UInt8], at: Int) -> UInt32 {
        UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8
            | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
    }

    private func live(_ disk: MemoryDisk) -> [UInt8] {
        let a = disk.block(FSLayout.superblockA)
        let b = disk.block(FSLayout.superblockB)
        let ga = a.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 72, as: UInt64.self) }
        let gb = b.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 72, as: UInt64.self) }
        return ga > gb ? a : b
    }

    private func create(_ fs: inout FileSystem<MemoryDisk>) -> UInt32? {
        let name: StaticString = "crc-entry-check.dat"
        let made = fs.create(
            UnsafeRawPointer(name.utf8Start), length: name.utf8CodeUnitCount,
            kind: .file, in: FSLayout.rootObject
        )
        guard made.status == .ok else { Issue.record("fixture create: \(made.status)"); return nil }
        return made.object
    }

    private func write(_ fs: inout FileSystem<MemoryDisk>, _ file: UInt32, _ bytes: [UInt8]) {
        let wrote = bytes.withUnsafeBytes {
            fs.write(file, at: 0, from: $0.baseAddress!, count: UInt64(bytes.count))
        }
        #expect(wrote.status == .ok)
        #expect(wrote.bytes == UInt64(bytes.count))
    }

    private func used(_ disk: MemoryDisk, _ plan: FSLayout.Plan, _ block: UInt32) -> Bool {
        let at = Int(plan.bitmapStart) * 4096 + Int(block / 8)
        return disk.byte(at: at) & (UInt8(1) << (block % 8)) != 0
    }

    private func content(_ count: Int) -> [UInt8] {
        var dice = Dice(71)
        return (0..<count).map { _ in UInt8(truncatingIfNeeded: dice.next()) }
    }

    @Test("both superblocks carry a CRC32C")
    func superblocks() {
        withFormatted { _, disk in
            for copy in [FSLayout.superblockA, FSLayout.superblockB] {
                let bytes = disk.block(copy)
                #expect(word(bytes, at: 108) == reference(Array(bytes[..<108]) + [0, 0, 0, 0]))
            }
        }
    }

    @Test("the committed header covers itself and every payload")
    func journalHeader() {
        var found = false
        for stop in 1...40 {
            withFormatted { fs, disk in
                disk.failAfter(stop)
                let name: StaticString = "journal.dat"
                _ = fs.create(UnsafeRawPointer(name.utf8Start), length: name.utf8CodeUnitCount,
                              kind: .file, in: FSLayout.rootObject)
                disk.recover()
                let header = disk.block(2)
                guard word(header, at: 12) == 2 else { return }
                found = true
                var checked = Array(header[..<FSJournal.Header.width])
                for at in 36..<40 { checked[at] = 0 }
                #expect(word(header, at: 36) == reference(checked))
                let count = Int(word(header, at: 32))
                #expect(count > 0 && count <= FSJournal.capacity)
                for index in 0..<min(count, FSJournal.capacity) {
                    #expect(word(header, at: 40 + 8 * index + 4)
                        == reference(disk.block(UInt32(FSLayout.journalStart) + UInt32(index))))
                }
                #expect(word(header, at: FSJournal.Header.declaredCheck) == 0)

                // The live writer supplies a declaration buffer even for no
                // intent. Omitting it has its own encoding, the complement.
                var omitted = [UInt8](repeating: 0, count: 4096)
                omitted.withUnsafeMutableBytes { raw in
                    header.withUnsafeBytes {
                        FSJournal(reading: $0.baseAddress!).write(to: raw.baseAddress!)
                    }
                }
                #expect(word(omitted, at: FSJournal.Header.declaredCheck) == 0xFFFF_FFFF)
            }
            if found { break }
        }
        #expect(found)
    }

    @Test("an overwrite declares the new CRC of every block before writing it")
    func declaredOverwrite() {
        let old = content(8192)
        let new = old.map { $0 ^ 0xA5 }
        var found = false
        for stop in 1...80 {
            withFormatted { fs, disk in
                guard let file = create(&fs) else { return }
                write(&fs, file, old)
                disk.failAfter(stop)
                _ = new.withUnsafeBytes {
                    fs.write(file, at: 0, from: $0.baseAddress!, count: UInt64(new.count))
                }
                disk.recover()
                let header = disk.block(2)
                let runs   = Int(word(header, at: FSJournal.Header.intentCount))
                guard runs > 0, [1, 2].contains(word(header, at: 12)) else { return }
                found = true
                var blocks = 0
                for run in 0..<min(runs, FSJournal.Intent.limit) {
                    blocks += Int(word(header, at: FSJournal.Header.intentRuns + run * 8 + 4))
                }
                #expect(blocks == 2)
                let declared = Array(header[512..<(512 + min(blocks, 2) * 4)])
                let sums = Set(stride(from: 0, to: declared.count, by: 4).map { word(declared, at: $0) })
                #expect(sums == Set([reference(Array(new[..<4096])), reference(Array(new[4096...]))]))
                #expect(word(header, at: FSJournal.Header.declaredCheck) == reference(declared))
            }
            if found { break }
        }
        #expect(found)
    }

    @Test("the sum region checks the table and every allocated data block")
    func sumRegion() {
        withFormatted { fs, disk in
            guard let file = create(&fs) else { return }
            write(&fs, file, content(3 * 4096))
            let plan = fs.plan
            let blocks = Array(plan.tableStart..<plan.sumStart)
                + (plan.dataStart..<plan.totalBlocks).filter { used(disk, plan, $0) }
            #expect(blocks.count >= Int(plan.tableBlocks) + 3)
            for block in blocks {
                let sums = disk.block(plan.sumStart + block / 1024)
                #expect(word(sums, at: Int(block % 1024) * 4) == reference(disk.block(block)))
            }
            var roots: [UInt8] = []
            for block in plan.sumStart..<plan.dataStart {
                let sum = reference(disk.block(block))
                for byte in 0..<4 { roots.append(UInt8(truncatingIfNeeded: sum >> (byte * 8))) }
            }
            #expect(word(live(disk), at: 100) == reference(roots))
        }
    }

    @Test("the seal checks the map, table and sum region across its blocks")
    func seal() {
        withFormatted { fs, disk in
            guard let file = create(&fs) else { return }
            write(&fs, file, content(3 * 4096))
            let plan = fs.plan
            #expect(fs.unmount() == .ok)
            let seal = (plan.sealStart..<plan.tableStart).flatMap { disk.block($0) }
            #expect(word(live(disk), at: 96) == reference(seal))
            for group in 0..<Int(plan.bitmapBlocks) {
                #expect(word(seal, at: FSSeal.groupOffset(group))
                    == reference(disk.block(plan.bitmapStart + UInt32(group))))
            }
            for table in 0..<Int(plan.tableBlocks + plan.sumBlocks) {
                #expect(word(seal, at: FSSeal.tableOffset(table, groups: Int(plan.bitmapBlocks)))
                    == reference(disk.block(plan.tableStart + UInt32(table))))
            }
        }
    }

    @Test("an entry folds the CRC into its existing twenty-four bits")
    func entryCheck() {
        withFormatted { fs, disk in
            guard create(&fs) != nil else { return }
            let name = Array("crc-entry-check.dat".utf8)
            var found = 0
            for block in fs.plan.dataStart..<fs.plan.totalBlocks where used(disk, fs.plan, block) {
                let bytes = disk.block(block)
                for at in stride(from: 0, to: 4096, by: 64) {
                    var slot = Array(bytes[at..<(at + 64)])
                    guard slot[4] == name.count, Array(slot[8..<(8 + name.count)]) == name else { continue }
                    found += 1
                    let stored = UInt32(slot[5]) | UInt32(slot[6]) << 8 | UInt32(slot[7]) << 16
                    for byte in 5..<8 { slot[byte] = 0 }
                    let hash = reference(slot)
                    #expect(stored == (hash ^ (hash >> 24)) & 0x00FF_FFFF)
                }
            }
            #expect(found == 1)
        }
    }
}
