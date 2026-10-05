//
//  KernelRuntimeABITests.swift
//  ReixOS
//

import Testing
@testable import Kernel
import ReixABI
import KernelTestSupport

@Suite("Kernel runtime ABI", .serialized)
struct KernelRuntimeABITests {

    @Test("malloc and free preserve payloads, alignment, and heap lifetime")
    func allocationLifetime() {
        withRuntimeHeap(pages: 128) { ram, heap in
            let pagesBefore = ram.ppm.pointee.allocatedPages
            let sizes: [UInt] = [0, 1, 8, 15, 16, 17, 63, 64, 65, 4095, 4096, 4097, 8192]
            var allocations: [(pointer: UnsafeMutableRawPointer, size: UInt, pattern: UInt8)] = []

            for (index, size) in sizes.enumerated() {
                let pointer = reixKernelMalloc(size)
                #expect(pointer != nil)
                guard let pointer else { continue }

                #expect(UInt(bitPattern: pointer) & 15 == 0)
                let writable = max(size, 1)
                let pattern = UInt8(truncatingIfNeeded: index &* 17 &+ 1)
                pointer.initializeMemory(as: UInt8.self, repeating: pattern, count: Int(writable))
                allocations.append((pointer, writable, pattern))
            }

            let liveAddresses = Set(allocations.map { UInt(bitPattern: $0.pointer) })
            #expect(liveAddresses.count == allocations.count)
            for allocation in allocations {
                let payload = UnsafeRawBufferPointer(
                    start: allocation.pointer,
                    count: Int(allocation.size)
                )
                #expect(payload.allSatisfy { $0 == allocation.pattern })
            }

            reixKernelFree(nil)
            for allocation in allocations.reversed() { reixKernelFree(allocation.pointer) }

            #expect(ram.ppm.pointee.allocatedPages == pagesBefore)

            let recycled = reixKernelMalloc(64)
            #expect(recycled != nil)
            if let recycled { reixKernelFree(recycled) }
            #expect(ram.ppm.pointee.allocatedPages == pagesBefore)
            _ = heap
        }
    }


    @Test("impossible and exhausted allocations fail without retaining pages")
    func allocationFailures() {
        withRuntimeHeap(pages: 32) { ram, _ in
            let before = ram.ppm.pointee.allocatedPages

            #expect(reixKernelMalloc(UInt.max) == nil)
            #expect(ram.ppm.pointee.allocatedPages == before)

            // Larger than this fixture and larger than the buddy's maximum block.
            #expect(reixKernelMalloc(16 * 1024 * 1024) == nil)
            #expect(ram.ppm.pointee.allocatedPages == before)

            var exhausted: [UnsafeMutableRawPointer] = []
            var reachedOOM = false
            for _ in 0...32 {
                guard let pointer = reixKernelMalloc(8192) else {
                    reachedOOM = true
                    break
                }
                exhausted.append(pointer)
            }
            #expect(!exhausted.isEmpty)
            #expect(reachedOOM)

            var output = UnsafeMutableRawPointer(bitPattern: 0x1234)
            #expect(reixKernelPosixMemalign(&output, 4096, 4097) == 12)
            #expect(output == UnsafeMutableRawPointer(bitPattern: 0x1234))

            for pointer in exhausted { reixKernelFree(pointer) }
            #expect(ram.ppm.pointee.allocatedPages == before)

            let recovered = reixKernelMalloc(8192)
            #expect(recovered != nil)
            if let recovered { reixKernelFree(recovered) }
            #expect(ram.ppm.pointee.allocatedPages == before)

            output = UnsafeMutableRawPointer(bitPattern: 0x1234)
            #expect(reixKernelPosixMemalign(&output, UInt(1) << 63, 1) == 12)
            #expect(output == UnsafeMutableRawPointer(bitPattern: 0x1234))
            #expect(ram.ppm.pointee.allocatedPages == before)
        }
    }


