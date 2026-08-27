//
//  DurabilityTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/08/2026.

import Testing
import ReixABI
@testable import ReixFS

/// What a device says a completed write has achieved, and what the file system
/// does about it.
///
/// The three words are not synonyms and the whole ordering rule rests on which
/// one a disk means: a write that has *completed* has been taken, a write that
/// is *ordered* cannot reach the medium after a later one, and a write that is
/// *durable* survives the power going. A disk with a write cache gives the first
/// and needs a flush for the other two; a disk without one gives all three at
/// once, and asking it for a barrier is a round trip for nothing.
///
/// And a disk may say none of it, which is the case the type could not express
/// and this suite grew for. A driver read "this device never offered a way to
/// empty its write cache" as "this device has no write cache", which is the
/// strongest of the three claims; so a disk that had promised nothing was
/// mounted read-write and the ordering rule became a wish about a queue. Every
/// test below the barrier ones is about a refusal.
@Suite("Completed, ordered and durable are three things")
struct DurabilityTests {

    private static let sectors: UInt64 = 4096


    private func withScratch(_ body: (UnsafeMutableRawPointer) -> Void) {
        let scratch = UnsafeMutableRawPointer.allocate(
            byteCount: FileSystem<MemoryDisk>.scratchBytes,
            alignment: 8
        )
        defer { scratch.deallocate() }

        body(scratch)
    }


    private func withDisk(
        _ durability: BlockDurability,
        _ body: (inout FileSystem<MemoryDisk>, MemoryDisk) -> Void
    ) {
        let disk = MemoryDisk(sectors: Self.sectors)
        disk.durability = durability

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


    private func file(
        _ fs: inout FileSystem<MemoryDisk>,
        _ name: StaticString,
        blocks: Int
    ) -> UInt32? {
        let made = fs.create(
            UnsafeRawPointer(name.utf8Start),
            length: name.utf8CodeUnitCount,
            kind  : .file,
            in    : FSLayout.rootObject
        )
        guard made.status == .ok else { return nil }

        let bytes = Int(FSLayout.blockSize) * blocks
        let payload = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 8)
        defer { payload.deallocate() }
        payload.initializeMemory(as: UInt8.self, repeating: 0x5A, count: bytes)

        guard fs.write(
            made.object, at: 0, from: UnsafeRawPointer(payload), count: UInt64(bytes)
        ).status == .ok else { return nil }

        return made.object
    }


    @Test("a disk with a cache is asked for the barrier it needs")
    func cachedDiskIsFlushed() {
        withDisk(.onFlush) { fs, disk in
            guard let object = file(&fs, "big.bin", blocks: 6) else { return }

            let before = disk.flushes
            #expect(fs.truncate(object, to: FSLayout.blockSize) == .ok)
            #expect(disk.flushes > before)
        }
    }


    @Test("a disk without one is not asked, because the answer is already yes")
    func uncachedDiskIsNotFlushed() {
        // The declaration earning its keep. Without it every barrier on such a
        // disk is a round trip that changes nothing - and through a block client
        // that is a round trip across an IPC.
        withDisk(.onCompletion) { fs, disk in
            guard let object = file(&fs, "big.bin", blocks: 6) else { return }

            let before = disk.flushes
            #expect(fs.truncate(object, to: FSLayout.blockSize) == .ok)
            #expect(disk.flushes == before)
        }
    }


    @Test("skipping the flush does not skip the ordering")
    func uncachedDiskStillOrders() {
        // The thing that must not be traded away: the barrier is cheaper on such
        // a disk, not absent. Blocks are still released only after the record
        // that stopped naming them is written, so the invariant holds either way.
        for durability in [BlockDurability.onFlush, .onCompletion] {
            withDisk(durability) { fs, disk in
                guard let object = file(&fs, "big.bin", blocks: 6) else { return }

                disk.failAfter(4)
                _ = fs.truncate(object, to: FSLayout.blockSize)
                disk.recover()
                fs.dropCache()

                #expect(fs.scan().ownedButFree == 0)
            }
        }
    }


    // MARK: - The wire

