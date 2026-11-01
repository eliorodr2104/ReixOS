//
//  RegionCloneTests.swift
//  ReixOS
//

import Testing
@testable import Kernel
import ReixABI
import KernelTestSupport
import KernelHostShims

/// What a clone owes the TLB and the instruction cache, and how often.
///
/// The parent's writable pages are downgraded in place while the walk runs and
/// the child's pages, code included, are installed into a space nobody has run.
/// Both are settled once, when `cloneRegions` returns: one `tlbi aside1is` for
/// the parent's tag and one completion for the child's code. Per page, which is
/// the cost this replaced, a fork of a process with fifty pages of text paid
/// fifty whole-cache invalidations.
///
/// `.serialized`, and the run needs `--no-parallel`: the recorder, the loaded
/// cache type, `PPMBackend.physicalOffset` and `ProcessStatsIndex` are globals.
extension KernelPolicyTestRoot {
@Suite("Region clone maintenance", .serialized)
struct RegionCloneTests {

    private static let page = UserSpaceLayout.pageSize
    private static let text = UserSpaceLayout.elfBaseTypical


    @Test("a clone retires the parent's tag once and publishes the child's code once")
    func cloneSettlesOnce() {
        withParent(dataPages: 3, codePages: 2) { ram, parent, child, code in
            let parentASID = parent.pointee.addressSpace.asid

            mmu_trace_reset(nil)
            defer { mmu_trace_reset(nil) }

            guard let childVMA = child.pointee.addressSpace.vmaManager,
                  let parentVMA = parent.pointee.addressSpace.vmaManager
            else { Issue.record("the pair lost a VMA manager"); return }

            #expect(throws: Never.self) {
                try childVMA.pointee.cloneRegions(from: parentVMA.pointee)
            }

            let calls = mmuCalls()

            // One invalidation, the parent's tag, then the one completion, last.
            #expect(Array(calls.suffix(2).map(\.op)) == [.tlbASID, .icacheAll])
            #expect(calls.suffix(2).first?.arg == UInt64(parentASID))
            #expect(mmuCount(.tlbASID)   == 1)
            #expect(mmuCount(.icacheAll) == 1)

            // Nothing per page, and nothing past the parent's own entries.
            #expect(mmuCount(.tlbLeaf)  == 0)
            #expect(mmuCount(.tlbTable) == 0)
            #expect(mmuCount(.tlbSync)  == 0)
            #expect(mmuCount(.tlbAll)   == 0)
            #expect(mmuCount(.stream)   == 0)

            // Each code page staged once, through the kernel alias of its frame.
            #expect(calls.filter { $0.op == .cleanPoU }.map(\.arg) == code)

            // And the child's code is in place, sharing the parent's frames.
            #expect(ram.vmm.pointee.physicalAddressOf(
                rootTable: child.pointee.addressSpace.rootTablePhysical,
                virtual  : Self.text
            ) == code.first)
        }
    }


    @Test("a clone that fails part way still retires the parent's tag")
    func failedCloneStillInvalidates() {
        withParent(dataPages: 4, codePages: 0) { ram, parent, child, _ in
            let parentASID = parent.pointee.addressSpace.asid

            // Room for one retained frame and the three tables its install builds,
            // so the walk throws with the first downgrade already in the parent.
            guard let budget = child.pointee.metadata.pointee.budget else {
                Issue.record("the child has no budget")
                return
            }
            budget.pointee.limit = budget.pointee.charged + 4

            mmu_trace_reset(nil)
            defer { mmu_trace_reset(nil) }

            guard let childVMA = child.pointee.addressSpace.vmaManager,
                  let parentVMA = parent.pointee.addressSpace.vmaManager
            else { Issue.record("the pair lost a VMA manager"); return }

            #expect(throws: VMAError.self) {
                try childVMA.pointee.cloneRegions(from: parentVMA.pointee)
            }

            #expect(Array(mmuOps().suffix(2)) == [.tlbASID, .icacheAll])
            #expect(mmuCalls().suffix(2).first?.arg == UInt64(parentASID))
            #expect(mmuCount(.tlbAll) == 0)
        }
    }


    // MARK: - Fixture

    /// A parent with `dataPages` resident writable anonymous pages and
    /// `codePages` resident executable ones at `text`, an empty child, and the
    /// code pages' frames in address order.
    private func withParent(
        dataPages: Int,
        codePages: Int,
        _ body   : (
            HostRAM,
            UnsafeMutablePointer<Process>,
            UnsafeMutablePointer<Process>,
            [PhysicalAddress]
        ) -> Void
    ) {
        withProcessManager(pages: 256) { ram, _, manager in
            withCacheType(cortexA53CacheType) {
                guard let parent    = try? manager.pointee.spawnProcess(),
                      let child     = try? manager.pointee.spawnProcess(),
                      let parentVMA = parent.pointee.addressSpace.vmaManager,
                      let data      = try? parentVMA.pointee.mmapAnonymous(
                        size       : UInt64(dataPages) * Self.page,
                        permissions: [.read, .write, .user]
                      )
                else { Issue.record("could not spawn the pair"); return }

                Arch.CPU.setCurrentProcess(UInt64(UInt(bitPattern: parent)))
                defer { Arch.CPU.setCurrentProcess(0) }

                for index in 0..<dataPages {
                    #expect(parentVMA.pointee.handlePageFault(
                        at    : data + UInt64(index) * Self.page,
                        cause : .translation,
                        access: .write
                    ) == .handled)
                }

                var code: [PhysicalAddress] = []

                if codePages > 0 {
                    let permissions: VMAPermissions = [.read, .execute, .user]

                    #expect(throws: Never.self) {
                        try parentVMA.pointee.registerRegion(
                            start      : Self.text,
                            size       : UInt64(codePages) * Self.page,
                            permissions: permissions,
                            backing    : .anonymous,
                            flags      : .none,
                            memoryType : .normal
                        )
                    }

                    for index in 0..<codePages {
                        guard let frame = try? ram.ppm.pointee.alloc(Int(Self.page)) else {
                            Issue.record("the arena gave no code frame")
                            return
                        }

                        #expect(throws: Never.self) {
                            try ram.vmm.pointee.installUserPage(
                                rootTable: parent.pointee.addressSpace.rootTablePhysical,
                                asid     : parent.pointee.addressSpace.asid,
                                virtual  : Self.text + UInt64(index) * Self.page,
                                physical : frame.address,
                                flags    : permissions.toPageFlags(),
                                type     : .normal
                            )
                        }

                        code.append(frame.address)
                    }
                }

                body(ram, parent, child, code)
            }
        }
    }
}
}
