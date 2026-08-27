//
//  LifecycleTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/08/2026.


import Testing
import ReixABI
@testable import ReixFS

/// What this process says it holds, against what the disk holds.
///
/// Three places kept the two apart. A rename put the new name in the copy this
/// process reads *before* asking the disk to take it, so a rename whose flush
/// failed left a machine answering to a name no disk had ever heard of - for the
/// rest of the boot, because nothing reads the superblock again. A refund clamped
/// to zero, which wrote the *result* of a contradiction back over the number that
/// would have shown it. And the counters that report findings wrapped, so a
/// report could come back saying there were none.
@Suite("What memory says and what the disk says")
struct LifecycleTests {

    private static let sectors: UInt64 = 4096      // 2 MiB
    private static let block = Int(FSLayout.blockSize)

    private func scratch() -> UnsafeMutableRawPointer {
        UnsafeMutableRawPointer.allocate(
            byteCount: FileSystem<MemoryDisk>.scratchBytes, alignment: 8
        )
    }

    private func withDisk(
        _ body: (inout FileSystem<MemoryDisk>, MemoryDisk) -> Void
    ) {
        let disk  = MemoryDisk(sectors: Self.sectors)
        let space = scratch()
        defer { space.deallocate() }

        guard var fs = FileSystem.format(disk, scratch: space).disk else {
            Issue.record("the fixture disk would not format")
            return
        }

        body(&fs, disk)
    }

    private func named(_ text: StaticString, _ body: (UnsafeRawPointer, Int) -> Void) {
        body(UnsafeRawPointer(text.utf8Start), text.utf8CodeUnitCount)
    }

    /// The machine's name, as this process would answer it.
    private func name(_ fs: inout FileSystem<MemoryDisk>) -> String {
        let out = UnsafeMutableRawPointer.allocate(
            byteCount: FSLayout.machineNameLimit, alignment: 8
        )
        defer { out.deallocate() }

        let length = fs.machineName(into: out)
        let bytes  = out.assumingMemoryBound(to: UInt8.self)

        var read = ""
        for index in 0..<length { read.append(Character(UnicodeScalar(bytes[index]))) }

        return read
    }

    /// The machine's name as it is on the medium, out of whichever superblock is
    /// the newer whole one.
    private func nameOnDisk(_ disk: MemoryDisk, _ plan: FSLayout.Plan) -> String {

        var best: (generation: UInt64, name: String)? = nil

        for copy in [FSLayout.superblockA, FSLayout.superblockB] {
            let at = Int(copy) * Self.block

            let raw = UnsafeMutableRawPointer.allocate(byteCount: Self.block, alignment: 8)
            defer { raw.deallocate() }

            for byte in 0..<Self.block {
                raw.storeBytes(
                    of: disk.byte(at: at + byte), toByteOffset: byte, as: UInt8.self
                )
            }

            guard FSSuperblock.verdict(of: raw, against: plan) == .whole else { continue }

            let block = FSSuperblock(reading: raw)

            var read = ""
            var index = 0
            while index < FSLayout.machineNameLimit,
                  block.name[index] > 0x20, block.name[index] < 0x7F {
                read.append(Character(UnicodeScalar(block.name[index])))
                index += 1
            }

            if best == nil || block.generation > best!.generation {
                best = (block.generation, read)
            }
        }

        return best?.name ?? ""
    }


    // MARK: - A rename the disk did not take

    @Test("a rename the disk refused leaves memory and the medium agreeing")
    func renameUnderFaults() {
        var refused = 0
        var took    = 0

        for stop in 1...12 {
            let disk  = MemoryDisk(sectors: Self.sectors)
            let space = scratch()
            defer { space.deallocate() }

            guard var fs = FileSystem.format(disk, scratch: space).disk else {
                Issue.record("format")
                return
            }

            #expect(name(&fs) == "reix", "stop \(stop)")

            disk.failAfter(stop)

            var status = FSStatus.ok
            named("elsewhere") { pointer, length in
                status = fs.setMachineName(pointer, length: length)
            }

            disk.recover()

            let inMemory = name(&fs)
            let onDisk   = nameOnDisk(disk, fs.plan)
            let plan     = fs.plan

            if status == .ok {
                took += 1

                // Both, and they agree. This is the half that always worked.
                #expect(inMemory == "elsewhere", "stop \(stop)")
                #expect(onDisk == "elsewhere", "stop \(stop)")
                #expect(!fs.corrupted, "stop \(stop)")

            } else {
                refused += 1

                // The name it started with. It used to be the new one over a
                // disk that had refused it, for the rest of the boot.
                #expect(inMemory == "reix", "stop \(stop)")

                // And the volume held, because which copy the medium kept is not
                // knowable from here.
                #expect(fs.corrupted, "stop \(stop)")

                let before = disk.writes
                named("third") { pointer, length in
                    #expect(fs.setMachineName(pointer, length: length) != .ok)
                }
                #expect(disk.writes == before, "stop \(stop): written after a refusal")
            }

            // Whatever happened, the medium holds a whole superblock and it is
            // one of the two names - never half of either, and never neither.
            #expect(onDisk == "reix" || onDisk == "elsewhere", "stop \(stop): \(onDisk)")

            // And a process that starts again answers what the disk says, which
            // is the recoverable form of "memory and the medium agree".
            let other = scratch()
            defer { other.deallocate() }

            guard var again = FileSystem.mount(disk, scratch: other).disk else {
                Issue.record("stop \(stop): the disk would not mount again")
                continue
            }

            #expect(name(&again) == nameOnDisk(disk, plan), "stop \(stop)")
        }

        #expect(took    > 0, "no fault point let the rename through")
        #expect(refused > 0, "no fault point stopped the rename")
    }


