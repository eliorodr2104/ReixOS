//
//  TaskProtectionTests.swift
//  ReixOS
//

import Testing
@testable import Kernel
import ReixABI
import KernelTestSupport
import KernelHostShims

/// The seal as one range operation: every descriptor of the region rewritten,
/// then one wait for all of their invalidations, under the task's own tag, and
/// one publication of the code for the whole region.
///
/// Per page, which is what this replaced, the costs were a `tlbi` across every
/// ASID, a `dsb ish`, an `isb` and a whole-cache `ic ialluis` for every page of
/// text, and nothing about the result says which of the two a kernel did. The
/// recorder does: what is asserted is the shape of the trace, its count of
/// waits and completions, and the operand every invalidation carried.
///
/// `.serialized`, and the run needs `--no-parallel`: the recorder, the loaded
/// cache type and `TaskRegistry` are globals.
extension KernelPolicyTestRoot {
@Suite("Task protection", .serialized)
struct TaskProtectionTests {

    private static let page = UserSpaceLayout.pageSize
    private static let base = UserSpaceLayout.elfBaseTypical

    private static let code: VMAPermissions = [.read, .execute, .user]
    private static let data: VMAPermissions = [.read, .write, .user]


    @Test("sealing text rewrites every page, waits once and publishes once")
    func sealIsOneBatch() {
        withMappedTask(pages: 4) { ram, vma, process in
            let asid = process.pointee.addressSpace.asid

            let sealed = vma.pointee.protectTaskRegion(
                start      : Self.base,
                end        : Self.base + 4 * Self.page,
                permissions: Self.code
            )
            #expect(sealed)

            let calls = mmuCalls()

            // Each page staged through the kernel alias and published, then the
            // range invalidated by page with one wait, then one completion.
            #expect(calls.map(\.op) == [
                .cleanPoU, .barrier, .cleanPoU, .barrier,
                .cleanPoU, .barrier, .cleanPoU, .barrier,
                .tlbLeaf, .tlbLeaf, .tlbLeaf, .tlbLeaf, .tlbSync,
                .icacheAll
            ])

