//
//  AddressSpaceReleaseTests.swift
//  ReixOS
//

import Testing
@testable import Kernel
import KernelTestSupport
import KernelHostShims

/// `AddressSpaceRelease`, `releaseAddressSpace` cut into steps. What retiring a
/// page or freeing a table does is covered where it always was; this suite owns
/// the order of the stages, the step each one lands on, and the run they make.
///
/// The fixture is one anonymous page faulted into an otherwise empty process,
/// so the walk is two steps: the batch, and the one that finds the list empty.
extension KernelPolicyTestRoot {
@Suite("Address space release in steps", .serialized)
struct AddressSpaceReleaseTests {

    @Test("walk, manager, trap frame, tables: each on a step of its own, in order")
    func stagesInOrder() {
        withDyingProcess { ram, manager, process in
            var release = AddressSpaceRelease(
                process: process,
                heap   : manager.pointee.heap,
                vmm    : manager.pointee.vmm
            )

            let asid = process.pointee.addressSpace.asid
            var log  = Observation.log(of: process, asid: asid)

            while true {
                guard let progress = try? release.step() else {
                    Issue.record("a release over a sound root threw")
                    return
                }

                log.record(Observation(of: process, asid: asid))

                if progress == .done { break }
            }

            #expect(log.changes == [
                ["regions"], [], [], ["manager"], ["trapFrame"], ["invalidated"]
            ])
        }
    }


    /// Before the last step the dying tag is still held, so a fresh space gets
    /// another; after it the allocator hands that very tag back, its
    /// invalidation already recorded.
    @Test("the tag goes back on the last step, after its invalidation, and not before")
    func tagReleasedLast() {
        withDyingProcess { ram, manager, process in
            var release = AddressSpaceRelease(
                process: process,
                heap   : manager.pointee.heap,
                vmm    : manager.pointee.vmm
            )

            let asid = process.pointee.addressSpace.asid

            for _ in 0..<5 {
                #expect((try? release.step()) == .more)
            }

            guard let probe = try? ram.vmm.pointee.createAddressSpace() else {
                Issue.record("the arena gave no probe address space")
                return
            }
            #expect(probe.asid != asid)
            try? ram.vmm.pointee.destroyAddressSpace(addressSpace: probe)

            mmu_trace_reset(nil)
            #expect((try? release.step()) == .done)
            #expect(mmuCalls().filter { $0.op == .tlbASID }.map(\.arg) == [UInt64(asid)])

            guard let reissued = try? ram.vmm.pointee.createAddressSpace() else {
                Issue.record("the arena gave no address space after the release")
                return
            }
            #expect(reissued.asid == asid)
            try? ram.vmm.pointee.destroyAddressSpace(addressSpace: reissued)
        }
    }


    @Test("a process with no manager skips the walk and goes straight to its trap frame")
    func noManager() {
        withDyingProcess { ram, manager, process in
            guard let vma = process.pointee.addressSpace.vmaManager else {
                Issue.record("the fixture has no manager")
                return
            }

            // Empty it the way a death would, then take it away.
            _ = Preemption.run(AddressSpaceTeardown.self, vma.pointee.retirement())
            manager.pointee.heap.pointee.kfree(vma)
            process.pointee.addressSpace.vmaManager = nil

            var release = AddressSpaceRelease(
                process: process,
                heap   : manager.pointee.heap,
                vmm    : manager.pointee.vmm
            )

            let asid = process.pointee.addressSpace.asid
            var log  = Observation.log(of: process, asid: asid)

            while let progress = try? release.step() {
                log.record(Observation(of: process, asid: asid))
                if progress == .done { break }
            }

            #expect(log.changes == [[], ["trapFrame"], ["invalidated"]])
        }
    }


    /// A root whose frame record says it was never allocated is refused. The
    /// refusal is the last step's, so everything before it has happened, and the
    /// tag is kept rather than handed back over tables nobody freed.
    @Test("a root the PPM refuses throws from the last step and keeps the tag")
    func refusedRoot() {
        withDyingProcess { ram, manager, process in
            var release = AddressSpaceRelease(
                process: process,
                heap   : manager.pointee.heap,
                vmm    : manager.pointee.vmm
            )

            let asid  = process.pointee.addressSpace.asid
            let root  = process.pointee.addressSpace.rootTablePhysical
            let sound = ram.frame(at: root)

            for _ in 0..<5 {
                #expect((try? release.step()) == .more)
            }
            #expect(process.pointee.context == nil)
            #expect(process.pointee.addressSpace.vmaManager == nil)

            ram.setFrame(FrameInfo(refCount: sound.refCount, order: sound.order, flags: []), at: root)

            var refused = false
            do throws(PPMError) { _ = try release.step() } catch {
                if case .frameNotAllocated = error { refused = true }
            }
            #expect(refused)

            guard let probe = try? ram.vmm.pointee.createAddressSpace() else {
                Issue.record("the arena gave no probe address space")
                return
            }
            #expect(probe.asid != asid)
            try? ram.vmm.pointee.destroyAddressSpace(addressSpace: probe)

            ram.setFrame(sound, at: root)
            try? ram.ppm.pointee.freeOwnedKernelPage(PhysicalPage(address: root, order: 0))
        }
    }


    /// On the host the budget is zero, so a window follows every step that
    /// leaves work behind: six steps, five windows, and one span record.
    @Test("releaseAddressSpace is one run with a window at every boundary")
    func oneRun() {
        withDyingProcess { ram, manager, process in
            let mask = Trace.runtimeMask
            Trace.runtimeMask = 0x3F
            TraceRing.reset()
            defer { TraceRing.reset(); Trace.runtimeMask = mask }

            PreemptionSpans.reset()
            defer { PreemptionSpans.reset() }

            #expect((try? manager.pointee.releaseAddressSpace(process)) != nil)

            #expect(PreemptionSpans.span(of: AddressSpaceTeardown.self).checkpoints == 5)
            #expect(teardownSpans().map(\.b) == [5])
        }
    }


    // MARK: - Fixtures

    /// One process holding one faulted anonymous page, its manager list intact,
    /// and nobody current, as on the `exit` path.
    private func withDyingProcess(
        _ body: (HostRAM, UnsafeMutablePointer<ProcessManager>, UnsafeMutablePointer<Process>) -> Void
    ) {
        withProcessManager(pages: 192) { ram, _, manager in
            guard let process = try? manager.pointee.spawnProcess(),
                  let vma     = process.pointee.addressSpace.vmaManager,
                  let address = try? vma.pointee.mmapAnonymous(
                    size       : 4096,
                    permissions: [.read, .write, .user]
                  )
            else {
                Issue.record("could not build the dying process")
                return
            }

            Arch.CPU.setCurrentProcess(VirtualAddress(UInt(bitPattern: process)))
            #expect(vma.pointee.handlePageFault(
                at    : address,
                cause : .translation,
                access: .write
            ) == .handled)
            Arch.CPU.setCurrentProcess(0)

            mmu_trace_reset(nil)
            body(ram, manager, process)
        }
    }
}
}