    @Test("a rename with a name too long, or none, changes nothing anywhere")
    func renameRefusesBadNames() {
        withDisk { fs, disk in
            named("with/slash") { pointer, length in
                #expect(fs.setMachineName(pointer, length: length) == .badName)
            }

            #expect(fs.setMachineName(UnsafeRawPointer(bitPattern: 1)!, length: 0) == .badName)

            #expect(name(&fs) == "reix")
            #expect(nameOnDisk(disk, fs.plan) == "reix")
        }
    }


    // MARK: - An unmount the disk did not take

    @Test("an unmount the disk refused is not reported as one that happened")
    func unmountUnderFaults() {
        var refused = 0
        var took    = 0

        for stop in 1...8 {
            let disk  = MemoryDisk(sectors: Self.sectors)
            let space = scratch()
            defer { space.deallocate() }

            guard var fs = FileSystem.format(disk, scratch: space).disk else {
                Issue.record("format")
                return
            }

            disk.failAfter(stop)
            let status = fs.unmount()
            disk.recover()

            if status == .ok {
                took += 1
                #expect(!fs.corrupted, "stop \(stop)")

            } else {
                refused += 1

                // Two shapes, both named: nothing was written and retrying works,
                // or the publish was interrupted and the volume is held.
                let before = disk.writes

                if fs.corrupted {
                    #expect(fs.unmount() != .ok, "stop \(stop)")
                    #expect(disk.writes == before, "stop \(stop): written while held")

                } else {
                    #expect(fs.unmount() == .ok, "stop \(stop): not retryable")
                }
            }

            let other = scratch()
            defer { other.deallocate() }

            let attempt = FileSystem.mount(disk, scratch: other)

            guard let again = attempt.disk else {
                Issue.record("stop \(stop): would not mount, \(attempt.found)")
                continue
            }

            // `ok` is a claim about the medium and it has to be true of it. The
            // other way round does not hold and must not be asserted: a write the
            // device took and did not flush leaves the mark down anyway, which is
            // exactly why the refusal above holds the volume instead of guessing.
            if status == .ok {
                #expect(!again.wasDirty, "stop \(stop): ok over a disk still dirty")
            }
        }

        #expect(took    > 0, "no fault point let the unmount through")
        #expect(refused > 0, "no fault point stopped the unmount")
    }


    @Test("an unmount refused before publication can be retried")
    func unmountRetriesAfterBarrierRefusal() {
        withDisk { fs, disk in
            disk.failAfter(1)

            #expect(fs.unmount() == .deviceFailed)
            #expect(!fs.corrupted)

            disk.recover()

            #expect(fs.unmount() == .ok)
            #expect(!fs.corrupted)
        }
    }


    @Test("a superblock with no generation left refuses rather than wrapping")
    func generationExhaustionIsRefused() {
        withDisk { fs, disk in

            // Both copies at the top of the range, behind the file system's back,
            // and then mounted again so the number in memory is that one.
            for copy in [FSLayout.superblockA, FSLayout.superblockB] {
                disk.poke(
                    UInt64.max,
                    at: Int(copy) * Self.block + FSSuperblock.generationOffset
                )
            }

            _ = fs

            let space = scratch()
            defer { space.deallocate() }

            // The mount itself has to publish a generation, so it is the first
            // thing refused. Refused, and not a mount over a wrapped number.
            let attempt = FileSystem.mount(disk, scratch: space)

            #expect(attempt.disk == nil)
            if case .ok = attempt.found { Issue.record("a mount with no generation left") }
        }
    }


    // MARK: - A refund that cannot be true