    @Test("posix_memalign validates before publishing and returns free-compatible heads")
    func posixAlignment() {
        withRuntimeHeap(pages: 128) { ram, _ in
            let pagesBefore = ram.ppm.pointee.allocatedPages
            let sentinel = UnsafeMutableRawPointer(bitPattern: 0x5678)

            for invalid: UInt in [0, 1, 4, 12, 24, UInt.max] {
                var output = sentinel
                #expect(reixKernelPosixMemalign(&output, invalid, 37) == 22)
                #expect(output == sentinel)
            }

            for alignment: UInt in [8, 16, 32, 64, 256, 4096] {
                var output: UnsafeMutableRawPointer?
                #expect(reixKernelPosixMemalign(&output, alignment, 37) == 0)
                #expect(output != nil)
                guard let output else { continue }

                #expect(UInt(bitPattern: output) & (alignment - 1) == 0)
                output.storeBytes(of: UInt8(0xC3), as: UInt8.self)
                (output + 36).storeBytes(of: UInt8(0x3C), as: UInt8.self)
                #expect(output.load(as: UInt8.self) == 0xC3)
                #expect((output + 36).load(as: UInt8.self) == 0x3C)
                reixKernelFree(output)
            }

            var zeroSized: UnsafeMutableRawPointer?
            #expect(reixKernelPosixMemalign(&zeroSized, 64, 0) == 0)
            #expect(zeroSized != nil)
            if let zeroSized {
                #expect(UInt(bitPattern: zeroSized) & 63 == 0)
                reixKernelFree(zeroSized)
            }

            #expect(ram.ppm.pointee.allocatedPages == pagesBefore)
        }
    }


    @Test("absolute alignment failure releases the candidate block")
    func absoluteAlignmentFailure() {
        withShiftedRuntimeHeap(pages: 16) { ppm in
            let before = ppm.pointee.allocatedPages
            var output = UnsafeMutableRawPointer(bitPattern: 0x9ABC)

            // The arena begins 4 KiB past an 8 KiB boundary. The buddy's order-1
            // head is aligned relative to that base, not in the C address space.
            #expect(reixKernelPosixMemalign(&output, 8192, 1) == 12)
            #expect(output == UnsafeMutableRawPointer(bitPattern: 0x9ABC))
            #expect(ppm.pointee.allocatedPages == before)
        }
    }


    @Test("runtime calls before heap publication fail without dereferencing nil")
    func beforeHeapPublication() {
        withKernelTestGlobals {
            let saved: UnsafeMutablePointer<BucketsHeap>? = Kernel.heap
            Kernel.heap = nil
            defer { Kernel.heap = saved }

            #expect(reixKernelMalloc(16) == nil)
            reixKernelFree(nil)

            var output = UnsafeMutableRawPointer(bitPattern: 0xDEF0)
            #expect(reixKernelPosixMemalign(&output, 16, 16) == 12)
            #expect(output == UnsafeMutableRawPointer(bitPattern: 0xDEF0))
        }
    }


    @Test("the hashing compatibility seed is fixed, bounded, and explicitly reproducible")
    func deterministicHashSeed() {
        let expected = [UInt8](repeating: 0x42, count: 32)
        var first = [UInt8](repeating: 0xEE, count: expected.count + 2)
        var second = [UInt8](repeating: 0xDD, count: expected.count + 2)

        first.withUnsafeMutableBytes { bytes in
            reixKernelFillDeterministicHashSeed(bytes.baseAddress! + 1, UInt(expected.count))
        }
        second.withUnsafeMutableBytes { bytes in
            reixKernelFillDeterministicHashSeed(bytes.baseAddress! + 1, UInt(expected.count))
        }

        #expect(first.first == 0xEE)
        #expect(first.last == 0xEE)
        #expect(second.first == 0xDD)
        #expect(second.last == 0xDD)
        #expect(Array(first.dropFirst().dropLast()) == expected)
        #expect(Array(second.dropFirst().dropLast()) == expected)

        reixKernelFillDeterministicHashSeed(nil, 0)
    }


