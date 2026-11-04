//
//  UncheckedArithmeticTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/08/2026.


import Testing
import ReixABI
@testable import ReixFS

/// Numbers from outside, arriving at arithmetic that traps.
///
/// Swift's integers trap on overflow and on division by zero, and a trap in a
/// server is that server gone. So every one of these is a client, a device or a
/// damaged disk being able to end the file system for everybody on the machine
/// by sending a number - which is a boundary crossed by a request that was
/// supposed to be refused.
///
/// Every test here is a value that used to reach an unchecked operation. They
/// pass by *returning* rather than by returning anything in particular: the
/// assertion is that the process is still running afterwards, and the expected
/// answer is checked on the way past.
@Suite("Numbers from outside do not trap")
struct UncheckedArithmeticTests {

    private static let sectors: UInt64 = 4096


    private func withDisk(_ body: (inout FileSystem<MemoryDisk>) -> Void) {
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

        body(&fs)
    }


    private func file(_ fs: inout FileSystem<MemoryDisk>, _ name: StaticString) -> UInt32? {
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


    // MARK: - What a device says it is

    @Test("a device claiming sectors of no size is refused, not divided by")
    func zeroSectorSizeIsRefused() {
        // The division came before the guard that would have caught it, so the
        // guard could never run: this is a device saying something absurd and
        // taking the process with it.
        #expect(FSLayout.Plan(sectorCount: 4096, sectorSize: 0) == nil)
    }


    @Test("a sector size a block is not a whole number of is refused")
    func raggedSectorSizeIsRefused() {
        // Truncating would leave a "block" of some other size while every offset
        // below went on being computed in four-kilobyte units. Not a refusal:
        // every read landing somewhere else.
        #expect(FSLayout.Plan(sectorCount: 4096, sectorSize: 3000) == nil)
        #expect(FSLayout.Plan(sectorCount: 4096, sectorSize: 513) == nil)

        // And the ones that do divide still work.
        #expect(FSLayout.Plan(sectorCount: 4096, sectorSize: 512) != nil)
        #expect(FSLayout.Plan(sectorCount: 4096, sectorSize: 4096) != nil)
    }


    @Test("rounding up a length near the top of the range does not wrap")
    func divideUpDoesNotWrap() {
        // `(value + unit - 1) / unit` overflows the addition before it divides.
        #expect(FSLayout.divideUp(UInt64.max, 4096) == (UInt64.max / 4096) + 1)
        #expect(FSLayout.divideUp(UInt64.max, 1) == UInt64.max)
        #expect(FSLayout.divideUp(0, 4096) == 0)
        #expect(FSLayout.divideUp(4096, 4096) == 1)
        #expect(FSLayout.divideUp(4097, 4096) == 2)

        // A unit of nothing is not a division either.
        #expect(FSLayout.divideUp(10, 0) == 0)
    }


    // MARK: - What a client sends

    @Test("a write at an offset near the top of the range is refused")
    func hugeOffsetIsRefused() {
        // Straight out of a message: the offset is two words a client fills in.
        // Rounding it up to blocks gives a number no thirty-two bit conversion
        // can take, and the conversion was reached before anything asked.
        withDisk { fs in
            guard let object = file(&fs, "a.bin") else { return }

            let byte = "x" as StaticString

            for offset in [UInt64(1) << 40, UInt64(1) << 62, UInt64.max - 4096] {
                let written = fs.write(
                    object, at: offset, from: UnsafeRawPointer(byte.utf8Start), count: 1
                )

                #expect(written.status != .ok, "offset \(offset) was accepted")
                #expect(written.bytes == 0)
            }

            // And the file is untouched by all of it.
            #expect(fs.object(object)?.size == 0)
        }
    }


    @Test("a write whose end wraps is refused")
    func wrappingEndIsRefused() {
        withDisk { fs in
            guard let object = file(&fs, "a.bin") else { return }

            let byte = "x" as StaticString
            let written = fs.write(
                object,
                at   : UInt64.max - 1,
                from : UnsafeRawPointer(byte.utf8Start),
                count: 16
            )

            #expect(written.status != .ok)
        }
    }


    @Test("cutting a file to a length past the disk is not a conversion")
    func hugeTruncateIsClamped() {
        withDisk { fs in
            guard let object = file(&fs, "a.bin") else { return }

            let payload = UnsafeMutableRawPointer.allocate(byteCount: 4096, alignment: 8)
            defer { payload.deallocate() }
            payload.initializeMemory(as: UInt8.self, repeating: 1, count: 4096)

            #expect(fs.write(
                object, at: 0, from: UnsafeRawPointer(payload), count: 4096
            ).status == .ok)

            // Longer than it is, so nothing is cut - and the number is far past
            // anything a `UInt32` can hold.
            #expect(fs.truncate(object, to: UInt64.max) == .ok)
            #expect(fs.object(object)?.blocks == 1)
        }
    }


    // MARK: - What a damaged disk says

    @Test("a container that spent more than it had is not believed")
    func overspentContainerIsRefused() {
        // `quota - used` traps for this record. Nothing writing the disk can
        // make one, so it reads as damage - and damage is refused rather than
        // subtracted.
        var record = FSObject(kind: .container, created: 0)
        record.quota = 10
        record.used  = 40

        #expect(record.roomLeft == 0)

        guard let plan = FSLayout.Plan(sectorCount: 4096, sectorSize: 512) else {
            Issue.record("no plan")
            return
        }

        #expect(!record.fits(plan))
    }


    @Test("a run that would carry a record past the top of the range is refused")
    func appendDoesNotWrap() {
        var record = FSObject(kind: .file, created: 0)

        var joined = record.append(start: 100, count: 4)
        #expect(joined)
        #expect(record.blocks == 4)

        // Joined onto the end of the last run, and the join overflows.
        joined = record.append(start: 104, count: UInt32.max)
        #expect(!joined)
        #expect(record.blocks == 4, "a refused append changed the record")

        // A separate run, and the block count overflows.
        joined = record.append(start: 5000, count: UInt32.max)
        #expect(!joined)
        #expect(record.blocks == 4)

        // A run of nothing is not a run.
        joined = record.append(start: 200, count: 0)
        #expect(!joined)

        // And an ordinary one still works after all that.
        joined = record.append(start: 200, count: 2)
        #expect(joined)
        #expect(record.blocks == 6)
        #expect(record.extents == 2)
    }


    @Test("a run starting at the top of the range does not wrap into a join")
    func appendEndDoesNotWrap() {
        var record = FSObject(kind: .file, created: 0)

        var joined = record.append(start: UInt32.max - 1, count: 2)
        #expect(joined)

        // The end of that run is exactly the top, and computing it wraps to
        // zero. A second run starting at zero must not be joined onto it.
        joined = record.append(start: 0, count: 1)
        #expect(joined)
        #expect(record.extents == 2)
    }
}
