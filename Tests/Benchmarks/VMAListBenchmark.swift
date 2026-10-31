// Host-only probe injected into KernelUnitTests by scripts/benchmark-vma-list.py.
// The list is laid out the way a process holds it (image, brk, packed mmap
// windows, stack) and every timed operation leaves it exactly as it found it.

import Dispatch
import Foundation
import Testing
@testable import Kernel
import KernelTestSupport

@Suite("VMA list benchmark", .serialized)
struct VMAListBenchmark {
    private static let pageSize = UserSpaceLayout.pageSize

    @Test("VMA list cost per operation at 8 to 1024 regions")
    func operations() {
        let environment = ProcessInfo.processInfo.environment
        let iterations  = Int(environment["REIX_VMA_LIST_BENCH_ITERATIONS"] ?? "20000")!
        let samples     = Int(environment["REIX_VMA_LIST_BENCH_SAMPLES"] ?? "20")!
        precondition(iterations > 0 && samples >= 4)

        var rows    : [String] = []
        var checksum: UInt64   = 0

        // 8 to 64 are what the kernel runs under its default ceiling; 128 and
        // 1024 exist only here, through a raised `nodeLimit`.
        for regions in [8, 16, 32, 64, 128, 1024] {
            withLayout(regions: regions) { list, nodes in
                let mmapLow  = nodes.filter { $0.pointee.startAddress >= UserSpaceLayout.mmapMin
                                              && $0.pointee.endAddress <= UserSpaceLayout.mmapBase }
                                    .map { $0.pointee.startAddress }.min()!
                let stack    = nodes.last!

                // Every region once, in a fixed scattered order: faults that
                // land anywhere in the address space.
                let scattered = (0..<nodes.count).map {
                    nodes[($0 * 5 + 3) % nodes.count].pointee.startAddress
                }

                // Sixteen faults per region before moving on: first touch of a
                // buffer, page after page.
                var local: [VirtualAddress] = []
                for node in nodes {
                    for page in 0..<16 {
                        local.append(node.pointee.startAddress + UInt64(page % Int(node.pointee.size / Self.pageSize)) * Self.pageSize)
                    }
                }

                // Below the stack's lowest page and above every other region:
                // the stack growth fault, which misses the list by design.
                let growth = stack.pointee.startAddress - Self.pageSize

                func time(_ name: String, _ body: (Int) -> UInt64) {
                    var elapsed: [UInt64] = []
                    for _ in 0..<samples {
                        let start = DispatchTime.now().uptimeNanoseconds
                        for step in 0..<iterations { checksum &+= body(step) }
                        elapsed.append(DispatchTime.now().uptimeNanoseconds - start)
                    }
                    rows.append(
                        "{\"workload\":\"\(name)\",\"regions\":\(regions),"
                        + "\"ops\":\(iterations),\"elapsed_ns\":\(elapsed)}"
                    )
                }

                time("search-scattered") { step in
                    UInt64(UInt(bitPattern: list.search(at: scattered[step % scattered.count])))
                }
                time("search-local") { step in
                    UInt64(UInt(bitPattern: list.search(at: local[step % local.count])))
                }
                time("search-growth-miss") { _ in
                    list.search(at: growth) == nil ? 1 : 0
                }
                // Between the first two image segments: a stray pointer, the
                // fault that ends in a kill.
                time("search-low-miss") { _ in
                    list.search(at: nodes[0].pointee.endAddress) == nil ? 1 : 0
                }
                time("overlap-next-mmap") { _ in
                    list.searchOverlap(start: mmapLow - Self.pageSize, end: mmapLow) == nil ? 1 : 0
                }
                time("gap-mmap-down") { _ in
                    list.findFreeGAPInRange(
                        min      : UserSpaceLayout.mmapMin,
                        max      : UserSpaceLayout.mmapBase,
                        size     : Self.pageSize,
                        alignment: Self.pageSize,
                        direction: .downward
                    ) ?? 0
                }

                let probe = makeVMA(start: mmapLow - Self.pageSize, pages: 1, flags: .none)
                time("insert-remove-mmap") { _ in
                    _ = try? list.insert(probe)
                    list.remove(element: probe)
                    return UInt64(list.nodeCount)
                }
                probe.deinitialize(count: 1)
                probe.deallocate()
            }
        }

        // What the list costs is only worth reading against the operation it
        // serves: a lazy fault, and an mmap, through the real manager.
        for regions in [8, 16, 32, 64] {
            withManager(regions: regions) { manager in
                let window = try! manager.pointee.mmapAnonymous(
                    size       : Self.pageSize,
                    permissions: [.read, .execute, .user]
                )
                precondition(Int(manager.pointee.registeredRegions) == regions - 1)
                let rounds = max(iterations / 20, 1)

                var fault: [UInt64] = []
                var mmap : [UInt64] = []
                for _ in 0..<samples {
                    var start = DispatchTime.now().uptimeNanoseconds
                    for _ in 0..<rounds {
                        let outcome = manager.pointee.handlePageFault(
                            at: window, cause: .translation, access: .read
                        )
                        precondition(outcome == .handled)
                        _ = try! manager.pointee.decommit(addr: window, size: Self.pageSize)
                    }
                    fault.append(DispatchTime.now().uptimeNanoseconds - start)

                    start = DispatchTime.now().uptimeNanoseconds
                    for _ in 0..<rounds {
                        let placed = try! manager.pointee.mmapAnonymous(
                            size       : Self.pageSize,
                            permissions: [.read, .user]
                        )
                        try! manager.pointee.rollbackMapping(addr: placed, size: Self.pageSize)
                        checksum &+= placed
                    }
                    mmap.append(DispatchTime.now().uptimeNanoseconds - start)
                }
                rows.append("{\"workload\":\"manager-fault-decommit\",\"regions\":\(regions),"
                    + "\"ops\":\(rounds),\"elapsed_ns\":\(fault)}")
                rows.append("{\"workload\":\"manager-mmap-unmap\",\"regions\":\(regions),"
                    + "\"ops\":\(rounds),\"elapsed_ns\":\(mmap)}")
            }
        }

        print("VMA_LIST_BENCHMARK_JSON "
            + "{\"samples\":\(samples),\"rows\":[\(rows.joined(separator: ","))],"
            + "\"checksum\":\(checksum)}")
    }


