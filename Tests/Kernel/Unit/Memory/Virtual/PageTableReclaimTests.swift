//
//  PageTableReclaimTests.swift
//  ReixOS
//

import Testing
@testable import Kernel
import KernelTestSupport
import KernelHostShims

/// What an address space does with the page tables under a mapping once the
/// mapping is gone, and what a failed mapping does with the ones it had just
/// built.
///
/// Both halves are leaks that nothing observable reported. A retired leaf used to
/// leave its L3 table linked and allocated until the process died, so a process
/// that mapped and unmapped sparse regions for its whole life held one 4 KiB
/// table per 2 MiB span it had ever touched; and an install that ran out of
/// frames at L2 left the L1 it had just created behind for the same lifetime.
/// Neither shows up in a page count, in a refusal or in a fault.
///
/// The whole path is real: a live `PhysicalPageManager` over the arena, the
/// kernel's own creating descent building the tables, its own walker clearing
/// them, and `PageRetirement` driving both. The kernel master table is a page of
/// its own rather than the address space's root, which is what lets the L0 rule
/// be tested at all: with the two conflated, as `withProcessManager` has them,
/// every L0 entry reads as shared and the top level is never a candidate.
///
/// `.serialized`, and the run needs `--no-parallel`: the MMU recorder and the
/// allocation fault injection are both one global in the process.
@Suite("Page table reclaim", .serialized)
struct PageTableReclaimTests {

    private static let pageSize : UInt64 = 4096
    private static let spanSize : UInt64 = 2 * 1024 * 1024

    /// First span of the user region, so every address below shares one L1 and
    /// one L2 exactly as `UserSpaceLayout` lays a real process out.
    private static let base: VirtualAddress = UserSpaceLayout.elfBaseTypical

    private static let readWrite: VirtualPageFlags = [.present, .userAccess, .pxn, .uxn]


    // MARK: - Fixture

    /// One live manager pair over a host arena, plus an address space built the
    /// way `ProcessManager` builds one.
    ///
    /// `HostRAM.rootTablePhysical` stands in for the kernel master table: it is
    /// zeroed and outside the arena, so a new address space inherits nothing and
    /// no table this suite frees can be mistaken for one of the kernel's.
    private func withAddressSpace(
        pages : Int = 256,
        _ body: (HostRAM, PhysicalAddress, ASID) -> Void
    ) {
        withKernelTestGlobals {
            withHostRAM(pages: pages) { ram in
                ram.installLiveManager()
                #expect(ram.donateAll())

                let saved = PPMBackend.physicalOffset
                PPMBackend.physicalOffset = 0

                defer {
                    PPMBackend.physicalOffset = saved
                    PPMFaultInjection.failAllocationsAfter = nil
                    mmu_trace_reset(nil)
                }

                ram.vmm.pointee = VirtualMemoryManager(
                    hostPPM      : ram.ppm,
                    identityTable: ram.rootTablePhysical
                )

                guard let space = try? ram.vmm.pointee.createAddressSpace() else {
                    Issue.record("the arena gave no address space")
                    return
                }

                body(ram, space.rootTablePhysical, space.asid)

                try? ram.vmm.pointee.destroyAddressSpace(addressSpace: space)
            }
        }
    }


    private func context(
        _ ram : HostRAM,
        _ root: PhysicalAddress,
        _ asid: ASID,
        budget: UnsafeMutablePointer<FrameBudget>? = nil
    ) -> PagingContext {
        PagingContext(
            vmm              : ram.vmm,
            ppm              : ram.ppm,
            rootTablePhysical: root,
            budget           : budget,
            asid             : asid
        )
    }


    /// Maps one page at `virtual` onto a frame taken from the arena.
    @discardableResult
    private func install(
        _ ram  : HostRAM,
        _ root : PhysicalAddress,
        _ asid : ASID,
        virtual: VirtualAddress
    ) -> PhysicalAddress? {
        guard let frame = try? ram.ppm.pointee.alloc(4096) else {
            Issue.record("the arena gave no frame for \(virtual)")
            return nil
        }

        let error = refusal {
            try ram.vmm.pointee.installUserPage(
                rootTable: root,
                asid     : asid,
                virtual  : virtual,
                physical : frame.address,
                flags    : Self.readWrite,
                type     : .normal
            )
        }

        guard error == "none" else {
            Issue.record("the install at \(virtual) was refused: \(error)")
            return nil
        }

        return frame.address
    }


