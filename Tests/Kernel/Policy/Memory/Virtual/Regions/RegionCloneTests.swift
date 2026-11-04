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
/// The parent's tag is retired once. Already published code needs nothing on
/// VIPT and PIPT caches; other policies keep the conservative publication.
/// A copied frame or a page newly made executable still needs publication.
///
/// `.serialized`, and the run needs `--no-parallel`: the recorder, the loaded
/// cache type, `PPMBackend.physicalOffset` and `ProcessStatsIndex` are globals.
extension KernelPolicyTestRoot {
@Suite("Region clone maintenance", .serialized)
struct RegionCloneTests {

    private static let page = UserSpaceLayout.pageSize
    private static let text = UserSpaceLayout.elfBaseTypical


    struct Cache: Sendable, CustomTestStringConvertible {
        let name : String
        let ctr  : UInt64
        let clean: Int
        let all  : Int

        var testDescription: String { name }
    }

    static let caches: [Cache] = [
        Cache(name: "VIPT", ctr: cortexA53CacheType, clean: 0, all: 0),
        Cache(name: "PIPT", ctr: 0x8444_C004, clean: 0, all: 0),
        Cache(name: "VIPT IDC", ctr: 0x9444_8004, clean: 0, all: 0),
        Cache(name: "PIPT IDC DIC", ctr: 0xB444_C004, clean: 0, all: 0),
        Cache(name: "legacy AIVIVT", ctr: 0x8444_4004, clean: 16, all: 1),
        Cache(name: "reserved, formerly VPIPT", ctr: 0x8444_0004, clean: 16, all: 1),
        Cache(name: "never loaded", ctr: 0, clean: 16, all: 1),
    ]


    @Test("a clone reuses published code only on known physically tagged caches", arguments: caches)
    func cloneSettlesOnce(_ cache: Cache) {
        withParent(dataPages: 3, codePages: 16, cacheType: cache.ctr) { ram, parent, child, code in
            let parentASID = parent.pointee.addressSpace.asid

            mmu_trace_reset(nil)
            defer { mmu_trace_reset(nil) }

            guard let childVMA = child.pointee.addressSpace.vmaManager,
                  let parentVMA = parent.pointee.addressSpace.vmaManager
            else { Issue.record("the pair lost a VMA manager"); return }

            #expect(throws: Never.self) {
                try childVMA.pointee.cloneRegions(from: parentVMA)
            }

            let calls = mmuCalls()

            #expect(calls.filter { $0.op == .tlbASID }.map(\.arg) == [UInt64(parentASID)])
            #expect(mmuCount(.icacheAll)   == cache.all)
            #expect(mmuCount(.icacheLines) == 0)

            // Nothing per page, and nothing past the parent's own entries.
            #expect(mmuCount(.tlbLeaf)  == 0)
            #expect(mmuCount(.tlbTable) == 0)
            #expect(mmuCount(.tlbSync)  == 0)
            #expect(mmuCount(.tlbAll)   == 0)
            #expect(mmuCount(.stream)   == 0)

            #expect(calls.filter { $0.op == .cleanPoU }.map(\.arg)
                == (cache.clean == 0 ? [] : code))
            #expect(calls.last?.op == (cache.all == 0 ? .tlbASID : .icacheAll))

