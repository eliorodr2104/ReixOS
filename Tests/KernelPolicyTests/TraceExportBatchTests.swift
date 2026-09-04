//
//  TraceExportBatchTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 04/08/2026.


import Testing
@testable import Kernel
import KernelHostShims

/// `TraceRing`, `TraceExport`'s attachment and the shim's barrier counter are
/// all global, and `.serialized` only orders this suite's own tests.
/// The run needs `swift test --no-parallel` (see the `test` target in the Makefile).
extension KernelPolicyTestRoot {
@Suite("Trace export batch publication", .serialized)
struct TraceExportBatchTests {
    @Test("zero records leave the tail unpublished")
    func zero() {
        let ring = UnsafeMutableRawPointer.allocate(byteCount: 160, alignment: 16)
        defer { ring.deallocate() }

        ring.initializeMemory(as: UInt8.self, repeating: 0, count: 160)
        ring.storeBytes(of: UInt32(9), toByteOffset: 0, as: UInt32.self)
        reset_page_table_barrier_count()

        var batch = TraceExportBatch(ring: ring, producer: 9, mask: 3)
        batch.publish()

        #expect(ring.load(fromByteOffset: 0, as: UInt32.self) == 9)
        #expect(page_table_barrier_count() == 0)
    }

    @Test("partial batch remains hidden until one final publication")
    func partial() {
        let ring = UnsafeMutableRawPointer.allocate(byteCount: 160, alignment: 16)
        defer { ring.deallocate() }

        ring.initializeMemory(as: UInt8.self, repeating: 0, count: 160)
        reset_page_table_barrier_count()

        var batch = TraceExportBatch(ring: ring, producer: 0, mask: 3)
        batch.append(TraceEvent(timestamp: 11, code: 12, info: 13, pid: 14, a: 15, b: 16))
        batch.append(TraceEvent(timestamp: 21, code: 22, info: 23, pid: 24, a: 25, b: 26))
        batch.append(TraceEvent(timestamp: 31, code: 32, info: 33, pid: 34, a: 35, b: 36))

        #expect(ring.load(fromByteOffset: 0, as: UInt32.self) == 0)
        #expect(page_table_barrier_count() == 0)
        #expect(ring.load(fromByteOffset: 16, as: UInt64.self) == 11)
        #expect(ring.load(fromByteOffset: 48, as: UInt64.self) == 21)
        #expect(ring.load(fromByteOffset: 80, as: UInt64.self) == 31)

        batch.publish()

        #expect(ring.load(fromByteOffset: 0, as: UInt32.self) == 3)
        #expect(page_table_barrier_count() == 1)
    }

    @Test("full batch uses one barrier")
    func full() {
        let ring = UnsafeMutableRawPointer.allocate(byteCount: 272, alignment: 16)
        defer { ring.deallocate() }

        ring.initializeMemory(as: UInt8.self, repeating: 0, count: 272)
        reset_page_table_barrier_count()

        var batch = TraceExportBatch(ring: ring, producer: 0, mask: 7)
        for value in UInt64(1)...8 {
            batch.append(TraceEvent(timestamp: value))
        }
        batch.publish()

        #expect(ring.load(fromByteOffset: 0, as: UInt32.self) == 8)
        #expect(page_table_barrier_count() == 1)
    }

    @Test("batch wraps slots and producer without early publication")
    func wrap() {
        let ring = UnsafeMutableRawPointer.allocate(byteCount: 144, alignment: 16)
        defer { ring.deallocate() }

        ring.initializeMemory(as: UInt8.self, repeating: 0, count: 144)
        ring.storeBytes(of: UInt32.max - 1, toByteOffset: 0, as: UInt32.self)
        reset_page_table_barrier_count()

        var batch = TraceExportBatch(ring: ring, producer: UInt32.max - 1, mask: 3)
        batch.append(TraceEvent(timestamp: 41))
        batch.append(TraceEvent(timestamp: 42))
        batch.append(TraceEvent(timestamp: 43))

        #expect(ring.load(fromByteOffset: 0, as: UInt32.self) == UInt32.max - 1)
        #expect(ring.load(fromByteOffset: 80, as: UInt64.self) == 41)
        #expect(ring.load(fromByteOffset: 112, as: UInt64.self) == 42)
        #expect(ring.load(fromByteOffset: 16, as: UInt64.self) == 43)

        batch.publish()

        #expect(ring.load(fromByteOffset: 0, as: UInt32.self) == 1)
        #expect(page_table_barrier_count() == 1)
    }