    /// Three image segments and a brk region low, `regions - 5` mmap windows
    /// packed down from `mmapBase` the way `mmapAnonymous` places them, and
    /// the stack on top. Nodes come back in address order.
    private func withLayout(
        regions: Int,
        _ body : (inout VMAList, [UnsafeMutablePointer<VirtualMemoryArea>]) -> Void
    ) {
        precondition(regions >= 6)
        var list = VMAList(
            minAddress: UserSpaceLayout.userMin,
            maxAddress: UserSpaceLayout.userMax,
            nodeLimit : UInt16(max(Int(VMAList.defaultNodeLimit), regions))
        )
        var nodes: [UnsafeMutablePointer<VirtualMemoryArea>] = []

        var cursor = UserSpaceLayout.elfBaseTypical
        for pages in [8, 2, 4, 16] {
            nodes.append(makeVMA(start: cursor, pages: pages, flags: .none))
            cursor += UInt64(pages + 1) * Self.pageSize
        }

        var top = UserSpaceLayout.mmapBase
        var windows: [UnsafeMutablePointer<VirtualMemoryArea>] = []
        for index in 0..<(regions - 5) {
            let pages = 1 + index % 4
            top -= UInt64(pages) * Self.pageSize
            windows.append(makeVMA(start: top, pages: pages, flags: .none))
        }
        nodes += windows.reversed()

        nodes.append(makeVMA(
            start: UserSpaceLayout.stackTop - 8 * Self.pageSize,
            pages: 8,
            flags: .growDown
        ))

        // Inserted in mmap order, newest window first, as the kernel would.
        for node in nodes.prefix(4) + windows + [nodes.last!] {
            do { try list.insert(node) } catch { preconditionFailure("layout overlaps") }
        }
        precondition(list.nodeCount == UInt16(regions))

        body(&list, nodes)

        for node in nodes {
            node.deinitialize(count: 1)
            node.deallocate()
        }
    }


    /// The same shape registered in a spawned process's own manager,
    /// permissions alternating so that neighbours never merge into one region.
    private func withManager(
        regions: Int,
        _ body : (UnsafeMutablePointer<VMAManager>) -> Void
    ) {
        withProcessManager(pages: 256) { _, _, processes in
            let process = try! processes.pointee.spawnProcess()
            let manager = process.pointee.addressSpace.vmaManager!

            var cursor = UserSpaceLayout.elfBaseTypical
            for pages in [8, 2, 4, 16] {
                try? manager.pointee.registerRegion(
                    start: cursor, size: UInt64(pages) * Self.pageSize,
                    permissions: [.read, .user], backing: .anonymous,
                    flags: .noReserve, memoryType: .normal
                )
                cursor += UInt64(pages + 1) * Self.pageSize
            }
            try? manager.pointee.registerRegion(
                start: UserSpaceLayout.stackTop - 8 * Self.pageSize, size: 8 * Self.pageSize,
                permissions: [.read, .write, .user], backing: .anonymous,
                flags: [.growDown, .noReserve], memoryType: .normal
            )
            // Two short: the fault's window and the timed mmap make `regions`.
            var index = 0
            while Int(manager.pointee.registeredRegions) < regions - 2 {
                _ = try! manager.pointee.mmapAnonymous(
                    size       : UInt64(1 + index % 4) * Self.pageSize,
                    permissions: index % 2 == 0 ? [.read, .user] : [.read, .write, .user]
                )
                index += 1
            }

            body(manager)
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
            endAddress  : start + UInt64(pages) * Self.pageSize,
            permissions : [.read, .write, .user],
            backingType : .anonymous,
            mappingFlags: flags,
            memoryType  : .normal
        ))
        return node
    }
}