    /// Retires `[virtual, virtual + pages)` as one batch, the way a retirement
    /// operation's step does.
    private func retire(
        _ ram  : HostRAM,
        _ root : PhysicalAddress,
        _ asid : ASID,
        virtual: VirtualAddress,
        pages  : UInt64 = 1
    ) {
        PageRetirement.retire(
            context: context(ram, root, asid),
            start  : virtual,
            end    : virtual + pages * Self.pageSize,
            backing: .anonymous
        )
    }


    // MARK: - Reading the tables back

    /// Page-table pages this address space owns, the root excluded: every table
    /// reachable from a root entry that is not the kernel master's.
    private func tablePages(
        _ ram : HostRAM,
        _ root: PhysicalAddress
    ) -> Int {
        let rootTable = Self.table(at: root)
        let master    = Self.table(at: ram.rootTablePhysical)

        var total = 0

        for index in 0..<512 {
            let entry = rootTable[index]
            guard entry.isPresent, entry.isTableDescriptor            else { continue }
            guard entry.physicalAddress != master[index].physicalAddress else { continue }

            total += Self.subtreePages(entry.physicalAddress, level: 1)
        }

        return total
    }


    private static func subtreePages(
        _ physical: PhysicalAddress,
        level     : Int
    ) -> Int {
        var total = 1
        guard level < 3 else { return total }

        let table = Self.table(at: physical)

        for index in 0..<512 {
            let entry = table[index]
            guard entry.isPresent, entry.isTableDescriptor else { continue }

            total += subtreePages(entry.physicalAddress, level: level + 1)
        }

        return total
    }


    private static func table(
        at physical: PhysicalAddress
    ) -> UnsafeMutablePointer<Arch.PageTableEntry> {
        UnsafeMutableRawPointer(bitPattern: UInt(physical))!
            .bindMemory(to: Arch.PageTableEntry.self, capacity: 512)
    }


    // MARK: - Sparse spans

    @Test("unmapping every sparse span gives back every table it built")
    func sparseSpansReturnEveryTable() {
        withAddressSpace { ram, root, asid in
            let spans = 8
            let quiet = ram.pmmStateSnapshot()

            #expect(tablePages(ram, root) == 0)

            for index in 0..<spans {
                install(ram, root, asid, virtual: Self.base + UInt64(index) * Self.spanSize)
            }

            // One L1, one L2 and one L3 per span: the whole user region lives in
            // L0[1]/L1[0], so only the leaf level multiplies.
            #expect(tablePages(ram, root) == 2 + spans)

            for index in 0..<spans {
                retire(ram, root, asid, virtual: Self.base + UInt64(index) * Self.spanSize)
            }

            #expect(tablePages(ram, root) == 0)

            // The root's own entry is gone with the L1 under it, and nothing the
            // kernel master shares was touched: it has no present entry at all.
            let rootTable = Self.table(at: root)
            #expect(rootTable[Self.base.l0].isPresent == false)

            let master = Self.table(at: ram.rootTablePhysical)
            for index in 0..<512 {
                #expect(master[index].isPresent == false)
            }

            // Byte for byte what the address space started with: the frames, the
            // tables, the metadata and the allocator's own bookkeeping.
            #expect(ram.pmmStateSnapshot() == quiet)
        }
    }


    @Test("a span with pages left keeps its table and its other descriptors")
    func partialSpanKeepsItsTable() {
        withAddressSpace { ram, root, asid in
            var frames: [PhysicalAddress] = []

            for index in 0..<4 {
                guard let frame = install(
                    ram, root, asid,
                    virtual: Self.base + UInt64(index) * Self.pageSize
                ) else { return }

                frames.append(frame)
            }

            #expect(tablePages(ram, root) == 3)

            retire(ram, root, asid, virtual: Self.base, pages: 2)

            // Two of four gone, so the table is still carrying the other two and
            // stays exactly where it was.
            #expect(tablePages(ram, root) == 3)

            guard let leaf = ram.vmm.pointee.leafTable(rootTable: root, virtual: Self.base) else {
                Issue.record("the leaf table was freed while pages were still in it")
                return
            }

            #expect(leaf[Self.base.l3].isPresent == false)
            #expect(leaf[(Self.base + Self.pageSize).l3].isPresent == false)
            #expect(leaf[(Self.base + 2 * Self.pageSize).l3].physicalAddress == frames[2])
            #expect(leaf[(Self.base + 3 * Self.pageSize).l3].physicalAddress == frames[3])
        }
    }