    @Test("a container asked to take back more than it holds is not normalised")
    func refundUnderflowIsRefused() {
        withDisk { fs, disk in
            var made: UInt32 = 0

            named("a.bin") { pointer, length in
                let result = fs.create(
                    pointer, length: length, kind: .file, in: FSLayout.rootObject
                )
                made = result.object
            }

            let payload = UnsafeMutableRawPointer.allocate(
                byteCount: Self.block * 2, alignment: 8
            )
            defer { payload.deallocate() }
            payload.initializeMemory(as: UInt8.self, repeating: 0x5A, count: Self.block * 2)

            #expect(fs.write(
                made, at: 0, from: UnsafeRawPointer(payload), count: UInt64(Self.block * 2)
            ).status == .ok)

            guard let root = fs.object(FSLayout.rootObject) else { return }
            #expect(root.used >= 2)

            // Fewer blocks than the file it owns has, which no disk this build
            // wrote can say. The clamp used to write the difference away.
            let at = Int(fs.plan.tableStart) * Self.block
                + Int(FSLayout.rootObject) * Int(FSLayout.objectSize)

            disk.poke(UInt32(1), at: at + 36)      // `used`
            fs.dropCache()

            #expect(fs.begin() == .ok)
            let given = fs.refund(2, toContainer: FSLayout.rootObject)
            #expect(given == .quarantined)
            #expect(fs.finish(given) == .quarantined)

            #expect(fs.corrupted)

            // And nothing was written on the way out.
            let before = disk.writes
            named("after.bin") { pointer, length in
                #expect(fs.create(
                    pointer, length: length, kind: .file, in: FSLayout.rootObject
                ).status != .ok)
            }
            #expect(disk.writes == before)
        }
    }


    @Test("nothing to give back is not a refund, and cannot underflow")
    func refundOfNothing() {
        withDisk { fs, _ in
            #expect(fs.begin() == .ok)

            #expect(fs.refund(0, toContainer: FSLayout.rootObject) == .ok)
            #expect(fs.refund(0, to: FSLayout.rootObject) == .ok)

            #expect(fs.transactionRefusal == nil)
            #expect(fs.commit() == .ok)
            #expect(!fs.corrupted)
        }
    }


    // MARK: - The window a client replaces

    /// The order the servers attach in, with one step made to fail.
    ///
    /// A model of it, and it is the type that enforces the rule: `install` is the
    /// only thing that changes `current`, and it comes last. What is walked here
    /// is that every step before it can fail without the client losing the
    /// attachment it already had - which is precisely what the file system server
    /// used to get wrong by releasing the old slot first.
    private func attaching(
        _ slot: inout ShmAttachment.Slot,
        failingAt step: Int,
        address: UInt64
    ) -> ShmAttachment? {

        // 1: the grant is not one to accept.
        guard step != 1, ShmAttachment.accepts(pages: 2, atMost: 4) else { return nil }

        // 2: no attachment number left.
        guard step != 2, let epoch = slot.nextEpoch() else { return nil }

        // 3: the mapping failed.
        guard step != 3 else { return nil }

        // 4: the grant could not be taken.
        guard step != 4 else { return nil }

        return slot.install(ShmAttachment(
            identity: 7, epoch: epoch, address: address, extent: 8192, grant: 11
        ))
    }


    @Test("a reattach that fails at any step leaves the old session working")
    func failedReattachKeepsTheOldWindow() {

        for step in 1...4 {
            var slot = ShmAttachment.Slot()

            // The first attachment, which succeeds.
            #expect(attaching(&slot, failingAt: 0, address: 0x1000) == nil)

            guard let first = slot.current else {
                Issue.record("step \(step): the first attach did not take")
                return
            }

            #expect(first.address == 0x1000)
            #expect(first.extent == 8192)

            // The second, which does not. Nothing of the first is let go.
            let displaced = attaching(&slot, failingAt: step, address: 0x2000)

            #expect(displaced == nil, "step \(step)")
            #expect(slot.current?.address == 0x1000, "step \(step)")
            #expect(slot.current?.epoch == first.epoch, "step \(step)")
            #expect(slot.held(by: 7), "step \(step)")
        }
    }


    @Test("a reattach that succeeds hands back the window to unmap")
    func reattachHandsBackTheOldWindow() {
        var slot = ShmAttachment.Slot()

        #expect(attaching(&slot, failingAt: 0, address: 0x1000) == nil)

        guard let letGo = attaching(&slot, failingAt: 0, address: 0x2000) else {
            Issue.record("the second attach handed nothing back")
            return
        }

        // The old one comes back out of `install`, which is what makes the unmap
        // impossible to forget: there is nowhere else to get it from.
        #expect(letGo.address == 0x1000)
        #expect(slot.current?.address == 0x2000)
        #expect(letGo.epoch != slot.current?.epoch)
    }
}
