//
//  SplitRegionCloneTests.swift
//  ReixOS
//

import Testing
@testable import Kernel
import ReixABI
import KernelTestSupport

/// A split must keep the flags that later cloning and fault service depend on.
/// Run with `--no-parallel`: the host allocator and process index are global.
extension KernelPolicyTestRoot {
@Suite("Split region inheritance", .serialized)
struct SplitRegionCloneTests {

    private func invalidLayout(_ call: () throws -> Void) -> Bool {
        do { try call() }
        catch VMAError.invalidLayout { return true }
        catch {}
        return false
    }


    private func withManager(
        pages: Int,
        _ body: (HostRAM, UnsafeMutablePointer<KernelHeap>, UnsafeMutablePointer<ProcessManager>) -> Void
    ) {
        withProcessManager(pages: pages) { ram, heap, manager in
            let scheduler = allocateZeroedStorage(KernelScheduler.self)
            let saved = Kernel.scheduler
            Kernel.scheduler = scheduler
            defer {
                Kernel.scheduler = saved
                UnsafeMutableRawPointer(scheduler).deallocate()
            }
            body(ram, heap, manager)
        }
    }


    private static let page = UserSpaceLayout.pageSize
    private static let base = UserSpaceLayout.mmapMin + 0x20_0000


    @Test("both halves keep every anonymous or COW attribute", arguments: [UInt8(0x1D), 0x1F])
    func directSplitKeepsAttributes(_ rawFlags: UInt8) {
        withManager(pages: 160) { _, heap, manager in
            guard let process = try? manager.pointee.spawnProcess(),
                  let vma = process.pointee.addressSpace.vmaManager
            else { Issue.record("could not create the address space"); return }

            #expect(throws: Never.self) {
                try vma.pointee.registerRegion(
                    start: Self.base, size: 5 * Self.page,
                    permissions: [.read, .write, .user], backing: .anonymous,
                    flags: MappingFlags(rawValue: rawFlags), memoryType: .normal
                )
            }
            guard let left = vma.pointee.vmaList.search(at: Self.base),
                  let right = try? vma.pointee.vmaList.split(
                    left, at: Self.base + 2 * Self.page, using: heap
                  )
            else { Issue.record("the anonymous split failed"); return }

            #expect(left.pointee.startAddress == Self.base)
            #expect(left.pointee.endAddress == Self.base + 2 * Self.page)
            #expect(right.pointee.startAddress == Self.base + 2 * Self.page)
            #expect(right.pointee.endAddress == Self.base + 5 * Self.page)
            #expect(left.pointee.next == right && right.pointee.prev == left)
            #expect(vma.pointee.registeredRegions == 2)
            for node in [left, right] {
                #expect(node.pointee.mappingFlags.rawValue == rawFlags)
                #expect(node.pointee.permissions == [.read, .write, .user])
                #expect(node.pointee.backingType == .anonymous)
                #expect(node.pointee.memoryType == .normal)
                #expect(node.pointee.sharedRegion == nil)
            }
        }
    }


