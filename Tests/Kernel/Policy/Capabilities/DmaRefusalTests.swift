//
//  DmaRefusalTests.swift
//  ReixOS
//

import Testing
@testable import Kernel
import ReixABI
import KernelTestSupport

/// What `dmaReclaim` does when the PPM will not take a quarantined block back.
///
/// Every refusal is staged the one way it can happen on a machine: the books
/// say something about the block other than "a live block of this order", or
/// they say that and the buddy disagrees. The rule each test pins is the same.
/// A refused block is not freed, not refunded and not forgotten, and nothing
/// frees it later either, however right its books come to look; one the books
/// call free is closed, refunded and counted as a double free, whether at the
/// first reclaim or at a later one of its own device, and of no other.
///
/// An extension of `DmaQuarantineTests`, for its fixture and its `.serialized`
/// trait: the ledger and the log ring are global.
extension KernelPolicyTestRoot.DmaQuarantineTests {

    /// One way the books can stop describing a quarantined block, and what the
    /// diagnosis has to call it.
    enum Injected: CaseIterable, Sendable {
        case interior
        case orderMismatch
        case reserved
        case kernelOwned
        case damaged

        var expected: PhysicalBlockState {
            switch self {
                case .interior     : .interior
                case .orderMismatch: .orderMismatch(recorded: 1)
                case .reserved     : .reserved
                case .kernelOwned  : .kernelOwned
                case .damaged      : .damaged
            }
        }

        /// Rewrites the head of a four-page block, answering what was there.
        func inject(_ ram: HostRAM, at head: PhysicalAddress) -> FrameInfo {
            let saved = ram.frame(at: head)
            var info  = saved

            switch self {
                case .interior     : info.order = 15
                case .orderMismatch: info.order = 1
                case .reserved     : info.flags.insert(.reserved)
                case .kernelOwned  : info.flags.insert(.kernel)
                case .damaged      : info.refCount = 0
            }

            ram.setFrame(info, at: head)
            return saved
        }
    }


    // MARK: - Every refusal

    @Test("a refused block is kept with its frames, its charge and its reading", arguments: Injected.allCases)
    func refusalKeepsEverything(_ cause: Injected) {
        withWorld { ram, heap, manager, ipc, context in
            guard let driver = try? manager.pointee.spawnProcess(),
                  let device = window(Self.disk, in: driver),
                  buffer(pages: 1, through: device, as: driver, publish: false, context) != nil,
                  let dead   = buffer(pages: 4, through: device, as: driver, context)
            else { return }

            let budget = budget(of: driver)
            let before = budget.pointee.charged
            let holds  = budget.pointee.references

            drop(dead, pages: 4, of: driver, ipc)

            let saved = cause.inject(ram, at: dead.physical)

            var answer: UInt64 = 0
            let logged = errorsLogged { answer = reclaim(UInt64(device), as: driver, context) }

            #expect(answer == 0)
            #expect(dead.region.pointee.refusal == cause.expected)
            #expect(counts() == (pages: 0, regions: 0, refused: 4, doubleFrees: 0))
            #expect(budget.pointee.charged == before)
            #expect(budget.pointee.references == holds)
            #expect(logged.count == 1)
            #expect(logged.first?.hasPrefix("quarantined DMA block at 0x") == true)
            #expect(logged.first?.contains("refused by the PPM") == true)
            #expect(logged.first?.contains("\(cause.expected.description)") == true)

            let stats = ProcStatsSyscall.systemSnapshot(ppm: ram.ppm, heap: heap)
            #expect(stats.physicalQuarantinedPages == 0)
            #expect(stats.physicalRefusedPages     == 4)
            #expect(stats.physicalDoubleFrees      == 0)

            // Looked at again, still wrong: kept, and nothing said twice.
            let again = errorsLogged { answer = reclaim(UInt64(device), as: driver, context) }

            #expect(answer == 0)
            #expect(again.isEmpty)
            #expect(dead.region.pointee.refusal == cause.expected)
            #expect(counts() == (pages: 0, regions: 0, refused: 4, doubleFrees: 0))

            // The books look right again: read, said once, and still left alone.
            ram.setFrame(saved, at: dead.physical)

            let untouched = books(ram)
            let changed   = errorsLogged { answer = reclaim(UInt64(device), as: driver, context) }

            #expect(answer == 0)
            #expect(books(ram) == untouched)
            #expect(dead.region.pointee.refusal == .live)
            #expect(changed.count == 1)
            #expect(changed.first?.contains("still kept") == true)
            #expect(counts() == (pages: 0, regions: 0, refused: 4, doubleFrees: 0))
            #expect(budget.pointee.charged == before)

            // Only books that say free close it, and then nothing is freed here.
            #expect((try? ram.ppm.pointee.free(PhysicalPage(address: dead.physical, order: 2))) != nil)

            #expect(reclaim(UInt64(device), as: driver, context) == 0)
            #expect(counts() == (pages: 0, regions: 0, refused: 0, doubleFrees: 1))
            #expect(budget.pointee.charged == before - 4)
            #expect(budget.pointee.references == holds - 1)
        }
    }