    @Test("a span emptied beside a mapped one gives back only its own table")
    func onlyTheEmptyLeafIsFreed() {
        withAddressSpace { ram, root, asid in
            let neighbour = Self.base + Self.spanSize

            install(ram, root, asid, virtual: Self.base)
            install(ram, root, asid, virtual: neighbour)

            #expect(tablePages(ram, root) == 4)

            retire(ram, root, asid, virtual: Self.base)

            // The L3 of the emptied span, and nothing above it: the L2 still
            // holds the neighbour's table, so the L1 and the L0 entry stand.
            #expect(tablePages(ram, root) == 3)
            #expect(ram.vmm.pointee.leafTable(rootTable: root, virtual: Self.base) == nil)
            #expect(ram.vmm.pointee.leafTable(rootTable: root, virtual: neighbour) != nil)
            #expect(Self.table(at: root)[Self.base.l0].isPresent)
        }
    }


    @Test("a table the kernel master shares is never pruned")
    func kernelSharedTablesAreLeftAlone() {
        withAddressSpace { ram, root, asid in
            install(ram, root, asid, virtual: Self.base)

            // The master adopts the address space's own L1, which is the shape
            // `createAddressSpace` copies by reference.
            let rootTable = Self.table(at: root)
            let master    = Self.table(at: ram.rootTablePhysical)

            master[Self.base.l0] = rootTable[Self.base.l0]

            let shared = rootTable[Self.base.l0].physicalAddress

            retire(ram, root, asid, virtual: Self.base)

            // The L3 and the L2 went, the L1 stayed: a shared table is not this
            // address space's to free, whoever emptied it.
            #expect(ram.vmm.pointee.leafTable(rootTable: root, virtual: Self.base) == nil)
            #expect(rootTable[Self.base.l0].isPresent)
            #expect(rootTable[Self.base.l0].physicalAddress == shared)
            #expect(ram.ppm.pointee.refCount(of: shared) == 1)

            master[Self.base.l0] = Arch.PageTableEntry(rawValue: 0)
        }
    }


    // MARK: - The unlink sequence

    @Test("a prune invalidates the parent descriptor before the TLB and the free")
    func pruneOrdersTheUnlink() {
        withAddressSpace { ram, root, asid in
            // A neighbour keeps the L2 occupied, so exactly one table is pruned
            // and the trace holds one unlink rather than three.
            install(ram, root, asid, virtual: Self.base)
            install(ram, root, asid, virtual: Self.base + Self.spanSize)

            guard let leaf = ram.vmm.pointee.leafTable(rootTable: root, virtual: Self.base),
                  let slot = Self.parentSlot(ram, root, virtual: Self.base)
            else {
                Issue.record("no leaf table after the install")
                return
            }

            let leafPhysical = PhysicalAddress(UInt(bitPattern: leaf))
            #expect(ram.ppm.pointee.refCount(of: leafPhysical) == 1)

            // The probe is the L2 descriptor that names the L3 table, sampled at
            // every shim call, so the window it is invalid in is observable.
            mmu_trace_reset(slot)
            retire(ram, root, asid, virtual: Self.base)

            // The batch's own leaf invalidation first, then the unlink: the store,
            // its `dsb ishst`, every level of the walk for the span, and the wait.
            #expect(mmuOps() == [.barrier, .tlbLeaf, .tlbSync, .barrier, .tlbTable, .tlbSync])

            // Both scoped to this space's tag and to an address the table spans:
            // the walk-cache entry naming the table is used for every one of them.
            #expect(mmu_trace_arg(1) == tlbiOperand(Self.base, asid: asid))
            #expect(mmu_trace_arg(4) == tlbiOperand(Self.base, asid: asid))

            // Invalid at the invalidation, which is the whole ordering: a prune
            // that flushed first would sample the live descriptor here.
            #expect(mmu_trace_descriptor(3) == 0)
            #expect(mmu_trace_descriptor(4) == 0)
            #expect(mmu_trace_descriptor(5) == 0)

            // And freed only after it: the page is nobody's once the trace ends,
            // and it was still the table's at the invalidation.
            #expect(ram.ppm.pointee.refCount(of: leafPhysical) == 0)

            // No invalidation reached past this space: nothing global, no tag.
            #expect(mmuCount(.tlbAll)  == 0)
            #expect(mmuCount(.tlbASID) == 0)
        }
    }