    private func withRuntimeHeap(
        pages: Int,
        _ body: (HostRAM, UnsafeMutablePointer<BucketsHeap>) -> Void
    ) {
        withKernelTestGlobals {
            withHostRAM(pages: pages) { ram in
                ram.installLiveManager()
                #expect(ram.donateAll())

                let savedOffset = PPMBackend.physicalOffset
                PPMBackend.physicalOffset = 0
                defer { PPMBackend.physicalOffset = savedOffset }

                var heap = BucketsHeap(ppmPtr: ram.ppm)
                withUnsafeMutablePointer(to: &heap) { heapPointer in
                    let savedHeap: UnsafeMutablePointer<BucketsHeap>? = Kernel.heap
                    Kernel.heap = heapPointer
                    defer { Kernel.heap = savedHeap }
                    body(ram, heapPointer)
                }
            }
        }
    }


    private func withShiftedRuntimeHeap(
        pages: Int,
        _ body: (UnsafeMutablePointer<KernelPPM>) -> Void
    ) {
        withKernelTestGlobals {
            let pageSize = 4096
            let storage = UnsafeMutableRawPointer.allocate(
                byteCount: pages * pageSize + pageSize,
                alignment: pageSize * 2
            )
            let arena = storage + pageSize
            arena.initializeMemory(as: UInt8.self, repeating: 0, count: pages * pageSize)
            #expect(UInt(bitPattern: arena) & UInt(pageSize * 2 - 1) == UInt(pageSize))

            let bitmap = UnsafeMutableRawPointer.allocate(
                byteCount: (pages + 7) / 8 + 8,
                alignment: 8
            )
            let freeLists = UnsafeMutableRawPointer.allocate(
                byteCount: 16 * MemoryLayout<LinkedList<FreeBlock>>.stride,
                alignment: MemoryLayout<LinkedList<FreeBlock>>.alignment
            )
            let framesRaw = UnsafeMutableRawPointer.allocate(
                byteCount: pages * MemoryLayout<FrameInfo>.stride,
                alignment: MemoryLayout<FrameInfo>.alignment
            )
            let frames = framesRaw.bindMemory(to: FrameInfo.self, capacity: pages)
            frames.initialize(repeating: FrameInfo(), count: pages)
            let ppm = allocateZeroedStorage(KernelPPM.self)

            defer {
                UnsafeMutableRawPointer(ppm).deallocate()
                UnsafeMutableRawPointer(frames).deallocate()
                freeLists.deallocate()
                bitmap.deallocate()
                storage.deallocate()
            }

            let base = PhysicalAddress(UInt(bitPattern: arena))
            let size = UInt64(pages * pageSize)
            let buddy = BuddyAllocator(
                start: base,
                size: size,
                bitmapAddress: PhysicalAddress(UInt(bitPattern: bitmap)),
                freeListsAddress: PhysicalAddress(UInt(bitPattern: freeLists))
            )
            #expect((try? buddy.addFreeRange(from: base, to: base + size)) != nil)
            ppm.pointee = KernelPPM(
                hostAllocator: buddy,
                ramStart: base,
                ramSize: size,
                framesMetadata: frames
            )

            let savedOffset = PPMBackend.physicalOffset
            PPMBackend.physicalOffset = 0
            defer { PPMBackend.physicalOffset = savedOffset }

            var heap = BucketsHeap(ppmPtr: ppm)
            withUnsafeMutablePointer(to: &heap) { heapPointer in
                let savedHeap: UnsafeMutablePointer<BucketsHeap>? = Kernel.heap
                Kernel.heap = heapPointer
                defer { Kernel.heap = savedHeap }
                body(ppm)
            }
        }
    }
}