/// What a window between two steps would find, reduced to the facts a stage
/// changes. `invalidated` is whether the dying tag has been retired.
struct Observation: Equatable {

    var regions    : UInt16
    var manager    : Bool
    var trapFrame  : Bool
    var invalidated: Bool

    init(of process: UnsafeMutablePointer<Process>, asid: ASID) {
        let vma = process.pointee.addressSpace.vmaManager

        regions     = vma?.pointee.registeredRegions ?? 0
        manager     = vma != nil
        trapFrame   = process.pointee.context != nil
        invalidated = mmuCalls().contains { $0.op == .tlbASID && $0.arg == UInt64(asid) }
    }

    func changed(from previous: Observation) -> [String] {
        var names: [String] = []
        if regions     != previous.regions     { names.append("regions") }
        if manager     != previous.manager     { names.append("manager") }
        if trapFrame   != previous.trapFrame   { names.append("trapFrame") }
        if invalidated != previous.invalidated { names.append("invalidated") }
        return names
    }

    static func log(of process: UnsafeMutablePointer<Process>, asid: ASID) -> ObservationLog {
        ObservationLog(last: Observation(of: process, asid: asid))
    }
}


/// The facts each step changed, one entry per step.
struct ObservationLog {

    var last   : Observation
    var changes: [[String]] = []

    mutating func record(_ next: Observation) {
        changes.append(next.changed(from: last))
        last = next
    }
}


/// Every `preemptSpan` record the teardown region filed, oldest first.
func teardownSpans() -> [TraceEvent] {
    var spans: [TraceEvent] = []

    TraceRing.forEachEvent { event in
        guard event.code == TraceCode.preemptSpan,
              event.info == UInt16(AddressSpaceTeardown.slot)
        else { return }

        spans.append(event)
    }

    return spans
}