            for (index, frame) in code.enumerated() {
                #expect(ram.vmm.pointee.physicalAddressOf(
                    rootTable: child.pointee.addressSpace.rootTablePhysical,
                    virtual  : Self.text + UInt64(index) * Self.page
                ) == frame)
                #expect(ram.ppm.pointee.refCount(of: frame) == 2)
            }
            print("clone \(cache.name): clean=\(mmuCount(.cleanPoU)) lines=\(mmuCount(.icacheLines)) all=\(mmuCount(.icacheAll)) stream=\(mmuCount(.stream)) parentTLBI=\(mmuCount(.tlbASID))")
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
                try childVMA.pointee.cloneRegions(from: parentVMA)
            }

            #expect(mmuOps().last == .tlbASID)
            #expect(mmuCalls().last?.arg == UInt64(parentASID))
            #expect(mmuCount(.icacheAll) == 0)
            #expect(mmuCount(.tlbAll) == 0)
        }
    }


    @Test("a clone with no executable pages has no instruction batch", arguments: [0, 3])
    func noCodeHasNoCompletion(_ dataPages: Int) {
        withParent(dataPages: dataPages, codePages: 0, cacheType: 0x8444_4004) { _, parent, child, _ in
            mmu_trace_reset(nil)
            defer { mmu_trace_reset(nil) }

            #expect(throws: Never.self) {
                try child.pointee.addressSpace.vmaManager!.pointee.cloneRegions(
                    from: parent.pointee.addressSpace.vmaManager!
                )
            }
            #expect(mmuCount(.tlbASID) == 1)
            #expect(mmuCount(.cleanPoU) == 0)
            #expect(mmuCount(.icacheAll) == 0)
            #expect(mmuCount(.stream) == 0)
        }
    }


    @Test("a clone that first makes a page executable publishes it", arguments: [cortexA53CacheType, 0x8444_C004])
    func newlyExecutableCodeIsPublished(_ cacheType: UInt64) {
        withParent(dataPages: 0, codePages: 1, cacheType: cacheType, parentExecutable: false) { _, parent, child, code in
            mmu_trace_reset(nil)
            defer { mmu_trace_reset(nil) }

            #expect(throws: Never.self) {
                try child.pointee.addressSpace.vmaManager!.pointee.cloneRegions(
                    from: parent.pointee.addressSpace.vmaManager!
                )
            }
            #expect(mmuCalls().filter { $0.op == .cleanPoU }.map(\.arg) == code)
            #expect(mmuCount(.icacheAll) == (cacheType == cortexA53CacheType ? 1 : 0))
            #expect(mmuCount(.icacheLines) == (cacheType == cortexA53CacheType ? 0 : 1))
            #expect(mmuOps().last == (cacheType == cortexA53CacheType ? .icacheAll : .stream))
        }
    }


    @Test("a throwing clone completes code already staged", arguments: [0, 4])
    func failedCodeCloneCompletes(_ allowance: UInt32) {
        withParent(dataPages: 0, codePages: 2, cacheType: 0x8444_4004) { _, parent, child, code in
            let budget = child.pointee.metadata.pointee.budget!
            budget.pointee.limit = budget.pointee.charged + allowance

            mmu_trace_reset(nil)
            defer { mmu_trace_reset(nil) }

            #expect(throws: VMAError.self) {
                try child.pointee.addressSpace.vmaManager!.pointee.cloneRegions(
                    from: parent.pointee.addressSpace.vmaManager!
                )
            }
            #expect(mmuCalls().filter { $0.op == .cleanPoU }.map(\.arg)
                == (allowance == 0 ? [] : [code[0]]))
            #expect(mmuCount(.icacheAll) == (allowance == 0 ? 0 : 1))
            #expect(mmuCount(.tlbASID) == 1)
        }
    }


    @Test("the private code copied after a clone still needs publication", arguments: [cortexA53CacheType, 0x8444_C004])
    func copiedCodeIsPublished(_ cacheType: UInt64) {
        withParent(
            dataPages: 0,
            codePages: 1,
            cacheType: cacheType,
            codePermissions: [.read, .write, .execute, .user]
        ) { ram, parent, child, code in
            let childVMA = child.pointee.addressSpace.vmaManager!
            mmu_trace_reset(nil)
            defer { mmu_trace_reset(nil) }

            #expect(throws: Never.self) {
                try childVMA.pointee.cloneRegions(from: parent.pointee.addressSpace.vmaManager!)
            }
            #expect(mmuCount(.cleanPoU) == 0)
            #expect(mmuCount(.icacheAll) == 0)
            #expect(mmuCount(.icacheLines) == 0)
            #expect(mmuCount(.stream) == 0)

            Arch.CPU.setCurrentProcess(UInt64(UInt(bitPattern: child)))
            mmu_trace_reset(nil)

            #expect(childVMA.pointee.handlePageFault(
                at: Self.text, cause: .permission, access: .write
            ) == .handled)

            guard let copy = ram.vmm.pointee.physicalAddressOf(
                rootTable: child.pointee.addressSpace.rootTablePhysical,
                virtual: Self.text
            ) else { Issue.record("the child lost its code mapping"); return }
            #expect(copy != code.first)
            #expect(mmuCalls().filter { $0.op == .cleanPoU }.map(\.arg) == [copy])
            #expect(mmuCount(.icacheAll) == (cacheType == cortexA53CacheType ? 1 : 0))
            #expect(mmuCount(.icacheLines) == (cacheType == cortexA53CacheType ? 0 : 1))
            let bytes: UnsafeMutablePointer<UInt8> = ram.vmm.pointee.physToVirt(copy)
            #expect(bytes[0] == 0x5A)
        }
    }


    // MARK: - Fixture

    /// A parent with `dataPages` resident writable anonymous pages and
    /// `codePages` resident executable ones at `text`, an empty child, and the
    /// code pages' frames in address order.
    private func withParent(
        dataPages: Int,
        codePages: Int,
        cacheType: UInt64 = cortexA53CacheType,
        codePermissions: VMAPermissions = [.read, .execute, .user],
        parentExecutable: Bool = true,
        _ body   : (
            HostRAM,
            UnsafeMutablePointer<Process>,
            UnsafeMutablePointer<Process>,
            [PhysicalAddress]
        ) -> Void
    ) {
        withProcessManager(pages: 256) { ram, _, manager in
            withCacheType(cacheType) {
                guard let parent    = try? manager.pointee.spawnProcess(),
                      let child     = try? manager.pointee.spawnProcess(),
                      let parentVMA = parent.pointee.addressSpace.vmaManager
                else { Issue.record("could not spawn the pair"); return }

                var data: VirtualAddress = 0
                if dataPages > 0 {
                    guard let address = try? parentVMA.pointee.mmapAnonymous(
                        size       : UInt64(dataPages) * Self.page,
                        permissions: [.read, .write, .user]
                    ) else { Issue.record("could not register data"); return }
                    data = address
                }

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
                    let permissions = codePermissions

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

                        let bytes: UnsafeMutablePointer<UInt8> = ram.vmm.pointee.physToVirt(frame.address)
                        bytes.initialize(repeating: 0x5A, count: Int(Self.page))
                        var flags = permissions.toPageFlags()
                        if !parentExecutable { flags.insert(.uxn) }

                        #expect(throws: Never.self) {
                            try ram.vmm.pointee.installUserPage(
                                rootTable: parent.pointee.addressSpace.rootTablePhysical,
                                asid     : parent.pointee.addressSpace.asid,
                                virtual  : Self.text + UInt64(index) * Self.page,
                                physical : frame.address,
                                flags    : flags,
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