    /// Why a refused block is never freed on a live reading. The books keep no
    /// owner, so the same order at the same address can be anybody's by then.
    @Test("a stranger's block at a refused entry's address is left alone")
    func strangerAtTheSameAddress() {
        withWorld { ram, _, manager, ipc, context in
            guard let driver = try? manager.pointee.spawnProcess(),
                  let device = window(Self.disk, in: driver),
                  buffer(pages: 1, through: device, as: driver, publish: false, context) != nil,
                  let dead   = buffer(pages: 4, through: device, as: driver, context)
            else { return }

            let budget = budget(of: driver)
            let before = budget.pointee.charged

            drop(dead, pages: 4, of: driver, ipc)

            let saved = Injected.damaged.inject(ram, at: dead.physical)
            #expect(reclaim(UInt64(device), as: driver, context) == 0)

            // Freed behind the ledger's back, then handed to somebody else at the same order.
            ram.setFrame(saved, at: dead.physical)
            #expect((try? ram.ppm.pointee.free(PhysicalPage(address: dead.physical, order: 2))) != nil)

            var others: [PhysicalAddress] = []
            var stranger: PhysicalAddress? = nil

            while stranger == nil, let block = try? ram.ppm.pointee.alloc(Int(Self.page) * 4) {
                if block.address == dead.physical { stranger = block.address } else { others.append(block.address) }
            }

            for other in others {
                #expect((try? ram.ppm.pointee.free(PhysicalPage(address: other, order: 2))) != nil)
            }

            guard let stranger else {
                Issue.record("the block never came back at the same address")
                return
            }

            #expect(ram.ppm.pointee.diagnose(stranger, order: 2) == .live)

            let untouched = books(ram)

            #expect(reclaim(UInt64(device), as: driver, context) == 0)

            #expect(books(ram) == untouched)
            #expect(ram.ppm.pointee.refCount(of: stranger) == 1)
            #expect(dead.region.pointee.refusal == .live)
            #expect(counts() == (pages: 0, regions: 0, refused: 4, doubleFrees: 0))
            #expect(budget.pointee.charged == before)

            // The stranger lets go: only now do the books say free, and the entry closes.
            #expect((try? ram.ppm.pointee.free(PhysicalPage(address: stranger, order: 2))) != nil)

            #expect(reclaim(UInt64(device), as: driver, context) == 0)
            #expect(counts() == (pages: 0, regions: 0, refused: 0, doubleFrees: 1))
        }
    }


