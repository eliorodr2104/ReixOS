//
//  ProcessPreparationTests.swift
//  ReixOS
//

import Testing
@testable import Kernel
import ReixABI
import KernelTestSupport
import KernelHostShims

extension KernelPolicyTestRoot {
@Suite("Private process preparation", .serialized)
struct ProcessPreparationTests {

    @Test("creation opens windows between complete private allocations")
    func creationCheckpoints() {
        withProcessManager(pages: 64) { _, _, manager in
            let mask = Trace.runtimeMask
            Trace.runtimeMask = 0x3F
            TraceRing.reset()
            host_set_counter_frequency(0)
            defer { Trace.runtimeMask = mask; TraceRing.reset() }

            guard let child = try? manager.pointee.spawnProcess() else {
                Issue.record("the fresh process was refused")
                return
            }
            if case .new = child.pointee.status {} else { Issue.record("the process was published runnable") }
            #expect(child.pointee.metadata.pointee.capsTable.hasFreeSlots(UInt(CapsTable.slotCount)))
            #expect(child.pointee.addressSpace.vmaManager != nil)
            #expect(child.pointee.context?.pointee.elr == 0)

            var checkpoints: UInt64 = 0
            TraceRing.forEachEvent { event in
                if event.code == TraceCode.preemptSpan, event.info == 7 {
                    checkpoints += event.b
                }
            }
            #expect(checkpoints == 4)
        }
    }

    @Test("each private allocation leaves a complete prefix and publishes no process")
    func completeSteps() {
        withProcessManager(pages: 64) { ram, heap, _ in
            var resources = ProcessPreparation.Resources()
            withUnsafeMutablePointer(to: &resources) { storage in
                var work = ProcessPreparation(
                    heap: heap, vmm: ram.vmm, ppm: ram.ppm, resources: storage,
                    frameLimit: 17, makeContext: true
                )
                #expect((try? work.step()) == .more)
                #expect(storage.pointee.metadata?.pointee.budget.pointee.limit == 17)
                #expect(storage.pointee.addressSpace == nil && storage.pointee.context == nil)
                #expect((try? work.step()) == .more)
                #expect(storage.pointee.addressSpace != nil)
                #expect(storage.pointee.addressSpace?.vmaManager == nil)
                #expect((try? work.step()) == .more)
                #expect(storage.pointee.addressSpace?.vmaManager != nil)
                #expect(storage.pointee.context == nil)
                #expect((try? work.step()) == .more)
                #expect(storage.pointee.context?.pointee.spel0 == UserSpaceLayout.stackTop)
                #expect((try? work.step()) == .done)
                #expect((try? work.step()) == .done)
            }
        }
    }

    @Test("every refused private allocation and the final record unwind all resources")
    func allocationRefusals() {
        for refusal in 0...4 {
            withProcessManager(pages: 64) { ram, heap, manager in
                let live = heap.pointee.metricsLiveBytes
                let pages = ram.ppm.pointee.allocatedPages
                KernelHeap.failAllocationsAfter = refusal
                defer { KernelHeap.failAllocationsAfter = nil }
                #expect((try? manager.pointee.spawnProcess()) == nil)
                KernelHeap.failAllocationsAfter = nil
                #expect(heap.pointee.metricsLiveBytes == live)
                #expect(ram.ppm.pointee.allocatedPages == pages)
                guard let child = try? manager.pointee.spawnProcess() else {
                    Issue.record("a refused creation left the next one unable to finish")
                    return
                }
                #expect(child.pointee.addressSpace.asid == 1)
            }
        }
    }
}
}
