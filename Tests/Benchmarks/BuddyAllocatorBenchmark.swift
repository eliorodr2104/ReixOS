// Host-only probe injected into KernelUnitTests by
// scripts/benchmark-buddy-allocator.py. Each workload leaves the allocator in
// the state it found it in, so every sample times the same work.

import Dispatch
import Foundation
import Testing
@testable import Kernel
import KernelTestSupport

@Suite("Buddy allocator benchmark", .serialized)
struct BuddyAllocatorBenchmark {
    private static let pageSize = 4096

    @Test("buddy cost per workload at 4 MiB and 128 MiB")
    func workloads() {
        let environment = ProcessInfo.processInfo.environment
        let samples = Int(environment["REIX_BUDDY_BENCH_SAMPLES"] ?? "10")!
        precondition(samples >= 4)

        var rows: [String] = []
        var checksum: UInt64 = 0

        func row(_ name: String, _ pages: Int, _ ops: Int, _ elapsed: [UInt64]) {
            rows.append(
                "{\"workload\":\"\(name)\",\"pages\":\(pages),"
                + "\"ops\":\(ops),\"elapsed_ns\":\(elapsed)}"
            )
        }

        for pages in [1024, 32768] {
            withHostRAM(pages: pages) { ram in
                precondition(ram.donateAll())
                let buddy    = ram.buddy
                let maxBytes = Self.largestBlock(pages: pages)

                // Warm the arena once so first-touch page faults stay out of the samples.
                _ = saturateAndDrain(buddy, pages: pages)

                var mixed: [UInt64] = []
                var mixedOps = 0
                for _ in 0..<samples {
                    let (ops, nanos, sum) = mixedOrders(buddy)
                    mixed.append(nanos)
                    mixedOps = ops
                    checksum &+= sum
                }
                row("mixed-orders", pages, mixedOps, mixed)

                var saturate: [UInt64] = []
                for _ in 0..<samples { saturate.append(saturateAndDrain(buddy, pages: pages)) }
                row("saturate-drain", pages, 2 * pages, saturate)

                var fragment: [UInt64] = []
                var coalesce: [UInt64] = []
                for _ in 0..<samples {
                    let (checker, merge) = checkerboard(buddy, pages: pages)
                    fragment.append(checker)
                    coalesce.append(merge)
                    precondition(fullyCoalesced(buddy, maxBytes: maxBytes))
                }
                row("checkerboard", pages, pages + pages / 2, fragment)
                row("coalesce-back", pages, pages / 2, coalesce)

                var maxAlloc: [UInt64] = []
                var maxFree : [UInt64] = []
                var depth   : [UInt64] = []
                let pairs = 256
                for _ in 0..<samples {
                    var allocNanos: UInt64 = 0
                    var freeNanos : UInt64 = 0
                    for _ in 0..<pairs {
                        let t0   = DispatchTime.now().uptimeNanoseconds
                        let page = try! buddy.alloc(maxBytes)
                        let t1   = DispatchTime.now().uptimeNanoseconds
                        let address = page.address
                        let order   = page.order
                        try! buddy.free(page)
                        let t2   = DispatchTime.now().uptimeNanoseconds
                        allocNanos += t1 - t0
                        freeNanos  += t2 - t1
                        checksum &+= address &+ UInt64(order)
                    }
                    maxAlloc.append(allocNanos)
                    maxFree.append(freeNanos)

                    let start = DispatchTime.now().uptimeNanoseconds
                    for _ in 0..<pairs {
                        let page = try! buddy.alloc(Self.pageSize)
                        checksum &+= page.address
                        try! buddy.free(page)
                    }
                    depth.append(DispatchTime.now().uptimeNanoseconds - start)
                }
                row("max-order-alloc", pages, pairs, maxAlloc)
                row("max-order-free", pages, pairs, maxFree)
                row("split-merge-full-depth", pages, 2 * pairs, depth)
            }

            // A second arena, never touched through `ram.buddy`: each sample
            // builds a fresh allocator over it, which is what boot does once.
            withHostRAM(pages: pages) { ram in
                let bitmap = UnsafeMutableRawPointer.allocate(byteCount: pages / 8 + 64, alignment: 8)
                let lists  = UnsafeMutableRawPointer.allocate(byteCount: 1024, alignment: 16)
                defer { bitmap.deallocate(); lists.deallocate() }

                for (name, from) in [("boot-add-whole-ram", ram.base), ("boot-add-after-kernel", ram.page(67))] {
                    var initNanos: [UInt64] = []
                    var addNanos : [UInt64] = []
                    for _ in 0..<samples {
                        let t0 = DispatchTime.now().uptimeNanoseconds
                        let buddy = BuddyAllocator(
                            start           : ram.base,
                            size            : ram.size,
                            bitmapAddress   : PhysicalAddress(UInt(bitPattern: bitmap)),
                            freeListsAddress: PhysicalAddress(UInt(bitPattern: lists))
                        )
                        let t1 = DispatchTime.now().uptimeNanoseconds
                        try! buddy.addFreeRange(from: from, to: ram.end)
                        let t2 = DispatchTime.now().uptimeNanoseconds
                        initNanos.append(t1 - t0)
                        addNanos.append(t2 - t1)
                    }
                    row(name + "-init", pages, 1, initNanos)
                    row(name, pages, 1, addNanos)
                }
            }
        }

        print("BUDDY_BENCHMARK_JSON "
            + "{\"samples\":\(samples),\"free_lists_bytes\":\(BuddyAllocator.freeListsBytes),"
            + "\"free_block_stride\":\(MemoryLayout<FreeBlock>.stride),"
            + "\"frame_info_stride\":\(MemoryLayout<FrameInfo>.stride),"
            + "\"rows\":[\(rows.joined(separator: ","))],\"checksum\":\(checksum)}")
    }