    @Test("all three answers survive the trip to a client")
    func durabilityCrossesTheWire() {
        // Two bits of the sector-size word, because the four words of a geometry
        // answer were already spoken for and a sector size is never that big.
        for durability in [BlockDurability.unknown, .onCompletion, .onFlush] {
            let message = BlockOperation.geometry(
                sectorSize : 512,
                sectorCount: 32768,
                durability : durability
            )

            let device = BlockOperation.device(of: message)

            #expect(device.sectorSize == 512)
            #expect(device.sectorCount == 32768)
            #expect(device.durability == durability)
        }

        // And a large but real sector size still comes back whole.
        let big = BlockOperation.device(of: BlockOperation.geometry(
            sectorSize : 4096,
            sectorCount: 1,
            durability : .onFlush
        ))

        #expect(big.sectorSize == 4096)
        #expect(big.durability == .onFlush)

        // A sector size the two bits leave no room for is sent as zero, which
        // every reader of this answer refuses. Masking it would hand back a size
        // the device never said, in the one direction that makes it look smaller.
        let absurd = BlockOperation.device(of: BlockOperation.geometry(
            sectorSize : 0x4000_0000,
            sectorCount: 1,
            durability : .onFlush
        ))

        #expect(absurd.sectorSize == 0)
        #expect(absurd.durability == .onFlush)
        #expect(!BlockGeometry.usable(
            sectorSize : absurd.sectorSize,
            sectorCount: absurd.sectorCount,
            window     : 4096
        ))
    }


    @Test("the reserved encoding is read as no claim at all")
    func reservedEncodingIsUnknown() {
        // Both bits set is the one pattern no encoder writes. A future build
        // that starts writing it is saying something this one cannot read, and
        // the safe reading of a claim you cannot read is that there is none.
        var words = InlineArray<4, UInt32>(repeating: 0)
        words[0] = BlockStatus.ok.rawValue
        words[1] = 512 | 0xC000_0000
        words[2] = 32768

        let device = BlockOperation.device(
            of: Message(tag: MessageTag(BlockOperation.geometry, length: 4), words: words)
        )

        #expect(device.durability == .unknown)
        #expect(device.sectorSize == 512)
    }


    // MARK: - The two doors into a writable volume

    @Test("mounting a disk that promises nothing writes nothing")
    func mountRefusesUnknown() {
        let disk = MemoryDisk(sectors: Self.sectors)

        withScratch { scratch in
            // A real file system on it first, so the refusal cannot be mistaken
            // for a disk that simply had nothing to mount.
            guard FileSystem.format(disk, scratch: scratch).disk != nil else {
                Issue.record("the fixture disk would not format")
                return
            }

            _ = FileSystem.mount(disk, scratch: scratch)    // leaves it marked

            disk.durability = .unknown
            let writes  = disk.writes
            let flushes = disk.flushes

            let found = FileSystem.mount(disk, scratch: scratch)

            #expect(found.disk == nil)
            #expect(isDurabilityUnknown(found.found))
            #expect(disk.writes  == writes)
            #expect(disk.flushes == flushes)
        }
    }


    @Test("formatting a disk that promises nothing writes nothing")
    func formatRefusesUnknown() {
        let disk = MemoryDisk(sectors: Self.sectors)
        disk.durability = .unknown

        withScratch { scratch in
            let made = FileSystem.format(disk, scratch: scratch)

            #expect(made.disk == nil)
            #expect(made.made == .durabilityUnknown)
            #expect(disk.writes  == 0)
            #expect(disk.flushes == 0)
        }
    }


    // MARK: - Geometry nobody can use

    @Test("a device with no sectors, or sectors nobody can hold, is refused")
    func unusableGeometryIsRefused() {
        let window: UInt64 = 4096

        // The real thing, for a floor under the refusals below.
        #expect(BlockGeometry.usable(sectorSize: 512, sectorCount: 32768, window: window))
        #expect(BlockGeometry.usable(sectorSize: 4096, sectorCount: 1, window: window))

        // Zero either way. A sector size of zero divides into the window
        // infinitely and traps doing it; a count of zero is a disk with nothing
        // on it that every range check then reads as "everything is past the
        // end".
        #expect(!BlockGeometry.usable(sectorSize: 0, sectorCount: 32768, window: window))
        #expect(!BlockGeometry.usable(sectorSize: 512, sectorCount: 0, window: window))

        // A sector too big for the window is a device that attaches and then
        // refuses every transfer, which is worse than refusing the attach.
        #expect(!BlockGeometry.usable(sectorSize: 8192, sectorCount: 8, window: window))
    }


    @Test("a device whose size cannot be counted in bytes is refused")
    func overflowingGeometryIsRefused() {
        let window: UInt64 = 4096

        // Eight sectors short of the top: the product is one bit past sixty-four
        // and the multiplication that every caller writes for itself traps.
        #expect(!BlockGeometry.usable(
            sectorSize : 512,
            sectorCount: UInt64.max / 512 + 1,
            window     : window
        ))

        // And the convenience that does the multiplication says so rather than
        // taking the process down with it.
        let huge = ClaimedDisk(sectorSize: 512, sectorCount: UInt64.max / 512 + 1)
        #expect(huge.byteCount == nil)

        let real = ClaimedDisk(sectorSize: 512, sectorCount: 32768)
        #expect(real.byteCount == 32768 * 512)
    }
}
