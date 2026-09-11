// Host-only scaling probe injected into KernelUnitTests by
// scripts/benchmark-vma-metrics.py. Setup, page-table population, and semantic
// checks stay outside the timed loop; the output retains every raw sample.

import Dispatch
import Foundation
import Testing
@testable import Kernel
import KernelTestSupport

@Suite("VMA metrics benchmark", .serialized)
struct VMAMetricsBenchmark {
    private static let pageSize: UInt64 = 4096

    @Test("single-snapshot traversal scaling")
    func snapshotScaling() {
        let environment = ProcessInfo.processInfo.environment
        let iterations = Int(environment["REIX_VMA_BENCH_ITERATIONS"] ?? "200")!
        let samples = Int(environment["REIX_VMA_BENCH_SAMPLES"] ?? "20")!
        precondition(iterations > 0 && samples >= 4)

        let shapes = [(vmas: 32, stackPages: 1),
                      (vmas: 128, stackPages: 32),
                      (vmas: 1024, stackPages: 256)]
        var rows: [String] = []
        var checksum: UInt64 = 0

        for shape in shapes {
            withFixture(vmas: shape.vmas, stackPages: shape.stackPages) { manager in
                let expectedExtent = UInt64(shape.vmas - 1 + shape.stackPages)
                let expectedMapped = UInt32(expectedExtent)
                let expectedCapacity = UInt32(
                    (UserSpaceLayout.stackTop - UserSpaceLayout.stackLimit) / Self.pageSize
                )

                func observe() -> VMAMemoryMetrics {
                    let metrics = manager.pointee.memoryMetrics()
                    precondition(metrics.mappedPages == expectedMapped)
                    precondition(metrics.virtualExtentPages == expectedExtent)
                    precondition(metrics.stackExtentPages == UInt32(shape.stackPages))
                    precondition(metrics.stackCapacityPages == expectedCapacity)
                    return metrics
                }

                _ = observe()
                var elapsed: [UInt64] = []
                for _ in 0..<samples {
                    let start = DispatchTime.now().uptimeNanoseconds
                    for _ in 0..<iterations {
                        let metrics = manager.pointee.memoryMetrics()
                        checksum &+= metrics.virtualExtentPages
                        checksum &+= UInt64(metrics.stackExtentPages)
                    }
                    elapsed.append(DispatchTime.now().uptimeNanoseconds - start)
                    _ = observe()
                }

                rows.append(
                    "{\"vmas\":\(shape.vmas),\"stack_pages\":\(shape.stackPages),"
                    + "\"iterations\":\(iterations),\"elapsed_ns\":\(elapsed)}"
                )
            }
        }

        print("VMA_METRICS_BENCHMARK_JSON "
            + "{\"samples\":\(samples),\"rows\":[\(rows.joined(separator: ","))],"
            + "\"checksum\":\(checksum)}")
    }

    private func withFixture(
        vmas: Int,
        stackPages: Int,
        _ body: (UnsafeMutablePointer<VMAManager>) -> Void
    ) {
        precondition(vmas >= 2 && stackPages > 0)
        withHostRAM(pages: 16) { ram in
            let heap = UnsafeMutablePointer<BucketsHeap>.allocate(capacity: 1)
            heap.initialize(to: BucketsHeap(ppmPtr: ram.ppm))
            let manager = UnsafeMutablePointer<VMAManager>.allocate(capacity: 1)
            manager.initialize(to: VMAManager(
                heap: heap,
                vmm: ram.vmm,
                ppm: ram.ppm,
                rootTablePhysical: ram.rootTablePhysical
            ))
            var nodes: [UnsafeMutablePointer<VirtualMemoryArea>] = []

            for index in 0..<(vmas - 1) {
                let start = UserSpaceLayout.elfBaseTypical
                    + UInt64(index * 2) * Self.pageSize
                let node = makeVMA(start: start, pages: 1, flags: .none)
                manager.pointee.vmaList.insert(node)
                nodes.append(node)
            }

            let stackStart = UserSpaceLayout.stackTop - UInt64(stackPages) * Self.pageSize
            let stack = makeVMA(start: stackStart, pages: stackPages, flags: .growDown)
            manager.pointee.vmaList.insert(stack)
            nodes.append(stack)
            for index in 0..<stackPages {
                ram.mapPage(
                    virtual: stackStart + UInt64(index) * Self.pageSize,
                    physical: ram.base
                )
            }
            manager.pointee.noteMapped(UInt32(vmas - 1 + stackPages))

            body(manager)

            for node in nodes {
                node.deinitialize(count: 1)
                node.deallocate()
            }
            manager.deinitialize(count: 1)
            manager.deallocate()
            heap.deinitialize(count: 1)
            heap.deallocate()
        }
    }

    private func makeVMA(
        start: VirtualAddress,
        pages: Int,
        flags: MappingFlags
    ) -> UnsafeMutablePointer<VirtualMemoryArea> {
        let node = UnsafeMutablePointer<VirtualMemoryArea>.allocate(capacity: 1)
        node.initialize(to: VirtualMemoryArea(
            startAddress: start,
            endAddress: start + UInt64(pages) * Self.pageSize,
            permissions: [.read, .write, .user],
            backingType: .anonymous,
            mappingFlags: flags
        ))
        return node
    }
}