    @Test("a prune that empties every level invalidates each table it takes out")
    func pruneInvalidatesEveryLevel() {
        withAddressSpace { ram, root, asid in
            install(ram, root, asid, virtual: Self.base + 7 * Self.pageSize)

            mmu_trace_reset(nil)
            retire(ram, root, asid, virtual: Self.base + 7 * Self.pageSize)

            // The L3, the L2 and the L1, youngest first, one invalidation each and
            // each with an address inside the span its own descriptor named.
            let operand = tlbiOperand(Self.base, asid: asid)
            let tables  = mmuCalls().filter { $0.op == .tlbTable }

            #expect(tables.count == 3)
            #expect(tables.allSatisfy { $0.arg == operand })
            #expect(mmuCount(.tlbSync) == 4)
            #expect(tablePages(ram, root) == 0)
        }
    }


    /// The L2 slot that names the L3 table of `virtual`, as the raw descriptor
    /// the recorder samples.
    private static func parentSlot(
        _ ram  : HostRAM,
        _ root : PhysicalAddress,
        virtual: VirtualAddress
    ) -> UnsafeMutablePointer<UInt64>? {
        let rootTable = Self.table(at: root)

        let level0 = rootTable[virtual.l0]
        guard level0.isPresent, level0.isTableDescriptor else { return nil }

        let level1 = Self.table(at: level0.physicalAddress)[virtual.l1]
        guard level1.isPresent, level1.isTableDescriptor else { return nil }

        let level2Table = Self.table(at: level1.physicalAddress)

        return UnsafeMutableRawPointer(level2Table + virtual.l2)
            .assumingMemoryBound(to: UInt64.self)
    }


    // MARK: - The creating walk that fails

    @Test("an install that runs out of frames leaves no table behind")
    func failedInstallRollsBackItsTables() {
        // One allowed allocation, then two: the walk gets its L1 and fails at
        // L2, then gets L1 and L2 and fails at L3. Both have something to undo.
        for allowed in [1, 2] {
            withAddressSpace { ram, root, asid in
                let quiet = ram.pmmStateSnapshot()

                guard let frame = try? ram.ppm.pointee.alloc(4096) else {
                    Issue.record("the arena gave no frame")
                    return
                }

                let armed = ram.pmmStateSnapshot()

                PPMFaultInjection.failAllocationsAfter = allowed

                let error = refusal {
                    try ram.vmm.pointee.installUserPage(
                        rootTable: root,
                        asid     : asid,
                        virtual  : Self.base,
                        physical : frame.address,
                        flags    : Self.readWrite,
                        type     : .normal
                    )
                }

                PPMFaultInjection.failAllocationsAfter = nil

                #expect(error == "allocationFailed")

                // Nothing linked, nothing held: the walk put back every table it
                // had made, so the allocator is where the refusal found it.
                #expect(tablePages(ram, root) == 0)
                #expect(Self.table(at: root)[Self.base.l0].isPresent == false)
                #expect(ram.pmmStateSnapshot().allocatedPages == armed.allocatedPages)

                try? ram.ppm.pointee.release(frame.address)
                #expect(ram.pmmStateSnapshot().allocatedPages == quiet.allocatedPages)
            }
        }
    }


    @Test("a failed walk invalidates each table it undoes under the install's ASID")
    func failedInstallInvalidatesWhatItUnlinked() {
        withAddressSpace { ram, root, asid in
            guard let frame = try? ram.ppm.pointee.alloc(4096) else {
                Issue.record("the arena gave no frame")
                return
            }

            // L1 and L2 built and linked, L3 refused: two tables to take back out,
            // and a speculative walk may already have cached either of them.
            PPMFaultInjection.failAllocationsAfter = 2
            mmu_trace_reset(nil)

            let error = refusal {
                try ram.vmm.pointee.installUserPage(
                    rootTable: root,
                    asid     : asid,
                    virtual  : Self.base,
                    physical : frame.address,
                    flags    : Self.readWrite,
                    type     : .normal
                )
            }

            PPMFaultInjection.failAllocationsAfter = nil

            #expect(error == "allocationFailed")

            // Two tables published, then each taken out youngest first: the store's
            // barrier, every level for the address under the tag, and the wait.
            #expect(mmuOps() == [
                .barrier, .barrier,
                .barrier, .tlbTable, .tlbSync,
                .barrier, .tlbTable, .tlbSync
            ])
            #expect(mmu_trace_arg(3) == tlbiOperand(Self.base, asid: asid))
            #expect(mmu_trace_arg(6) == tlbiOperand(Self.base, asid: asid))