    @Test("full export ring reports TraceRing eviction with zero copy budget")
    func fullRingDropped() {
        withAttachedExport { base in
            let ring = base + Int(UserSpaceLayout.pageSize)

            reset_page_table_barrier_count()
            for batch in 0..<8 {
                for index in 0..<8 {
                    TraceRing.append(TraceEvent(timestamp: UInt64(batch * 8 + index + 1)))
                }
                TraceExport.pump()
            }

            #expect(ring.load(fromByteOffset: 0, as: UInt32.self) == 64)
            #expect(page_table_barrier_count() == 8)

            for index in 0...Int(TraceRing.capacity) {
                TraceRing.append(TraceEvent(timestamp: UInt64(1000 + index)))
            }

            reset_page_table_barrier_count()
            TraceExport.pump()

            #expect(ring.load(fromByteOffset: 0, as: UInt32.self) == 64)
            #expect(ring.load(fromByteOffset: 8, as: UInt64.self) == 1)
            #expect(page_table_barrier_count() == 0)
        }
    }

    private func withAttachedExport(_ body: (UnsafeMutableRawPointer) -> Void) {
        TraceRing.reset()

        let base = UnsafeMutableRawPointer.allocate(byteCount: 8192, alignment: 4096)
        let schedulerStorage = UnsafeMutableRawPointer.allocate(
            byteCount: MemoryLayout<KernelScheduler>.stride,
            alignment: MemoryLayout<KernelScheduler>.alignment
        )
        let ppmStorage = UnsafeMutableRawPointer.allocate(
            byteCount: MemoryLayout<KernelPPM>.stride,
            alignment: MemoryLayout<KernelPPM>.alignment
        )
        let heapStorage = UnsafeMutableRawPointer.allocate(
            byteCount: MemoryLayout<KernelHeap>.stride,
            alignment: MemoryLayout<KernelHeap>.alignment
        )
        let managerStorage = UnsafeMutableRawPointer.allocate(
            byteCount: MemoryLayout<ProcessManager>.stride,
            alignment: MemoryLayout<ProcessManager>.alignment
        )
        let backing = UnsafeMutablePointer<SharedRegion>.allocate(capacity: 1)

        base.initializeMemory(as: UInt8.self, repeating: 0, count: 8192)
        schedulerStorage.initializeMemory(
            as: UInt8.self,
            repeating: 0,
            count: MemoryLayout<KernelScheduler>.stride
        )
        ppmStorage.initializeMemory(as: UInt8.self, repeating: 0, count: MemoryLayout<KernelPPM>.stride)
        heapStorage.initializeMemory(as: UInt8.self, repeating: 0, count: MemoryLayout<KernelHeap>.stride)
        managerStorage.initializeMemory(
            as: UInt8.self,
            repeating: 0,
            count: MemoryLayout<ProcessManager>.stride
        )

        let scheduler = schedulerStorage.bindMemory(to: KernelScheduler.self, capacity: 1)
        let ppm = ppmStorage.bindMemory(to: KernelPPM.self, capacity: 1)
        let heap = heapStorage.bindMemory(to: KernelHeap.self, capacity: 1)
        let manager = managerStorage.bindMemory(to: ProcessManager.self, capacity: 1)

        backing.initialize(to: SharedRegion(
            physicalPage: PhysicalPage(),
            references: 1,
            pageCount: 2
        ))

        #expect(TraceExport.attach(
            base: base,
            backing: backing,
            pageCount: 2,
            scheduler: scheduler,
            ppm: ppm,
            heap: heap,
            processManager: manager
        ))

        body(base)

        TraceExport.detach(pid: 0)
        TraceRing.reset()

        backing.deinitialize(count: 1)
        backing.deallocate()
        managerStorage.deallocate()
        heapStorage.deallocate()
        ppmStorage.deallocate()
        schedulerStorage.deallocate()
        base.deallocate()
    }
}


}
