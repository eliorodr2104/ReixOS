// Host-only probe injected into KernelUnitTests by scripts/benchmark-slab-heap.py.
// Every workload drains the heap back to zero reserved pages before it returns,
// so every sample starts from the same state and times the same work.

import Dispatch
import Foundation
import Testing
@testable import Kernel
import ReixABI
import KernelTestSupport

@Suite("Slab heap benchmark", .serialized)
struct SlabHeapBenchmark {
    private static let pageSize = 4096

    @Test("kernel slab heap cost per workload at 4 MiB and 32 MiB")
    func workloads() {
        let environment = ProcessInfo.processInfo.environment
        let samples = Int(environment["REIX_SLAB_BENCH_SAMPLES"] ?? "10")!
        precondition(samples >= 4)

        var rows: [String] = []
        var checksum: UInt64 = 0

        func row(
            _ name   : String,
            _ size   : Int,
            _ ram    : Int,
            _ ops    : Int,
            _ elapsed: [UInt64],
            held     : Int,
            after    : Int
        ) {
            rows.append(
                "{\"workload\":\"\(name)\",\"size\":\(size),\"ram_pages\":\(ram),"
                + "\"ops\":\(ops),\"elapsed_ns\":\(elapsed),"
                + "\"held_pages\":\(held),\"after_pages\":\(after)}"
            )
        }

        for ramPages in [1024, 8192] {
            withBenchmarkHeap(pages: ramPages) { heap in
                // Per size class: a run of allocations as long as 128 pages of
                // the class, then the same blocks freed in allocation order.
                if ramPages == 1024 {
                    for shift in 3...12 {
                        let size  = 1 << shift
                        let count = 128 * Self.blocksPerPage(size)
                        var alloc: [UInt64] = []
                        var free : [UInt64] = []
                        var held = 0
                        for _ in 0..<samples {
                            let (a, f, peak, sum) = allocThenFree(&heap, size: size, count: count)
                            alloc.append(a)
                            free.append(f)
                            held = peak
                            checksum &+= sum
                        }
                        row("class-alloc", size, ramPages, count, alloc, held: held, after: Self.pages(heap))
                        row("class-free", size, ramPages, count, free, held: held, after: Self.pages(heap))
                    }
                }

                for size in [64, 512] {
                    var elapsed: [UInt64] = []
                    var ops = 0
                    var held = 0
                    for _ in 0..<samples {
                        let (count, nanos, after, sum) = fragmentation(&heap, size: size, pages: 128)
                        elapsed.append(nanos)
                        ops = count
                        held = after
                        checksum &+= sum
                    }
                    row("fragment-reuse", size, ramPages, ops, elapsed, held: held, after: Self.pages(heap))
                }

                // Pages empty one after another only at the very end, while the
                // class still has every other page's free blocks outstanding.
                let drainPages = ramPages == 1024 ? 128 : 512
                for size in [8, 256] {
                    var alloc: [UInt64] = []
                    var drain: [UInt64] = []
                    var count = 0
                    var held = 0
                    for _ in 0..<samples {
                        let (n, a, d, peak, sum) = peakThenDrain(&heap, size: size, pages: drainPages)
                        alloc.append(a)
                        drain.append(d)
                        count = n
                        held = peak
                        checksum &+= sum
                    }
                    row("peak-alloc", size, ramPages, count, alloc, held: held, after: Self.pages(heap))
                    row("peak-drain", size, ramPages, count, drain, held: held, after: Self.pages(heap))
                }

                if ramPages == 1024 {
                    var fill   : [UInt64] = []
                    var refuse : [UInt64] = []
                    var count = 0
                    var held = 0
                    for _ in 0..<samples {
                        let (n, f, r, peak, sum) = exhaust(&heap, size: 64, refusals: 1024)
                        fill.append(f)
                        refuse.append(r)
                        count = n
                        held = peak
                        checksum &+= sum
                    }
                    row("oom-fill", 64, ramPages, count, fill, held: held, after: Self.pages(heap))
                    row("oom-refusal", 64, ramPages, 1024, refuse, held: held, after: Self.pages(heap))
                }
            }
        }

        print("SLAB_BENCHMARK_JSON "
            + "{\"samples\":\(samples),"
            + "\"frame_info_stride\":\(MemoryLayout<FrameInfo>.stride),"
            + "\"rows\":[\(rows.joined(separator: ","))],\"checksum\":\(checksum)}")
    }


    private static func blocksPerPage(_ size: Int) -> Int {
        let reserved = SlabCore<PPMBackend>.reservedBlockCount(
            forShift: UInt8(size.trailingZeroBitCount)
        )
        return pageSize / size - reserved
    }


    private static func pages(_ heap: BucketsHeap) -> Int {
        Int(heap.metricsReservedBytes) / pageSize
    }