            try? ram.ppm.pointee.release(frame.address)
        }
    }


    @Test("a walk that fails at its first level has nothing to undo")
    func firstLevelFailureLeavesNothing() {
        withAddressSpace { ram, root, asid in
            guard let frame = try? ram.ppm.pointee.alloc(4096) else {
                Issue.record("the arena gave no frame")
                return
            }

            let armed = ram.pmmStateSnapshot()

            PPMFaultInjection.failAllocationsAfter = 0

            let error = refusal {
                try ram.vmm.pointee.installUserPage(
                    rootTable: root,
                    asid     : asid,
                    virtual  : Self.base,
                    physical : frame.address,
                    flags    : Self.readWrite,
                    type     : .normal
                )
            }

            PPMFaultInjection.failAllocationsAfter = nil

            #expect(error == "allocationFailed")
            #expect(ram.pmmStateSnapshot() == armed)
        }
    }


    @Test("a walk over tables that were already there rolls back none of them")
    func existingTablesSurviveAFailedWalk() {
        withAddressSpace { ram, root, asid in
            // A first page builds L1, L2 and the L3 of its own span. The second
            // address needs only an L3, which is the allocation that fails.
            install(ram, root, asid, virtual: Self.base)

            let standing = tablePages(ram, root)
            #expect(standing == 3)

            guard let frame = try? ram.ppm.pointee.alloc(4096) else {
                Issue.record("the arena gave no frame")
                return
            }

            PPMFaultInjection.failAllocationsAfter = 0

            let error = refusal {
                try ram.vmm.pointee.installUserPage(
                    rootTable: root,
                    asid     : asid,
                    virtual  : Self.base + Self.spanSize,
                    physical : frame.address,
                    flags    : Self.readWrite,
                    type     : .normal
                )
            }

            PPMFaultInjection.failAllocationsAfter = nil

            #expect(error == "allocationFailed")

            // The L1 and the L2 are pre-existing and stay: only what this call
            // created is undone, and it created nothing.
            #expect(tablePages(ram, root) == standing)
            #expect(ram.vmm.pointee.leafTable(rootTable: root, virtual: Self.base) != nil)

            try? ram.ppm.pointee.release(frame.address)
        }
    }


    // MARK: - Teardown after a prune

    @Test("teardown after a prune frees the rest and frees nothing twice")
    func teardownAfterPruningIsExact() {
        withKernelTestGlobals {
            withHostRAM(pages: 256) { ram in
                ram.installLiveManager()
                #expect(ram.donateAll())

                let saved = PPMBackend.physicalOffset
                PPMBackend.physicalOffset = 0
                defer { PPMBackend.physicalOffset = saved }

                ram.vmm.pointee = VirtualMemoryManager(
                    hostPPM      : ram.ppm,
                    identityTable: ram.rootTablePhysical
                )

                // One empty cycle first: the ASID bitmap is grown on the first
                // address space and is the allocator's from then on, not a space's.
                if let warm = try? ram.vmm.pointee.createAddressSpace() {
                    try? ram.vmm.pointee.destroyAddressSpace(addressSpace: warm)
                }

                let quiet = ram.pmmStateSnapshot()

                guard let space = try? ram.vmm.pointee.createAddressSpace() else {
                    Issue.record("the arena gave no address space")
                    return
                }

                let root = space.rootTablePhysical
                let asid = space.asid

                install(ram, root, asid, virtual: Self.base)
                let resident = install(ram, root, asid, virtual: Self.base + Self.spanSize)

                // One span emptied and pruned, one left resident, so teardown
                // meets a tree a prune has already been through.
                retire(ram, root, asid, virtual: Self.base)
                #expect(tablePages(ram, root) == 3)

                // The pruned table's page goes straight back out as somebody
                // else's frame. A teardown that freed it again would take this
                // frame with it.
                guard let reused = try? ram.ppm.pointee.alloc(4096) else {
                    Issue.record("the arena gave no frame to reuse the pruned table")
                    return
                }

                try? ram.vmm.pointee.destroyAddressSpace(addressSpace: space)

                #expect(ram.ppm.pointee.refCount(of: reused.address) == 1)

                try? ram.ppm.pointee.release(reused.address)

                // The page still mapped when the space died, which `freePageTables`
                // deliberately leaves alone: data frames are `VMAManager.teardown`'s.
                if let resident { try? ram.ppm.pointee.release(resident) }

                // Everything the address space ever held is back, counted once:
                // the pruned table by the prune, the rest by the teardown. A
                // second free of the pruned page would have taken `reused` with
                // it, and the metadata is where that would show.
                //
                // The arena bytes are deliberately not compared, as they are in
                // the sparse test: `freePageTableSubtree` frees a table without
                // zeroing it, so the L2 goes back to the allocator still carrying
                // the descriptor of the span that was resident at the end.
                let after = ram.pmmStateSnapshot()

                #expect(after.allocatedPages == quiet.allocatedPages)
                #expect(after.metadata       == quiet.metadata)
            }
        }
    }


    // MARK: - The tag a teardown gives back

    @Test("teardown retires its tag with one invalidation and nothing global")
    func teardownRetiresItsTagOnce() {
        withAddressSpace { ram, root, asid in
            install(ram, root, asid, virtual: Self.base)

            mmu_trace_reset(nil)

            guard let space = try? ram.vmm.pointee.createAddressSpace() else {
                Issue.record("the arena gave no second address space")
                return
            }

            #expect(space.asid != asid)
            #expect(mmu_trace_length() == 0)

            try? ram.vmm.pointee.destroyAddressSpace(addressSpace: space)

            // The whole space, by its tag, once: neither a second flush after the
            // free nor anything that reaches the kernel's global entries.
            #expect(mmuCalls() == [MMUCall(
                op: .tlbASID, arg: UInt64(space.asid)
            )])
        }
    }


    @Test("a tag is invalidated before it is reissued, and only then")
    func reissuedTagIsInvalidatedFirst() {
        withAddressSpace { ram, root, asid in
            guard let first = try? ram.vmm.pointee.createAddressSpace() else {
                Issue.record("the arena gave no address space")
                return
            }

            let tag = first.asid

            mmu_trace_reset(nil)
            try? ram.vmm.pointee.destroyAddressSpace(addressSpace: first)

            let retired = mmuCalls()

            guard let second = try? ram.vmm.pointee.createAddressSpace() else {
                Issue.record("the arena gave no address space after the teardown")
                return
            }

            // The allocator hands the freed tag straight back, which is the case
            // the rule exists for: by then its invalidation has already run.
            #expect(second.asid == tag)
            #expect(retired.map(\.op) == [.tlbASID])
            #expect(retired.first?.arg == UInt64(tag))

            // And issuing it costs nothing more: the new owner starts empty.
            #expect(mmu_trace_length() == UInt64(retired.count))

            try? ram.vmm.pointee.destroyAddressSpace(addressSpace: second)
        }
    }


    @Test("a tag freed by a refused creation was never live and is not invalidated")
    func refusedCreationReleasesWithoutInvalidating() {
        withAddressSpace { ram, root, asid in
            let budget = UnsafeMutablePointer<FrameBudget>.allocate(capacity: 1)
            defer { budget.deallocate() }

            budget.initialize(to: FrameBudget())
            budget.pointee.limit = budget.pointee.charged

            mmu_trace_reset(nil)

            let refused = refusal {
                _ = try ram.vmm.pointee.createAddressSpace(budget: budget)
            }

            #expect(refused == "budgetExceeded")
            #expect(mmu_trace_length() == 0)

            // The tag went back: the next creation gets the same one.
            guard let next = try? ram.vmm.pointee.createAddressSpace() else {
                Issue.record("the arena gave no address space")
                return
            }

            #expect(next.asid == asid + 1)

            try? ram.vmm.pointee.destroyAddressSpace(addressSpace: next)
        }
    }
}
