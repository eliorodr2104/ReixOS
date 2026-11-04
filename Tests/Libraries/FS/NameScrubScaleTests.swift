//
//  NameScrubScaleTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/08/2026.
//

import Testing
import ReixABI
@testable import ReixFS

@Suite("Directory scrub scale", .serialized)
struct NameScrubScaleTests {

    private static let sectors: UInt64 = 32768

    private func scratch() -> UnsafeMutableRawPointer {
        UnsafeMutableRawPointer.allocate(
            byteCount: FileSystem<MemoryDisk>.scratchBytes, alignment: 8
        )
    }

    private func named(_ index: Int, _ body: (UnsafeRawPointer, Int) -> Void) {
        var name = InlineArray<8, UInt8>(repeating: 0)
        name[0] = UInt8(ascii: "n")
        name[1] = UInt8(0x30 + UInt8(index / 100 % 10))
        name[2] = UInt8(0x30 + UInt8(index / 10 % 10))
        name[3] = UInt8(0x30 + UInt8(index % 10))

        name.span.withUnsafeBufferPointer { bytes in
            body(UnsafeRawPointer(bytes.baseAddress!), 4)
        }
    }

    private func microseconds(_ span: Duration) -> Int {
        let parts = span.components
        return Int(parts.seconds) * 1_000_000 + Int(parts.attoseconds / 1_000_000_000_000)
    }

    @Test("100 500 and 900 names have bounded scrub traffic")
    func scrubTraffic() {
        var readings: [(names: Int, reads: Int, microseconds: Int)] = []

        for names in [100, 500, 900] {
            let disk = MemoryDisk(sectors: Self.sectors)
            let space = scratch()
            defer { space.deallocate() }

            guard var fs = FileSystem.format(disk, scratch: space).disk else {
                Issue.record("format \(names)")
                return
            }

            for index in 0..<names {
                named(index) { pointer, length in
                    #expect(fs.create(pointer, length: length, kind: .file, in: FSLayout.rootObject).status == .ok)
                }
            }

            fs.dropCache()
            let before = disk.reads
            let started = ContinuousClock.now
            let findings = fs.scan(.everything)
            let elapsed = microseconds(started.duration(to: ContinuousClock.now))
            let reads = disk.reads - before

            #expect(findings.complete)
            #expect(!findings.damaged)
            readings.append((names, reads, elapsed))
        }

        for reading in readings {
            print("  scrub names \(reading.names): \(reading.reads) reads, \(reading.microseconds)us")
        }

        #expect(
            readings[2].reads * 10 <= readings[1].reads * 22,
            "500 names \(readings[1].reads) reads, 900 names \(readings[2].reads) reads"
        )
    }

    @Test("many ordinary populated folders do not consume one scrub budget")
    func manyFoldersRemainSafe() {
        let disk = MemoryDisk(sectors: Self.sectors)
        let space = scratch()
        defer { space.deallocate() }

        guard var fs = FileSystem.format(disk, scratch: space).disk else {
            Issue.record("format")
            return
        }

        for index in 0..<40 {
            named(index) { pointer, length in
                let folder = fs.create(pointer, length: length, kind: .folder, in: FSLayout.rootObject)
                #expect(folder.status == .ok)
                named(index + 100) { child, childLength in
                    #expect(fs.create(child, length: childLength, kind: .file, in: folder.object).status == .ok)
                }
            }
        }

        let findings = fs.scan(.everything)
        #expect(findings.complete)
        #expect(!findings.nameScrubBudgetExhausted)
        #expect(findings.safeToServe)
    }

    @Test("one directory cannot exceed its bounded partition capacity")
    func directoryPartitionBound() {
        let capacity = FileSystem<MemoryDisk>.nameScrubDescriptorCapacity
        let budget = FileSystem<MemoryDisk>.nameScrubPassBudget
        #expect(FileSystem<MemoryDisk>.nameScrubPartitions(named: 1) == budget)
        #expect(FileSystem<MemoryDisk>.nameScrubPartitions(named: capacity * budget) == budget)
        #expect(FileSystem<MemoryDisk>.nameScrubPartitions(named: capacity * budget + 1) == nil)
    }
}