    /// The one refusal the books cannot explain: they describe a live block of
    /// the right order and the buddy, which has it free already, says no.
    @Test("books that look right but a buddy that refuses: kept, never retried, closed once they agree")
    func buddyRefusesConsistentBooks() {
        withWorld { ram, _, manager, ipc, context in
            guard let driver = try? manager.pointee.spawnProcess(),
                  let device = window(Self.disk, in: driver),
                  buffer(pages: 1, through: device, as: driver, publish: false, context) != nil,
                  let dead   = buffer(pages: 4, through: device, as: driver, context)
            else { return }

            let budget = budget(of: driver)
            let before = budget.pointee.charged

            drop(dead, pages: 4, of: driver, ipc)

            // Freed behind the ledger's back, then the books put back as they were.
            let frames  = (0..<4).map { dead.physical + UInt64($0) * Self.page }
            let records = frames.map { ram.frame(at: $0) }

            #expect((try? ram.ppm.pointee.free(PhysicalPage(address: dead.physical, order: 2))) != nil)
            for (frame, info) in zip(frames, records) { ram.setFrame(info, at: frame) }

            #expect(ram.ppm.pointee.diagnose(dead.physical, order: 2) == .live)

            var logged = errorsLogged { #expect(reclaim(UInt64(device), as: driver, context) == 0) }

            #expect(dead.region.pointee.refusal == .live)
            #expect(counts() == (pages: 0, regions: 0, refused: 4, doubleFrees: 0))
            #expect(logged.count == 1)

            // Read again, the same live block: not retried, and nothing said.
            let untouched = books(ram)
            logged = errorsLogged { #expect(reclaim(UInt64(device), as: driver, context) == 0) }

            #expect(logged.isEmpty)
            #expect(books(ram) == untouched)
            #expect(counts() == (pages: 0, regions: 0, refused: 4, doubleFrees: 0))
            #expect(budget.pointee.charged == before)

            // The books catch up with the buddy: free, so closed as a double free.
            for frame in frames { ram.setFrame(FrameInfo(), at: frame) }

            logged = errorsLogged { #expect(reclaim(UInt64(device), as: driver, context) == 0) }

            #expect(counts() == (pages: 0, regions: 0, refused: 0, doubleFrees: 1))
            #expect(budget.pointee.charged == before - 4)
            #expect(logged.count == 1)
            #expect(logged.first?.contains("was already free") == true)
        }
    }


    // MARK: - Already free

    @Test("a block already free at its first reclaim is closed, refunded and counted")
    func alreadyFreeAtTheFirstReclaim() {
        withWorld { ram, heap, manager, ipc, context in
            guard let driver = try? manager.pointee.spawnProcess(),
                  let device = window(Self.disk, in: driver),
                  buffer(pages: 1, through: device, as: driver, publish: false, context) != nil,
                  let dead   = buffer(pages: 4, through: device, as: driver, context)
            else { return }

            let budget = budget(of: driver)
            let before = budget.pointee.charged
            let holds  = budget.pointee.references

            drop(dead, pages: 4, of: driver, ipc)

            #expect((try? ram.ppm.pointee.free(PhysicalPage(address: dead.physical, order: 2))) != nil)

            var answer: UInt64 = 0
            let logged = errorsLogged { answer = reclaim(UInt64(device), as: driver, context) }

            // Nothing given back by this call: the frames were back already.
            #expect(answer == 0)
            #expect(counts() == (pages: 0, regions: 0, refused: 0, doubleFrees: 1))
            #expect(budget.pointee.charged == before - 4)
            #expect(budget.pointee.references == holds - 1)
            #expect(logged.count == 1)
            #expect(logged.first?.hasPrefix("quarantined DMA block at 0x") == true)
            #expect(logged.first?.contains("was already free") == true)

            let stats = ProcStatsSyscall.systemSnapshot(ppm: ram.ppm, heap: heap)
            #expect(stats.physicalDoubleFrees  == 1)
            #expect(stats.physicalRefusedPages == 0)
        }
    }


    @Test("a refused block that a later reclaim finds free is closed then, and counted")
    func alreadyFreeAtALaterReclaim() {
        withWorld { ram, _, manager, ipc, context in
            guard let driver = try? manager.pointee.spawnProcess(),
                  let device = window(Self.disk, in: driver),
                  buffer(pages: 1, through: device, as: driver, publish: false, context) != nil,
                  let dead   = buffer(pages: 4, through: device, as: driver, context)
            else { return }

            let budget = budget(of: driver)
            let before = budget.pointee.charged

            drop(dead, pages: 4, of: driver, ipc)

            let saved = Injected.damaged.inject(ram, at: dead.physical)

            #expect(reclaim(UInt64(device), as: driver, context) == 0)
            #expect(counts() == (pages: 0, regions: 0, refused: 4, doubleFrees: 0))

            // Somebody frees it while it sits refused.
            ram.setFrame(saved, at: dead.physical)
            #expect((try? ram.ppm.pointee.free(PhysicalPage(address: dead.physical, order: 2))) != nil)

            let logged = errorsLogged { #expect(reclaim(UInt64(device), as: driver, context) == 0) }

            #expect(counts() == (pages: 0, regions: 0, refused: 0, doubleFrees: 1))
            #expect(budget.pointee.charged == before - 4)
            #expect(logged.count == 1)
            #expect(logged.first?.contains("was already free") == true)
        }
    }


    // MARK: - Other devices

    @Test("a refused block is looked at only by its own device's reclaim")
    func otherDeviceUntouched() {
        withWorld { ram, _, manager, ipc, context in
            guard let driver = try? manager.pointee.spawnProcess(),
                  let disk   = window(Self.disk, in: driver),
                  let other  = window(Self.other, in: driver),
                  buffer(pages: 1, through: disk, as: driver, publish: false, context) != nil,
                  let mine   = buffer(pages: 4, through: disk,  as: driver, context),
                  let theirs = buffer(pages: 4, through: other, as: driver, context)
            else { return }

            drop(mine,   pages: 4, of: driver, ipc)
            drop(theirs, pages: 4, of: driver, ipc)

            let saved = Injected.interior.inject(ram, at: theirs.physical)

            #expect(reclaim(UInt64(other), as: driver, context) == 0)
            #expect(theirs.region.pointee.refusal == .interior)

            // Their books change, but only their own device's reclaim reads them.
            ram.setFrame(saved, at: theirs.physical)

            #expect(reclaim(UInt64(disk), as: driver, context) == 4)
            #expect(theirs.region.pointee.refusal == .interior)
            #expect(ram.ppm.pointee.refCount(of: theirs.physical) == 1)
            #expect(counts() == (pages: 0, regions: 0, refused: 4, doubleFrees: 0))

            #expect(reclaim(UInt64(other), as: driver, context) == 0)
            #expect(theirs.region.pointee.refusal == .live)
            #expect(ram.ppm.pointee.refCount(of: theirs.physical) == 1)
            #expect(counts() == (pages: 0, regions: 0, refused: 4, doubleFrees: 0))
        }
    }


    // MARK: - A creator that is gone

    /// The entry is the last hold on a dead creator's budget, refused or not,
    /// and only closing it lets the cell go.
    @Test("a dead creator's budget outlives a refusal and goes when the entry closes", arguments: [false, true])
    func deadCreator(refusedFirst: Bool) {
        withWorld(pages: 256) { ram, heap, manager, ipc, context in
            guard let bus      = try? manager.pointee.spawnProcess(),
                  let resetter = window(Self.disk, in: bus)
            else { return }

            // Twice: the first round pulls in the slabs, the second is measured.
            for round in 0..<2 {
                let pages = ram.ppm.pointee.allocatedPages
                let live  = heap.pointee.metricsLiveBytes

                guard let driver = try? manager.pointee.spawnProcess(),
                      let device = window(Self.disk, in: driver),
                      let dead   = buffer(pages: 4, through: device, as: driver, context)
                else { return }

                let budget = budget(of: driver)

                drop(dead, pages: 4, of: driver, ipc)
                tearDown(driver, manager, ipc)

                if refusedFirst {
                    let saved = Injected.damaged.inject(ram, at: dead.physical)

                    #expect(reclaim(UInt64(resetter), as: bus, context) == 0)
                    #expect(budget.pointee.references == 1)

                    ram.setFrame(saved, at: dead.physical)
                }

                // Only a block the books call free closes the entry, and with it the budget.
                #expect((try? ram.ppm.pointee.free(PhysicalPage(address: dead.physical, order: 2))) != nil)

                #expect(reclaim(UInt64(resetter), as: bus, context) == 0)
                #expect(DmaQuarantine.doubleFrees == UInt32(round + 1))

                #expect(DmaQuarantine.regions      == 0)
                #expect(DmaQuarantine.refusedPages == 0)

                if round == 1 {
                    #expect(ram.ppm.pointee.allocatedPages == pages)
                    #expect(heap.pointee.metricsLiveBytes == live)
                }
            }
        }
    }


    // MARK: - Boundary

    @Test("one reclaim over healthy, refused and already free blocks settles each its own way")
    func mixedReclaim() {
        withWorld { ram, heap, manager, ipc, context in
            guard let driver = try? manager.pointee.spawnProcess(),
                  let disk   = window(Self.disk, in: driver),
                  let other  = window(Self.other, in: driver),
                  buffer(pages: 1, through: disk, as: driver, publish: false, context) != nil
            else { return }

            let budget = budget(of: driver)
            let before = budget.pointee.charged

            guard let healthy   = buffer(pages: 4, through: disk,  as: driver, context),
                  let refused   = buffer(pages: 2, through: disk,  as: driver, context),
                  let small     = buffer(pages: 1, through: disk,  as: driver, context),
                  let freed     = buffer(pages: 4, through: disk,  as: driver, context),
                  let elsewhere = buffer(pages: 2, through: other, as: driver, context)
            else { return }

            drop(healthy,   pages: 4, of: driver, ipc)
            drop(refused,   pages: 2, of: driver, ipc)
            drop(small,     pages: 1, of: driver, ipc)
            drop(freed,     pages: 4, of: driver, ipc)
            drop(elsewhere, pages: 2, of: driver, ipc)

            #expect(budget.pointee.charged == before + 13)

            _ = Injected.interior.inject(ram, at: refused.physical)
            #expect((try? ram.ppm.pointee.free(PhysicalPage(address: freed.physical, order: 2))) != nil)

            var answer: UInt64 = 0
            let logged = errorsLogged { answer = reclaim(UInt64(disk), as: driver, context) }

            #expect(answer == 5)
            #expect(ram.ppm.pointee.refCount(of: healthy.physical) == 0)
            #expect(ram.ppm.pointee.refCount(of: small.physical)   == 0)
            #expect(refused.region.pointee.refusal == .interior)
            #expect(ram.ppm.pointee.refCount(of: elsewhere.physical) == 1)

            // Still paying for the refused block and the other device's one.
            #expect(budget.pointee.charged == before + 4)
            #expect(counts() == (pages: 2, regions: 1, refused: 2, doubleFrees: 1))
            #expect(logged.count == 2)

            let stats = ProcStatsSyscall.systemSnapshot(ppm: ram.ppm, heap: heap)
            #expect(stats.physicalQuarantinedPages   == 2)
            #expect(stats.physicalQuarantinedRegions == 1)
            #expect(stats.physicalRefusedPages       == 2)
            #expect(stats.physicalDoubleFrees        == 1)
        }
    }


    // MARK: - Fixture

    private func budget(
        of process: UnsafeMutablePointer<Process>
    ) -> UnsafeMutablePointer<FrameBudget> {
        process.pointee.metadata.pointee.budget
    }


    /// The PPM's books and the buddy's bitmap and free-list heads, without the
    /// arena's bytes: the region cells live there, and a reclaim writes its
    /// reading into them.
    private func books(_ ram: HostRAM) -> Books {
        let full  = ram.pmmStateSnapshot()
        let buddy = (ram.pages + 7) / 8 + BuddyAllocator.freeListsBytes

        return Books(
            metadata      : full.metadata,
            buddy         : Array(full.allocator.prefix(buddy)),
            allocatedPages: full.allocatedPages
        )
    }


    struct Books: Equatable {
        let metadata      : [UInt8]
        let buddy         : [UInt8]
        let allocatedPages: UInt64
    }


    private func counts() -> (pages: UInt32, regions: UInt32, refused: UInt32, doubleFrees: UInt32) {
        (DmaQuarantine.pages, DmaQuarantine.regions, DmaQuarantine.refusedPages, DmaQuarantine.doubleFrees)
    }


    /// The error lines the kernel logged while `body` ran, oldest first.
    private func errorsLogged(_ body: () -> Void) -> [String] {
        var mark: UInt64? = nil
        LogRing.forEachRecord { mark = $0.cursor }

        body()

        var lines: [String] = []
        LogRing.forEachRecord { record in
            if let mark, record.cursor <= mark { return }
            guard record.level == LogLevel.error.rawValue else { return }

            let payload = (0..<record.payloadLength).map { LogRing.payloadByte(record, $0) }
            lines.append(String(decoding: payload, as: UTF8.self))
        }

        return lines
    }
}
