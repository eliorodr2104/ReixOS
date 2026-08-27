//
//  RetirementTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/08/2026.


import Testing
import ReixABI
@testable import ReixFS

/// What happens when a slot has been reused as many times as a token can count.
///
/// The counter used to go round. Thirty-two bits in the record, cut down to
/// whatever a badge could carry, and a badge for generation zero of slot twelve
/// would - after enough removals - name a live file again. Which is the one thing
/// the counter exists to prevent, so the answer cannot be "eventually it stops
/// working".
///
/// It does not go round now. A slot that reaches the last value both a badge and
/// a handle can tell apart is marked out of use and never handed out again. The
/// cost is one slot in a thousand after a few million reuses of it, which nothing
/// on this machine will ever pay; what it buys is that an old capability naming an
/// old incarnation names *nothing*, for good.
@Suite("Slots that have been reused enough")
struct RetirementTests {

    private static let sectors: UInt64 = 32768      // 16 MiB, 1024 object slots


    private func withFileSystem(
        _ body: (inout FileSystem<MemoryDisk>, MemoryDisk) -> Void
    ) {
        let disk = MemoryDisk(sectors: Self.sectors)

        let space = UnsafeMutableRawPointer.allocate(
            byteCount: FileSystem<MemoryDisk>.scratchBytes,
            alignment: 8
        )
        defer { space.deallocate() }

        guard var fs = FileSystem.format(disk, scratch: space).disk else {
            Issue.record("a fresh disk could not be formatted")
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

        return made.status == .ok ? made.object : nil
    }

    private func remove(
        _ fs: inout FileSystem<MemoryDisk>,
        _ name: StaticString
    ) -> FSStatus {
        fs.remove(
            UnsafeRawPointer(name.utf8Start),
            length: name.utf8CodeUnitCount,
            from  : FSLayout.rootObject
        )
    }


    /// Puts a generation on a record behind the file system's back.
    ///
    /// Two million removals is not a thing a test performs, so the counter is put
    /// where it would be. Nothing else about the record is touched.
    private func setGeneration(
        _ disk: MemoryDisk,
        _ plan: FSLayout.Plan,
        _ object: UInt32,
        _ generation: UInt32
    ) {
        let at = Int(plan.tableStart) * Int(FSLayout.blockSize)
            + Int(object) * Int(FSLayout.objectSize)

        disk.poke(generation, at: at + 48)
    }


    /// The last generation both a badge and a handle can tell apart on this disk.
    private func limit(_ plan: FSLayout.Plan) -> UInt32 {
        let badges = FSBadge(objectCount: plan.objectCount)
        return min(badges.lastGeneration, badges.handles.lastGeneration)
    }


    @Test("a slot at the last generation is retired rather than counted round")
    func theSlotRetires() {
        withFileSystem { fs, disk in
            guard let object = make(&fs, "doomed.bin") else {
                Issue.record("create"); return
            }

            let last = limit(fs.plan)

            // One short of the limit. The removal after this brings it to the
            // limit, and the one after that is the removal that would have
            // wrapped.
            setGeneration(disk, fs.plan, object, last - 1)
            fs.dropCache()

            #expect(remove(&fs, "doomed.bin") == .ok)

            guard let atLimit = fs.object(object) else {
                Issue.record("the free record went away")
                return
            }

            #expect(atLimit.generation == last)
            #expect(!atLimit.retired)

            // Still allocatable, so the slot is used once more.
            guard let again = make(&fs, "doomed.bin") else {
                Issue.record("the slot was not handed out at the limit")
                return
            }
            #expect(again == object)

            // And this is the removal that would have wrapped.
            #expect(remove(&fs, "doomed.bin") == .ok)

            guard let retired = fs.object(object) else {
                Issue.record("the free record went away")
                return
            }

            #expect(retired.generation == last, "the counter went round")
            #expect(retired.retired)
        }
    }


    @Test("a retired slot is never handed out again")
    func theSlotStaysOut() {
        withFileSystem { fs, disk in
            guard let object = make(&fs, "doomed.bin") else {
                Issue.record("create"); return
            }

            setGeneration(disk, fs.plan, object, limit(fs.plan))
            fs.dropCache()

            #expect(remove(&fs, "doomed.bin") == .ok)
            #expect(fs.object(object)?.retired == true)

            // Twenty more objects, and not one of them lands there. The
            // allocator walks past a retired slot rather than counting its
            // generation round.
            for index in 0..<20 {
                var name = InlineArray<8, UInt8>(repeating: 0)
                name[0] = UInt8(ascii: "n")
                name[1] = UInt8(0x30 + UInt8(index / 10))
                name[2] = UInt8(0x30 + UInt8(index % 10))

                var made: UInt32? = nil
                name.span.withUnsafeBufferPointer { buffer in
                    let result = fs.create(
                        UnsafeRawPointer(buffer.baseAddress!), length: 3,
                        kind: .file, in: FSLayout.rootObject
                    )
                    if result.status == .ok { made = result.object }
                }

                guard let made else {
                    Issue.record("create \(index)")
                    return
                }

                #expect(made != object, "the retired slot was handed out again")
            }

            // Which the scan is content with: a retired slot is a free slot with
            // a bit set, and a free slot is nobody's business.
            let findings = fs.scan(.everything)
            #expect(findings.complete)
            #expect(!findings.damaged)
        }
    }


    @Test("a token for a retired slot names nothing, and cannot come to name something")
    func staleTokensStayDead() {
        withFileSystem { fs, disk in
            guard let object = make(&fs, "doomed.bin") else {
                Issue.record("create"); return
            }

            let badges  = FSBadge(objectCount: fs.plan.objectCount)
            let handles = badges.handles

            // A token for the very first incarnation of the slot, which is the
            // one a wrap would eventually have matched again.
            let stale = handles.encode(object: object, generation: 0)

            setGeneration(disk, fs.plan, object, limit(fs.plan))
            fs.dropCache()

            #expect(remove(&fs, "doomed.bin") == .ok)

            // Nothing lives there, and nothing will: the slot is out of use, so
            // there is no future record for this token to match.
            #expect(fs.object(object)?.kind == .free)
            #expect(handles.object(of: stale) == object)
            #expect(!handles.names(
                generation: fs.object(object)?.generation ?? 0, handle: stale
            ))
        }
    }


    @Test("the retired bit survives being written and read")
    func theBitRoundTrips() {
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(FSLayout.objectSize), alignment: 8
        )
        defer { raw.deallocate() }
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: Int(FSLayout.objectSize))

        var record = FSObject(kind: .free, created: 0)
        #expect(!record.retired)

        record.retired = true
        #expect(record.retired)
        #expect(record.flags & FSObject.Flags.retired != 0)

        record.write(to: raw)
        #expect(FSObject(reading: raw).retired)

        record.retired = false
        #expect(!record.retired)
        #expect(record.flags == 0)
    }
}