    @Test("a cut outside the interior leaves the anonymous node alone",
          arguments: [UInt64(0), 5, 6])
    func refusesNonInteriorSplit(_ offset: UInt64) {
        withManager(pages: 160) { ram, heap, manager in
            guard let process = try? manager.pointee.spawnProcess(),
                  let vma = process.pointee.addressSpace.vmaManager,
                  let address = try? vma.pointee.mmapAnonymous(
                    size: 5 * Self.page, permissions: [.read, .write, .user]
                  ),
                  let node = vma.pointee.vmaList.search(at: address)
            else { Issue.record("could not create the anonymous region"); return }
            let before = ram.pmmStateSnapshot()
            #expect(invalidLayout {
                _ = try vma.pointee.vmaList.split(node, at: address + offset * Self.page, using: heap)
            })
            let untouched = ram.pmmStateSnapshot() == before
            #expect(untouched)
            #expect(vma.pointee.registeredRegions == 1)
        }
    }


    @Test("unmap splits anonymous and cloned COW regions without losing fault semantics",
          arguments: [false, true], [false, true])
    func splitAndCloneKeepFaultSemantics(_ cloneFirst: Bool, _ childDiesFirst: Bool) {
        withManager(pages: 256) { ram, _, manager in
            guard let parent = try? manager.pointee.spawnProcess(),
                  let child = try? manager.pointee.spawnProcess(),
                  let parentVMA = parent.pointee.addressSpace.vmaManager,
                  let childVMA = child.pointee.addressSpace.vmaManager
            else { Issue.record("could not spawn the pair"); return }

            #expect(throws: Never.self) {
                try parentVMA.pointee.registerRegion(
                    start: Self.base, size: 5 * Self.page,
                    permissions: [.read, .write, .user], backing: .anonymous,
                    flags: [.fixed, .growDown, .noReserve, .taskConstruction], memoryType: .normal
                )
            }
            withCurrentProcess(parent) {
                for offset in [UInt64(0), 2, 4] {
                    #expect(parentVMA.pointee.handlePageFault(
                        at: Self.base + offset * Self.page, cause: .translation, access: .write
                    ) == .handled)
                }
            }
            let root = parent.pointee.addressSpace.rootTablePhysical
            guard let first = ram.vmm.pointee.physicalAddressOf(rootTable: root, virtual: Self.base),
                  let last = ram.vmm.pointee.physicalAddressOf(rootTable: root, virtual: Self.base + 4 * Self.page)
            else { Issue.record("the parent has no resident edge pages"); return }

            if cloneFirst {
                #expect(throws: Never.self) { try childVMA.pointee.cloneRegions(from: parentVMA.pointee) }
            }
            #expect((try? parentVMA.pointee.munmapRegion(
                addr: Self.base + 2 * Self.page, size: Self.page
            )) == .completed)
            if !cloneFirst {
                #expect(throws: Never.self) { try childVMA.pointee.cloneRegions(from: parentVMA.pointee) }
            } else {
                #expect((try? childVMA.pointee.munmapRegion(
                    addr: Self.base + 2 * Self.page, size: Self.page
                )) == .completed)
            }

            for vma in [parentVMA, childVMA] {
                #expect(vma.pointee.registeredRegions == 2)
                for offset in [UInt64(0), 3] {
                    guard let node = vma.pointee.vmaList.search(at: Self.base + offset * Self.page) else {
                        Issue.record("a split half disappeared"); return
                    }
                    #expect(node.pointee.mappingFlags.rawValue == 0x1F)
                    #expect(node.pointee.permissions == [.read, .write, .user])
                    #expect(node.pointee.backingType == .anonymous)
                    #expect(node.pointee.memoryType == .normal)
                    #expect(node.pointee.sharedRegion == nil)
                }
                #expect(vma.pointee.vmaList.search(at: Self.base + 2 * Self.page) == nil)
            }
            #expect(ram.ppm.pointee.refCount(of: first) == 2)
            #expect(ram.ppm.pointee.refCount(of: last) == 2)

            withCurrentProcess(child) {
                #expect(childVMA.pointee.handlePageFault(
                    at: Self.base, cause: .permission, access: .write
                ) == .handled)
                #expect(childVMA.pointee.vmaList.search(at: Self.base)?.pointee.mappingFlags.rawValue == 0x1F)
                #expect(childVMA.pointee.handlePageFault(
                    at: Self.base + 4 * Self.page, cause: .permission, access: .write
                ) == .handled)
                for offset in [UInt64(1), 3] {
                    #expect(childVMA.pointee.handlePageFault(
                        at: Self.base + offset * Self.page, cause: .translation, access: .write
                    ) == .handled)
                }
            }
            #expect(ram.ppm.pointee.refCount(of: first) == 1)
            #expect(ram.ppm.pointee.refCount(of: last) == 1)

            let firstToDie  = childDiesFirst ? childVMA : parentVMA
            let secondToDie = childDiesFirst ? parentVMA : childVMA
            firstToDie.pointee.teardown()
            #expect(secondToDie.pointee.isPageMapped(at: Self.base))
            #expect(secondToDie.pointee.isPageMapped(at: Self.base + 4 * Self.page))
            secondToDie.pointee.teardown()
            #expect(ram.ppm.pointee.refCount(of: first) == 0)
            #expect(ram.ppm.pointee.refCount(of: last) == 0)
        }
    }


    @Test("raw initrd mappings may unmap in part without releasing their frames",
          arguments: [UInt64(0), 2, 4])
    func fileBackedCutsOwnNoObject(_ offset: UInt64) {
        withManager(pages: 192) { ram, _, manager in
            guard let process = try? manager.pointee.spawnProcess(),
                  let vma = process.pointee.addressSpace.vmaManager,
                  let backing = try? ram.ppm.pointee.alloc(Int(8 * Self.page))
            else { Issue.record("could not create the file mapping"); return }
            let physical = backing.address
            defer { try? ram.ppm.pointee.free(PhysicalPage(address: physical, order: 3)) }
            #expect(throws: Never.self) {
                try vma.pointee.registerRegion(
                    start: Self.base, size: 5 * Self.page,
                    permissions: [.read, .execute, .user], backing: .fileBacked,
                    flags: .fixed, memoryType: .normal
                )
                for index in 0..<5 {
                    try ram.vmm.pointee.installUserPage(
                        rootTable: process.pointee.addressSpace.rootTablePhysical,
                        asid: process.pointee.addressSpace.asid,
                        virtual: Self.base + UInt64(index) * Self.page,
                        physical: physical + UInt64(index) * Self.page,
                        flags: VMAPermissions([.read, .execute, .user]).toPageFlags(), type: .normal
                    )
                }
            }
            #expect((try? vma.pointee.munmapRegion(
                addr: Self.base + offset * Self.page, size: Self.page
            )) == .completed)
            #expect(ram.ppm.pointee.refCount(of: physical) == 1)
            for index in 0..<5 {
                let address = Self.base + UInt64(index) * Self.page
                #expect(vma.pointee.isPageMapped(at: address) == (UInt64(index) != offset))
                if UInt64(index) != offset {
                    let node = vma.pointee.vmaList.search(at: address)
                    #expect(node?.pointee.backingType == .fileBacked)
                    #expect(node?.pointee.mappingFlags == .fixed)
                }
            }
            #expect((try? vma.pointee.munmapRegion(addr: Self.base, size: 5 * Self.page)) == .completed)
            #expect(ram.ppm.pointee.refCount(of: physical) == 1)
        }
    }
}
}
