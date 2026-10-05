// Host-only microbenchmark injected into KernelUnitTests by
// scripts/benchmark-kernel-runtime.py. It compares the Swift runtime adapter
// with the same working BucketsHeap lifecycle; the old no-op stubs are not a baseline.

import Dispatch
import Foundation
import Testing
@testable import Kernel
import KernelTestSupport

@Suite("Kernel runtime benchmark", .serialized)
struct KernelRuntimeBenchmark {
    @Test("adapter cost over the same balanced heap lifecycle")
    func adapterCost() {
        let environment = ProcessInfo.processInfo.environment
        let iterations = Int(environment["REIX_RUNTIME_BENCH_ITERATIONS"] ?? "20000")!
        let samples = Int(environment["REIX_RUNTIME_BENCH_SAMPLES"] ?? "20")!
        precondition(iterations > 0 && samples >= 4 && samples % 4 == 0)

        withKernelTestGlobals {
            withHostRAM(pages: 64) { ram in
                ram.installLiveManager()
                precondition(ram.donateAll())

                let savedOffset = PPMBackend.physicalOffset
                PPMBackend.physicalOffset = 0
                defer { PPMBackend.physicalOffset = savedOffset }

                var heap = BucketsHeap(ppmPtr: ram.ppm)
                withUnsafeMutablePointer(to: &heap) { heapPointer in
                    let savedHeap: UnsafeMutablePointer<BucketsHeap>? = Kernel.heap
                    Kernel.heap = heapPointer
                    defer { Kernel.heap = savedHeap }

                    let pagesBefore = ram.ppm.pointee.allocatedPages
                    var checksum: UInt = 0
                    var rows: [String] = []

                    func measure(
                        allocate: () -> UnsafeMutableRawPointer?,
                        free: (UnsafeMutableRawPointer) -> Void
                    ) -> UInt64 {
                        let start = DispatchTime.now().uptimeNanoseconds
                        for _ in 0..<iterations {
                            guard let pointer = allocate() else {
                                fatalError("runtime benchmark allocation failed")
                            }
                            pointer.storeBytes(of: UInt64(0xA110_CA7E), as: UInt64.self)
                            checksum &+= UInt(bitPattern: pointer)
                            free(pointer)
                        }
                        let elapsed = DispatchTime.now().uptimeNanoseconds - start
                        precondition(ram.ppm.pointee.allocatedPages == pagesBefore)
                        return elapsed
                    }

                    for size: UInt in [32, 256, 4096, 8192] {
                        var adapter: [UInt64] = []
                        var direct : [UInt64] = []

                        func measureAdapter() -> UInt64 {
                            measure(
                                allocate: { reixKernelMalloc(size) },
                                free: { reixKernelFree($0) }
                            )
                        }
                        func measureDirect() -> UInt64 {
                            measure(
                                allocate: { heapPointer.pointee.kmallocOrNil(max(size, 16)) },
                                free: { heapPointer.pointee.kfree($0) }
                            )
                        }

                        // Warm both paths before the interleaved A/B/B/A samples.
                        _ = measureAdapter()
                        _ = measureDirect()

                        for _ in 0..<(samples / 4) {
                            adapter.append(measureAdapter())
                            direct.append(measureDirect())
                            direct.append(measureDirect())
                            adapter.append(measureAdapter())
                        }

                        rows.append(
                            "{\"bytes\":\(size),\"adapter_ns\":\(adapter),"
                            + "\"direct_ns\":\(direct)}"
                        )
                    }

                    print(
                        "RUNTIME_BENCHMARK_JSON "
                        + "{\"iterations\":\(iterations),\"rows\":[\(rows.joined(separator: ","))],"
                        + "\"checksum\":\(checksum),\"pages_before\":\(pagesBefore),"
                        + "\"pages_after\":\(ram.ppm.pointee.allocatedPages)}"
                    )
                }
            }
        }
    }
}