            #expect(calls.filter { $0.op == .tlbLeaf }.map(\.arg) == (0..<4).map {
                tlbiOperand(Self.base + UInt64($0) * Self.page, asid: asid)
            })

            #expect(calls.filter { $0.op == .cleanPoU }.map(\.arg) == (0..<4).map {
                ram.vmm.pointee.physicalAddressOf(
                    rootTable: process.pointee.addressSpace.rootTablePhysical,
                    virtual  : Self.base + UInt64($0) * Self.page
                ) ?? 0
            })

            #expect(vma.pointee.vmaList.search(at: Self.base)?.pointee.permissions == Self.code)
        }
    }


    @Test("a long seal invalidates the tag once instead of every page")
    func longSealUsesTheTag() {
        withMappedTask(pages: 40) { _, vma, process in
            let sealed = vma.pointee.protectTaskRegion(
                start      : Self.base,
                end        : Self.base + 40 * Self.page,
                permissions: Self.code
            )
            #expect(sealed)

            let ops = mmuOps()

            #expect(mmuCount(.cleanPoU) == 40)
            #expect(mmuCount(.barrier)  == 40)
            #expect(mmuCount(.tlbLeaf)  == 0)
            #expect(mmuCount(.tlbSync)  == 0)
            #expect(mmuCount(.tlbAll)   == 0)
            #expect(Array(ops.suffix(2)) == [.tlbASID, .icacheAll])
            #expect(mmu_trace_arg(UInt64(ops.count - 2)) == UInt64(process.pointee.addressSpace.asid))
        }
    }


    @Test("sealing data invalidates in one wait and publishes nothing")
    func dataSealPublishesNothing() {
        withMappedTask(pages: 3) { _, vma, process in
            let asid = process.pointee.addressSpace.asid

            let sealed = vma.pointee.protectTaskRegion(
                start      : Self.base,
                end        : Self.base + 3 * Self.page,
                permissions: Self.data
            )
            #expect(sealed)

            #expect(mmuOps() == [.barrier, .barrier, .barrier, .tlbLeaf, .tlbLeaf, .tlbLeaf, .tlbSync])
            #expect(mmu_trace_arg(3) == tlbiOperand(Self.base, asid: asid))
        }
    }


    @Test("a refused seal touches no descriptor and issues nothing")
    func refusedSealIssuesNothing() {
        withMappedTask(pages: 4) { _, vma, _ in
            // Not the exact region, then a writable and executable one, then an
            // empty range.
            let partial = vma.pointee.protectTaskRegion(
                start      : Self.base,
                end        : Self.base + 2 * Self.page,
                permissions: Self.code
            )
            let writableCode = vma.pointee.protectTaskRegion(
                start      : Self.base,
                end        : Self.base + 4 * Self.page,
                permissions: [.read, .write, .execute, .user]
            )
            let backwards = vma.pointee.protectTaskRegion(
                start      : Self.base + Self.page,
                end        : Self.base,
                permissions: Self.code
            )

            #expect(!partial)
            #expect(!writableCode)
            #expect(!backwards)

            #expect(mmu_trace_length() == 0)
        }
    }


    @Test("a page that cannot be protected undoes the ones before it and invalidates exactly those")
    func failedSealRollsBack() {
        withMappedTask(pages: 4) { ram, vma, process in
            let root = process.pointee.addressSpace.rootTablePhysical
            let asid = process.pointee.addressSpace.asid

            // Page 2 loses its descriptor behind the VMA's back, so the third
            // protect is refused and the first two have to be put back.
            ram.vmm.pointee.removeUserPage(rootTable: root, virtual: Self.base + 2 * Self.page)
            mmu_trace_reset(nil)

            let sealed = vma.pointee.protectTaskRegion(
                start      : Self.base,
                end        : Self.base + 4 * Self.page,
                permissions: Self.code
            )
            #expect(!sealed)

            // Two pages staged and rewritten, the same two restored, the two
            // invalidated with one wait, and no completion: nothing stayed code.
            #expect(mmuOps() == [
                .cleanPoU, .barrier, .cleanPoU, .barrier,
                .barrier, .barrier,
                .tlbLeaf, .tlbLeaf, .tlbSync
            ])
            #expect(mmuCalls().filter { $0.op == .tlbLeaf }.map(\.arg) == [
                tlbiOperand(Self.base,             asid: asid),
                tlbiOperand(Self.base + Self.page, asid: asid)
            ])

            // And the region is exactly as it was: data, not code.
            let region = vma.pointee.vmaList.search(at: Self.base)
            #expect(region?.pointee.permissions == Self.data)

            guard let leaf = ram.vmm.pointee.leafTable(rootTable: root, virtual: Self.base) else {
                Issue.record("the leaf table went missing")
                return
            }

            #expect(leaf[Self.base.l3].flags.contains(.uxn))
            #expect(!leaf[Self.base.l3].flags.contains(.readOnly))
        }
    }


    // MARK: - Fixture

    /// A suspended task holding one `.taskConstruction` region of `pages` pages
    /// at `base`, every page backed, with the trace reset just after.
    private func withMappedTask(
        pages : UInt32,
        _ body: (HostRAM, UnsafeMutablePointer<VMAManager>, UnsafeMutablePointer<Process>) -> Void
    ) {
        withProcessManager(pages: 256) { ram, _, manager in
            TaskRegistry.resetForTesting()
            defer { TaskRegistry.resetForTesting() }

            guard let owner = try? manager.pointee.spawnProcess(),
                  let task  = manager.pointee.createSuspendedTask(ownedBy: owner)
            else {
                Issue.record("could not create the suspended task")
                return
            }

            task.process.pointee.metadata.pointee.budget.pointee.limit = .max

            #expect(manager.pointee.mapTaskAnonymous(task.control, at: Self.base, pages: pages) == .ok)

            guard let vma = task.process.pointee.addressSpace.vmaManager else {
                Issue.record("the task has no VMA manager")
                return
            }

            withCacheType(cortexA53CacheType) {
                mmu_trace_reset(nil)
                defer { mmu_trace_reset(nil) }

                body(ram, vma, task.process)
            }
        }
    }
}
}