    private func allocThenFree(
        _ heap: inout BucketsHeap,
        size  : Int,
        count : Int
    ) -> (UInt64, UInt64, Int, UInt64) {
        var held: [UnsafeMutableRawPointer] = []
        held.reserveCapacity(count)
        var sum: UInt64 = 0

        let t0 = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<count { held.append(heap.kmallocOrNil(UInt(size))!) }
        let t1 = DispatchTime.now().uptimeNanoseconds
        let peak = Self.pages(heap)
        for pointer in held { heap.kfree(pointer) }
        let t2 = DispatchTime.now().uptimeNanoseconds

        precondition(heap.metricsReservedBytes == 0)
        for pointer in held { sum &+= UInt64(UInt(bitPattern: pointer)) }
        return (t1 - t0, t2 - t1, peak, sum)
    }


    /// Fills `pages` pages of the class, frees every other block, then takes as
    /// many back. Timed as one run of all three phases; `held` is the backing
    /// left once the holes are refilled, which is the fragmentation figure.
    private func fragmentation(
        _ heap: inout BucketsHeap,
        size  : Int,
        pages : Int
    ) -> (Int, UInt64, Int, UInt64) {
        let count = pages * Self.blocksPerPage(size)
        var held: [UnsafeMutableRawPointer] = []
        held.reserveCapacity(count)
        var sum: UInt64 = 0

        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<count { held.append(heap.kmallocOrNil(UInt(size))!) }
        for index in stride(from: 0, to: count, by: 2) { heap.kfree(held[index]) }
        for index in stride(from: 0, to: count, by: 2) { held[index] = heap.kmallocOrNil(UInt(size))! }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start

        let after = Self.pages(heap)
        for pointer in held {
            sum &+= UInt64(UInt(bitPattern: pointer))
            heap.kfree(pointer)
        }
        precondition(heap.metricsReservedBytes == 0)
        return (count + count, elapsed, after, sum)
    }


    /// Fills `pages` pages, then frees block `slot` of every page before slot
    /// `slot + 1` of any: no page empties until the last round, and by then the
    /// class holds every other page's free blocks.
    private func peakThenDrain(
        _ heap: inout BucketsHeap,
        size  : Int,
        pages : Int
    ) -> (Int, UInt64, UInt64, Int, UInt64) {
        let perPage = Self.blocksPerPage(size)
        let count = pages * perPage
        var held: [UnsafeMutableRawPointer] = []
        held.reserveCapacity(count)
        var sum: UInt64 = 0

        let t0 = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<count { held.append(heap.kmallocOrNil(UInt(size))!) }
        let t1 = DispatchTime.now().uptimeNanoseconds
        let peak = Self.pages(heap)

        held.sort { UInt(bitPattern: $0) < UInt(bitPattern: $1) }
        var order: [UnsafeMutableRawPointer] = []
        order.reserveCapacity(count)
        for slot in 0..<perPage {
            for page in 0..<pages { order.append(held[page * perPage + slot]) }
        }

        let t2 = DispatchTime.now().uptimeNanoseconds
        for pointer in order { heap.kfree(pointer) }
        let t3 = DispatchTime.now().uptimeNanoseconds

        precondition(heap.metricsReservedBytes == 0)
        for pointer in held { sum &+= UInt64(UInt(bitPattern: pointer)) }
        return (count, t1 - t0, t3 - t2, peak, sum)
    }


    /// Allocates until the arena runs out, times `refusals` further requests
    /// that must all fail, then drains and proves the heap serves again.
    private func exhaust(
        _ heap  : inout BucketsHeap,
        size    : Int,
        refusals: Int
    ) -> (Int, UInt64, UInt64, Int, UInt64) {
        var held: [UnsafeMutableRawPointer] = []
        var sum: UInt64 = 0

        let t0 = DispatchTime.now().uptimeNanoseconds
        while let pointer = heap.kmallocOrNil(UInt(size)) { held.append(pointer) }
        let t1 = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<refusals { precondition(heap.kmallocOrNil(UInt(size)) == nil) }
        let t2 = DispatchTime.now().uptimeNanoseconds

        let peak = Self.pages(heap)
        for pointer in held {
            sum &+= UInt64(UInt(bitPattern: pointer))
            heap.kfree(pointer)
        }
        precondition(heap.metricsReservedBytes == 0)

        let again = heap.kmallocOrNil(UInt(size))!
        heap.kfree(again)
        return (held.count, t1 - t0, t2 - t1, peak, sum)
    }


    /// A real `BucketsHeap` over `PPMBackend` over a live manager on a host
    /// arena, set up the way `BucketsHeapTests` does, with no progress reserve so
    /// the OOM workload can drain it.
    private func withBenchmarkHeap(
        pages : Int,
        _ body: (inout BucketsHeap) -> Void
    ) {
        withHostRAM(pages: pages) { ram in
            ram.installLiveManager(reservePages: 0)
            precondition(ram.donateAll())

            let saved = PPMBackend.physicalOffset
            PPMBackend.physicalOffset = 0
            defer { PPMBackend.physicalOffset = saved }

            var heap = BucketsHeap(ppmPtr: ram.ppm)
            body(&heap)
        }
    }
}
