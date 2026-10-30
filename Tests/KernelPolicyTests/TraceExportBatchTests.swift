//
//  TraceExportBatchTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 04/08/2026.


import Testing
@testable import Kernel
import KernelHostShims
import KernelTestSupport

/// `TraceRing`, `TraceExport`'s attachment and the shim's barrier counter are
/// all global, and `.serialized` only orders this suite's own tests.
/// The run needs `swift test --no-parallel` (see the `test` target in the Makefile).
extension KernelPolicyTestRoot {
@Suite("Trace export batch publication", .serialized)
struct TraceExportBatchTests {
    @Test("zero records leave the tail unpublished")
    func zero() {
        withRing { ring, region in
            ring.storeBytes(of: UInt32(9), toByteOffset: 0, as: UInt32.self)
            reset_page_table_barrier_count()

            var batch = TraceExportBatch(ring: ring, region: region, linearOffset: 0, producer: 9, mask: 3)
            batch.publish()

            #expect(ring.load(fromByteOffset: 0, as: UInt32.self) == 9)
            #expect(page_table_barrier_count() == 0)
        }
    }

    @Test("partial batch remains hidden until one final publication")
    func partial() {
        withRing { ring, region in
            reset_page_table_barrier_count()

            var batch = TraceExportBatch(ring: ring, region: region, linearOffset: 0, producer: 0, mask: 3)
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
    }

    @Test("full batch uses one barrier")
    func full() {
        withRing { ring, region in
            reset_page_table_barrier_count()

            var batch = TraceExportBatch(ring: ring, region: region, linearOffset: 0, producer: 0, mask: 7)
            for value in UInt64(1)...8 {
                batch.append(TraceEvent(timestamp: value))
            }
            batch.publish()

            #expect(ring.load(fromByteOffset: 0, as: UInt32.self) == 8)
            #expect(page_table_barrier_count() == 1)
        }
    }

    @Test("batch wraps slots and producer without early publication")
    func wrap() {
        withRing { ring, region in
            ring.storeBytes(of: UInt32.max - 1, toByteOffset: 0, as: UInt32.self)
            reset_page_table_barrier_count()

            var batch = TraceExportBatch(
                ring: ring, region: region, linearOffset: 0, producer: UInt32.max - 1, mask: 3
            )
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

    @Test("a record that straddles two scattered pages lands half in each")
    func straddleAcrossScatteredPages() {
        withScatteredRegion { _, _, region in
            let ring   = TraceExport.linearPage(1, of: region, linearOffset: 0)
            let second = TraceExport.linearPage(2, of: region, linearOffset: 0)

            // What sits right after page 1 in physical memory is somebody
            // else's frame, and must not be written.
            let neighbour = ring + 4096
            let untouched = Array(UnsafeRawBufferPointer(start: neighbour, count: 32))

            // Slot 127 starts at byte 4080 of a two-page ring.
            var batch = TraceExportBatch(
                ring: ring, region: region, linearOffset: 0, producer: 127, mask: 127
            )
            batch.append(TraceEvent(timestamp: 71, code: 72, info: 73, pid: 74, a: 75, b: 76))
            batch.publish()

            #expect(ring.load(fromByteOffset: 4080, as: UInt64.self) == 71)
            #expect(ring.load(fromByteOffset: 4088, as: UInt16.self) == 72)
            #expect(ring.load(fromByteOffset: 4090, as: UInt16.self) == 73)
            #expect(ring.load(fromByteOffset: 4092, as: UInt32.self) == 74)
            #expect(second.load(fromByteOffset: 0, as: UInt64.self) == 75)
            #expect(second.load(fromByteOffset: 8, as: UInt64.self) == 76)
            #expect(ring.load(fromByteOffset: 0, as: UInt32.self) == 128)

            #expect(Array(UnsafeRawBufferPointer(start: neighbour, count: 32)) == untouched)
        }
    }


    @Test("an export attached to a scattered region fills its whole ring")
    func pumpIntoScatteredRegion() {
        withScatteredRegion { ram, heap, region in
            let manager = allocateZeroedStorage(ProcessManager.self)
            defer { UnsafeMutableRawPointer(manager).deallocate() }

            TraceRing.reset()
            defer { TraceRing.reset() }

            #expect(TraceExport.attach(
                backing: region,
                linearOffset: 0,
                ppm: ram.ppm,
                heap: heap,
                processManager: manager
            ))
            defer { TraceExport.detach(pid: 0) }

            let ring   = TraceExport.linearPage(1, of: region, linearOffset: 0)
            let second = TraceExport.linearPage(2, of: region, linearOffset: 0)

            // 8160 bytes of records hold 255, and the capacity is 128 of them.
            for round in 0..<8 {
                for index in 0..<16 {
                    let value = UInt64(round * 16 + index)
                    TraceRing.append(TraceEvent(timestamp: value, a: 1000 + value, b: 2000 + value))
                }
                TraceExport.pump()
            }

            #expect(ring.load(fromByteOffset: 0, as: UInt32.self) == 128)

            // The record in slot 127 straddles the page boundary.
            #expect(ring.load(fromByteOffset: 4080, as: UInt64.self) == 127)
            #expect(second.load(fromByteOffset: 0, as: UInt64.self) == 1127)
            #expect(second.load(fromByteOffset: 8, as: UInt64.self) == 2127)

            // And slot 126, the last that does not.
            #expect(ring.load(fromByteOffset: 4048, as: UInt64.self) == 126)
            #expect(ring.load(fromByteOffset: 4064, as: UInt64.self) == 1126)
        }
    }


    /// A three-page region whose pages are three single frames, none next to
    /// another, out of an arena left with no free block larger than a frame.
    private func withScatteredRegion(
        _ body: (HostRAM, UnsafeMutablePointer<KernelHeap>, UnsafeMutablePointer<SharedRegion>) -> Void
    ) {
        withProcessManager(pages: 64) { ram, heap, _ in
            ram.checkerboard()
            let baseline = ram.ppm.pointee.allocatedPages

            let region = UnsafeMutablePointer<SharedRegion>.allocate(capacity: 1)
            region.initialize(to: SharedRegion(references: 1, pageCount: 3))
            defer { region.deallocate() }

            do { try region.pointee.allocateFrames(ppm: ram.ppm, heap: heap) }
            catch { Issue.record("could not allocate the region: \(error)"); return }

            #expect(region.pointee.extentCount == 3)
            for page in UInt32(0)..<3 {
                let address = region.pointee.physicalAddress(ofPage: page)
                for other in UInt32(0)..<3 where other != page {
                    let distance = Int64(bitPattern: address &- region.pointee.physicalAddress(ofPage: other))
                    #expect(distance.magnitude > 4096)
                }
            }

            body(ram, heap, region)

            #expect(region.move().releaseFrames(ppm: ram.ppm, heap: heap) == nil)
            #expect(ram.ppm.pointee.allocatedPages == baseline)
        }
    }


    /// A two-page region over host memory, one block, with the ring on page 1.
    private func withRing(
        _ body: (UnsafeMutableRawPointer, UnsafeMutablePointer<SharedRegion>) -> Void
    ) {
        let base = UnsafeMutableRawPointer.allocate(byteCount: 8192, alignment: 4096)
        defer { base.deallocate() }

        base.initializeMemory(as: UInt8.self, repeating: 0, count: 8192)

        let region = UnsafeMutablePointer<SharedRegion>.allocate(capacity: 1)
        region.initialize(to: SharedRegion(
            physicalPage: PhysicalPage(address: PhysicalAddress(UInt(bitPattern: base)), order: 1),
            references: 1,
            pageCount: 2
        ))
        defer { region.deinitialize(count: 1); region.deallocate() }

        body(base + 4096, region)
    }


    private func withAttachedExport(_ body: (UnsafeMutableRawPointer) -> Void) {
        TraceRing.reset()

        let base = UnsafeMutableRawPointer.allocate(byteCount: 8192, alignment: 4096)
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
        ppmStorage.initializeMemory(as: UInt8.self, repeating: 0, count: MemoryLayout<KernelPPM>.stride)
        heapStorage.initializeMemory(as: UInt8.self, repeating: 0, count: MemoryLayout<KernelHeap>.stride)
        managerStorage.initializeMemory(
            as: UInt8.self,
            repeating: 0,
            count: MemoryLayout<ProcessManager>.stride
        )

        let ppm = ppmStorage.bindMemory(to: KernelPPM.self, capacity: 1)
        let heap = heapStorage.bindMemory(to: KernelHeap.self, capacity: 1)
        let manager = managerStorage.bindMemory(to: ProcessManager.self, capacity: 1)

        // The host has no linear map: an arena address is its own pointer.
        backing.initialize(to: SharedRegion(
            physicalPage: PhysicalPage(address: PhysicalAddress(UInt(bitPattern: base)), order: 1),
            references: 1,
            pageCount: 2
        ))

        #expect(TraceExport.attach(
            backing: backing,
            linearOffset: 0,
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
        base.deallocate()
    }
}


}