    private static func largestBlock(pages: Int) -> Int {
        var bytes = pageSize
        while bytes * 2 <= pages * pageSize, bytes < pageSize << 11 { bytes *= 2 }
        return bytes
    }


    /// A fixed-seed stream of orders 0...4, at most 64 blocks live, then a drain.
    private func mixedOrders(_ buddy: BuddyAllocator) -> (Int, UInt64, UInt64) {
        var rng  = SplitMix64(seed: 0xB0DD_1E5)
        var live : [(PhysicalAddress, UInt8)] = []
        var ops  = 0
        var sum  : UInt64 = 0
        live.reserveCapacity(64)

        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<4096 {
            if live.isEmpty || (live.count < 64 && rng.below(2) == 0) {
                let page = try! buddy.alloc(Self.pageSize << rng.below(5))
                live.append((page.address, page.order))
                sum &+= page.address
            } else {
                let (address, order) = live.remove(at: rng.below(live.count))
                try! buddy.free(PhysicalPage(address: address, order: order))
            }
            ops += 1
        }
        for (address, order) in live {
            try! buddy.free(PhysicalPage(address: address, order: order))
            ops += 1
        }
        return (ops, DispatchTime.now().uptimeNanoseconds - start, sum)
    }


    private func saturateAndDrain(_ buddy: BuddyAllocator, pages: Int) -> UInt64 {
        var held: [PhysicalAddress] = []
        held.reserveCapacity(pages)

        let start = DispatchTime.now().uptimeNanoseconds
        while let page = try? buddy.alloc(Self.pageSize) { held.append(page.address) }
        for address in held { try! buddy.free(PhysicalPage(address: address, order: 0)) }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start

        precondition(held.count == pages)
        return elapsed
    }


    /// Every page taken, the even ones freed, then the odd ones: the second
    /// phase is the coalescing one, every free merging as far as it can.
    private func checkerboard(_ buddy: BuddyAllocator, pages: Int) -> (UInt64, UInt64) {
        var held: [PhysicalAddress] = []
        held.reserveCapacity(pages)

        let start = DispatchTime.now().uptimeNanoseconds
        while let page = try? buddy.alloc(Self.pageSize) { held.append(page.address) }
        held.sort()
        for index in stride(from: 0, to: held.count, by: 2) {
            try! buddy.free(PhysicalPage(address: held[index], order: 0))
        }
        let middle = DispatchTime.now().uptimeNanoseconds
        for index in stride(from: 1, to: held.count, by: 2) {
            try! buddy.free(PhysicalPage(address: held[index], order: 0))
        }
        let end = DispatchTime.now().uptimeNanoseconds

        precondition(held.count == pages)
        return (middle - start, end - middle)
    }


    private func fullyCoalesced(_ buddy: BuddyAllocator, maxBytes: Int) -> Bool {
        guard let page = try? buddy.alloc(maxBytes) else { return false }
        return (try? buddy.free(page)) != nil
    }
}
