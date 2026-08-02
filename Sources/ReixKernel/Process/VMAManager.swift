//
//  VMAManager.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 10/05/2026.
//

import ReixABI

/// Per-address-space owner of the Virtual Memory Areas.
///
/// One instance per process is allocated by `ProcessManager` right after
/// the VMM returns a fresh address space. The manager keeps the VMA
/// list, services page-fault decisions, grows the user stack on demand
/// and walks the page tables on teardown to release every frame the
/// process touched.
///
/// All dependencies (kernel heap, VMM, PPM) and the root page table
/// physical reference are injected at construction time so the type is
/// free of static facades.
public struct VMAManager: RXAllocatable {

    public static var errorMessageAllocation: StaticString = "Failed to allocate VMAManager on the kernel heap"
    
    private var vmaList: LinkedList<VirtualMemoryArea> // 40 Byte (All ptr 8 Bytes var)
    
    /// Current program break for the brk-style heap. Set once by
    /// `setInitialBreak` at spawn time, then bumped by `extendBreak`.
    public var currentBreak: VirtualAddress = 0 // 8 Byte
    
    private let heap: UnsafeMutablePointer<BucketsHeap>                 // 8 Byte
    private let vmm : UnsafeMutablePointer<VirtualMemoryManager>        // 8 Byte
    private let ppm : UnsafeMutablePointer<KernelPPM>                   // 8 Byte
    
    /// Cached pointer to the single VMA covering the brk heap, if any.
    /// `nil` until the first successful `extendBreak`.
    private var brkVMA: UnsafeMutablePointer<VirtualMemoryArea>? = nil  // 8 Byte
    
    
    private let rootTablePhysical: PhysicalAddress // 8 Byte
    
    
    private let asid: ASID // 2 Byte

    private static let rangeInvalidationLimit: UInt64 = 32
    private static let leafTableSpan: UInt64 = 512 * UserSpaceLayout.pageSize


    public init(
        heap             : UnsafeMutablePointer<BucketsHeap>,
        vmm              : UnsafeMutablePointer<VirtualMemoryManager>,
        ppm              : UnsafeMutablePointer<KernelPPM>,
        rootTablePhysical: PhysicalAddress,
        asid             : ASID
    ) {
        self.heap              = heap
        self.vmm               = vmm
        self.ppm               = ppm
        self.rootTablePhysical = rootTablePhysical
        self.asid              = asid
        self.vmaList           = LinkedList(
            head      : nil,
            tail      : nil,
            minAddress: UserSpaceLayout.userMin,
            maxAddress: UserSpaceLayout.userMax
        )
    }


    /// Register a new VMA over `[start, start + size)` without touching
    /// the page tables. Used by the spawn path to declare ELF segments
    /// and the user stack region: the actual PTE mapping is done by the
    /// caller (eager) or deferred to the first page-fault (lazy).
    public mutating func registerRegion(
        start      : VirtualAddress,
        size       : UInt64,
        permissions: VMAPermissions,
        backing    : BackingType,
        flags      : MappingFlags
    ) throws(VMAError) {
        guard size > 0 else { throw .invalidLayout }

        let end = start + size
        guard start >= UserSpaceLayout.userMin,
              end   <= UserSpaceLayout.userMax
        else { throw .invalidLayout }

        if vmaList.searchOverlap(start: start, end: end) != nil {
            throw .regionOverlap
        }

        guard let nodePtr = heap.pointee.kmallocOrNil(VirtualMemoryArea.self) else {
            throw .heapAllocationFailed(.allocationFailed(reason: .fullMemory))
        }

        nodePtr.initialize(
            to: VirtualMemoryArea(
                startAddress: start,
                endAddress  : end,
                permissions : permissions,
                backingType : backing,
                mappingFlags: flags
            )
        )

        vmaList.insert(nodePtr)

        var survivor = nodePtr
        if let prev = survivor.pointee.prev,
           let removed = vmaList.mergeAdjacent(prev, survivor) {
            if removed == brkVMA { brkVMA = prev }
            heap.pointee.kfree(removed)
            survivor = prev
        }
        if let next = survivor.pointee.next,
           let removed = vmaList.mergeAdjacent(survivor, next) {
            if removed == brkVMA { brkVMA = survivor }
            heap.pointee.kfree(removed)
        }
    }
    
    public func decommit(
        addr: VirtualAddress,
        size: UInt64
    ) throws(VMAError) {

        guard size > 0 else { throw .invalidLayout }

        guard addr & (UserSpaceLayout.pageSize - 1) == 0 else {
            throw .invalidLayout
        }

        guard let range = UserSpaceLayout.checkedPageRange(
            address: addr,
            size   : size
        ) else { throw .invalidLayout }

        guard let overlapping = vmaList.searchOverlap(
            start: range.start,
            end  : range.end
        ) else { throw .invalidLayout }

        var probe: UnsafeMutablePointer<VirtualMemoryArea>? = overlapping
        while let nodePtr = probe, nodePtr.pointee.startAddress < range.end {

            guard nodePtr.pointee.backingType == .anonymous else {
                throw .unownedBacking
            }

            probe = nodePtr.pointee.next
        }

        var current: UnsafeMutablePointer<VirtualMemoryArea>? = overlapping
        while let nodePtr = current, nodePtr.pointee.startAddress < range.end {

            let node  = nodePtr.pointee
            let start = node.startAddress < range.start ? range.start : node.startAddress
            let end   = node.endAddress   > range.end   ? range.end   : node.endAddress

            var va = start
            while va < end {
                try? vmm.pointee.unmapAndFreeUserPage(
                    rootTable: rootTablePhysical,
                    virtual  : va
                )
                va += UserSpaceLayout.pageSize
            }

            current = node.next
        }

        invalidateRange(start: range.start, end: range.end)
    }


    /// Decide what to do with a synchronous abort raised at `address`.
    ///
    /// Returns `true` if the manager fulfilled the access (lazy
    /// allocation, stack growth) and the user instruction can be
    /// restarted, `false` if the fault is a real segfault.
    public mutating func handlePageFault(
        at address: VirtualAddress,
        cause     : FaultCause
    ) -> Bool {
        
        guard address >= UserSpaceLayout.userMin,
              address <  UserSpaceLayout.userMax
        else { return false }

        if let vmaPtr = vmaList.search(at: address) {
            return serviceFault(
                vmaPtr : vmaPtr,
                address: address,
                cause  : cause
            )
        }

        if let growable = findGrowableStackVMA(below: address) {
            return tryGrowStack(
                vmaPtr     : growable,
                downTo     : address
            )
        }

        return false
    }


    /// Decide whether the half-open range `[start, end)` is fully
    /// covered by VMAs that grant `permissions`. Used by the syscall
    /// validation layer (`UserMemory.validateRegion`) to refuse buffers
    /// that fall on unmapped pages or violate access rights.
    public func contains(
        start      : VirtualAddress,
        end        : VirtualAddress,
        permissions: VMAPermissions
    ) -> Bool {

        guard end > start else { return false }
        guard start >= UserSpaceLayout.userMin,
              end   <= UserSpaceLayout.userMax
        else { return false }

        // Locate the VMA containing `start` once, then walk forward following
        // `next`. The list is sorted, so adjacent coverage is just a contiguity
        // check (`next.start == cursor`), O(n) total instead of restarting an
        // O(n) `search(at:)` for every covered segment (previously O(k·n))
        guard var vmaPtr = vmaList.search(at: start) else { return false }

        var cursor = start
        while cursor < end {
            let vma = vmaPtr.pointee

            guard vma.startAddress <= cursor, cursor < vma.endAddress,
                  vma.permissions.contains(permissions)
            else { return false }

            cursor = vma.endAddress
            if cursor >= end { break }

            // The next region must start exactly where this one ends, otherwise
            // there is an unmapped gap inside [start, end).
            guard let next = vma.next,
                  next.pointee.startAddress == cursor
            else { return false }

            vmaPtr = next
        }

        return true
    }


    /// `true` when `virtual` already has a live leaf entry in this address
    /// space's page tables.
    ///
    /// The syscall validation layer needs this probe but holds no
    /// `VirtualMemoryManager` handle,  the instance is private to `Kernel` and
    /// only ever injected into `ProcessManager` and here, so it is reached
    /// through the VMA manager, which already owns both the handle and the root
    /// table the probe must be relative to.
    public func isPageMapped(at virtual: VirtualAddress) -> Bool {
        guard let leafTable = vmm.pointee.leafTable(
            rootTable: rootTablePhysical,
            virtual  : virtual
        ) else { return false }

        return leafTable[virtual.l3].isPresent
    }


    /// Seed the program break value used by `extendBreak`. Called by
    /// `ProcessManager.spawnProcess` once the ELF image is loaded, with
    /// the first page-aligned address above the ELF end.
    public mutating func setInitialBreak(_ value: VirtualAddress) {
        self.currentBreak = value
    }


    /// Query the current program break.
    public func programBreak() -> VirtualAddress {
        return currentBreak
    }


    /// Move the program break upward to `newBreak`, page-aligned.
    ///
    /// Returns the new break value on success. Shrinking is rejected
    /// silently by returning the current break (no-op). The brk heap is
    /// represented by a single VMA `.noReserve`: on the first call the
    /// VMA is registered, on subsequent calls its end address is moved
    /// forward in place. The pages are not allocated here, the page
    /// fault handler materialises them lazily.
    public mutating func extendBreak(
        to newBreak: VirtualAddress
    ) throws(VMAError) -> VirtualAddress {

        guard newBreak >= UserSpaceLayout.userMin,
              newBreak <= UserSpaceLayout.mmapMin - UserSpaceLayout.pageSize else { throw .invalidLayout }

        let aligned = (newBreak + UserSpaceLayout.pageSize - 1) & ~(UserSpaceLayout.pageSize - 1)

        if aligned <= currentBreak {
            return currentBreak
        }

        if let existing = brkVMA {
            if vmaList.searchOverlap(
                start: existing.pointee.endAddress,
                end  : aligned
            ) != nil {
                throw .regionOverlap
            }

            let grown = VirtualMemoryArea(
                startAddress: existing.pointee.startAddress,
                endAddress  : aligned,
                permissions : existing.pointee.permissions,
                prev        : existing.pointee.prev,
                next        : existing.pointee.next,
                backingType : existing.pointee.backingType,
                mappingFlags: existing.pointee.mappingFlags
            )
            existing.pointee = grown

        } else {
            try registerRegion(
                start      : currentBreak,
                size       : aligned - currentBreak,
                permissions: [.read, .write, .user],
                backing    : .anonymous,
                flags      : .noReserve
            )
            brkVMA = vmaList.search(at: currentBreak)
        }

        currentBreak = aligned
        return currentBreak
    }
    
    /// Place `pageCount` pages of `physicalBase` in the mmap area with exactly
    /// `permissions`.
    ///
    /// `permissions` is the caller's to choose because the two syscalls that
    /// reach here derive it from the capability being mapped, and a region
    /// capability that carries no `.write` has to produce a read-only window.
    /// The hardcoded `[.read, .write, .user]` this replaces made that
    /// unrepresentable: every shared region and every MMIO window came out
    /// writable regardless of what its capability said.
    /// 
    public mutating func mapRegion(
        physicalBase: PhysicalAddress,
        pageCount   : Int,
        kind        : RegionKind,
        permissions : VMAPermissions
    ) throws(VMAError) -> VirtualAddress {

        guard pageCount > 0 else { throw .invalidLayout }

        let alignedSize = UInt64(pageCount) * UserSpaceLayout.pageSize

        guard let start = vmaList.findFreeGAPInRange(
            min      : UserSpaceLayout.mmapMin,
            max      : UserSpaceLayout.mmapBase,
            size     : alignedSize,
            alignment: UserSpaceLayout.pageSize,
            direction: .downward
        ) else { throw .noFreeGap }

        try registerRegion(
            start      : start,
            size       : alignedSize,
            permissions: permissions,
            backing    : kind.backing,
            flags      : .none
        )

        for i in 0..<pageCount {
            let currentVirtualPage: UInt64 = UInt64(i) * UserSpaceLayout.pageSize

            do {
                try vmm.pointee.mapUserPage(
                    rootTable: rootTablePhysical,
                    virtual  : start        + currentVirtualPage,
                    physical : physicalBase + currentVirtualPage,
                    flags    : permissions.toPageFlags(),
                    type     : kind.memoryType
                )

            } catch {
                try? munmapRegion(addr: start, size: alignedSize)
                throw .mappingFailed(error)
            }
        }

        return start
    }

    /// Reserve an anonymous read/write region in the mmap area.
    ///
    /// The region is registered as `.noReserve`: physical pages are
    /// allocated only when the user actually touches them. The hint is
    /// ignored in this milestone, placement is always automatic, in
    /// the topmost free gap of `[stackLimit, mmapBase)`.
    public mutating func mmapAnonymous(
        size       : UInt64,
        permissions: VMAPermissions
    ) throws(VMAError) -> VirtualAddress {

        guard size > 0, size <= UserSpaceLayout.mmapBase - UserSpaceLayout.mmapMin else {
            throw .invalidLayout
        }
        
        let alignedSize = (size + UserSpaceLayout.pageSize - 1) & ~(UserSpaceLayout.pageSize - 1)

        guard let start = vmaList.findFreeGAPInRange(
            min      : UserSpaceLayout.mmapMin,
            max      : UserSpaceLayout.mmapBase,
            size     : alignedSize,
            alignment: UserSpaceLayout.pageSize,
            direction: .downward
        ) else { throw .noFreeGap }

        try registerRegion(
            start      : start,
            size       : alignedSize,
            permissions: permissions,
            backing    : .anonymous,
            flags      : .noReserve
        )

        return start
    }


    public mutating func munmapRegion(
        addr: VirtualAddress,
        size: UInt64
    ) throws(VMAError) {

        // MARK: Phase 1 — validation only, the list is left exactly as it was.

        guard size > 0 else { throw .invalidLayout }

        guard addr & (UserSpaceLayout.pageSize - 1) == 0 else { throw .invalidLayout }

        guard let range = UserSpaceLayout.checkedPageRange(
            address: addr,
            size   : size
        ) else { throw .invalidLayout }

        guard let overlapping = vmaList.searchOverlap(
            start: range.start,
            end  : range.end
        ) else { throw .invalidLayout }

        var probe: UnsafeMutablePointer<VirtualMemoryArea>? = overlapping
        while let nodePtr = probe, nodePtr.pointee.startAddress < range.end {

            if nodePtr == brkVMA {
                guard nodePtr.pointee.startAddress >= range.start,
                      nodePtr.pointee.endAddress   <= range.end
                else { throw .invalidLayout }
            }

            probe = nodePtr.pointee.next
        }

        // MARK: Phase 2 — the only fallible mutations: at most two splits.

        var first = overlapping
        if range.start > first.pointee.startAddress {
            
            first = try vmaList.split(
                first,
                at   : range.start,
                using: heap
            )
        }

        var last = first
        while let next = last.pointee.next,
              next.pointee.startAddress < range.end {
            last = next
        }

        if last.pointee.endAddress > range.end {
            
            _ = try vmaList.split(
                last,
                at   : range.end,
                using: heap
            )
        }

        // MARK: Phase 3 — infallible from here on: every node is wholly inside.

        var current: UnsafeMutablePointer<VirtualMemoryArea>? = first
        while let nodePtr = current, nodePtr.pointee.startAddress < range.end {
            let node = nodePtr.pointee

            var va = node.startAddress
            while va < node.endAddress {
                switch node.backingType {
                    case .anonymous:
                        try? vmm.pointee.unmapAndFreeUserPage(
                            rootTable: rootTablePhysical,
                            virtual  : va
                        )

                    case .fileBacked, .shared, .device:
                        try? vmm.pointee.unmapUserPage(
                            rootTable: rootTablePhysical,
                            virtual  : va
                        )
                }
                va += UserSpaceLayout.pageSize
            }

            if brkVMA == nodePtr { brkVMA = nil }

            let nextPtr = node.next
            vmaList.remove(element: nodePtr)
            heap.pointee.kfree(nodePtr)
            current = nextPtr
        }

        invalidateRange(start: range.start, end: range.end)
    }


    /// Walk every registered VMA, unmap each mapped page and release
    /// the corresponding physical frame when the backing is owned by
    /// the VMA (`.anonymous`). For `.fileBacked` and `.shared` only the
    /// PTE is cleared: the backing block is freed by whoever produced
    /// it (e.g. the ELF loader frees the contiguous image block back
    /// to the PPM with its original buddy order).
    public mutating func teardown() {
        var current = vmaList.head

        while let nodePtr = current {
            let node = nodePtr.pointee
            var va   = node.startAddress

            while va < node.endAddress {
                switch node.backingType {
                    case .anonymous:
                        try? vmm.pointee.unmapAndFreeUserPage(
                            rootTable: rootTablePhysical,
                            virtual  : va
                        )

                    case .fileBacked, .shared, .device:
                        try? vmm.pointee.unmapUserPage(
                            rootTable: rootTablePhysical,
                            virtual  : va
                        )
                }
                va += UserSpaceLayout.pageSize
            }

            let nextPtr = node.next
            heap.pointee.kfree(nodePtr)
            current = nextPtr
        }

        vmaList = LinkedList(
            head      : nil,
            tail      : nil,
            minAddress: UserSpaceLayout.userMin,
            maxAddress: UserSpaceLayout.userMax
        )
    }


    private mutating func serviceFault(
        vmaPtr : UnsafeMutablePointer<VirtualMemoryArea>,
        address: VirtualAddress,
        cause  : FaultCause
    ) -> Bool {
        let vma = vmaPtr.pointee

        switch cause {
            case .translation:
                guard vma.mappingFlags.contains(.noReserve)
                   || vma.mappingFlags.contains(.growDown)
                else { return false }

                return materialize(
                    vma    : vma,
                    address: address
                )

            case .permission:
                guard vma.mappingFlags.contains(.copyOnWrite) && vma.permissions.contains(.write) else {
                    return false
                }
                
                
                let aligned = address & ~(UserSpaceLayout.pageSize - 1)
                
                guard let phys = vmm.pointee.physicalAddressOf(
                    rootTable: rootTablePhysical,
                    virtual  : aligned
                ) else { return false }
                
                
                let flags = vma.permissions.toPageFlags()
                
                if ppm.pointee.refCount(of: phys) == 1 {

                    do {
                        try vmm.pointee.protectUserPage(
                            rootTable: rootTablePhysical,
                            virtual  : aligned,
                            flags    : flags
                        )
                    } catch { return false }

                } else {

                    let page: PhysicalPage
                    do {
                        page = try ppm.pointee.alloc(4096)
                    } catch { return false }

                    let src: UnsafeMutablePointer<UInt8> = vmm.pointee.physToVirt(phys)
                    let dst: UnsafeMutablePointer<UInt8> = vmm.pointee.physToVirt(page.address)
                    
                    dst.update(from: src, count: Int(UserSpaceLayout.pageSize))

                    do {
                        try vmm.pointee.mapUserPage(
                            rootTable: rootTablePhysical,
                            virtual  : aligned,
                            physical : page.address,
                            flags    : flags
                        )
                    } catch {
                        try? ppm.pointee.free(page)
                        return false
                    }

                    try? ppm.pointee.release(phys)
                }

                Arch.MMU.flushTLBPage(aligned)
                return true

            case .alignment, .access: return false
        }
    }


    /// Retire the cached translations of `[start, end)` once its leaf
    /// descriptors have been cleared.
    private func invalidateRange(
        start: VirtualAddress,
        end  : VirtualAddress
    ) {
        let pages = (end - start) / UserSpaceLayout.pageSize

        guard pages <= Self.rangeInvalidationLimit else {
            Arch.MMU.flushTLB()
            return
        }

        var va = start
        while va < end {
            Arch.MMU.flushTLBPageNoSync(va)
            va += UserSpaceLayout.pageSize
        }

        Arch.MMU.flushTLBSync()
    }


    private func findGrowableStackVMA(
        below address: VirtualAddress
    ) -> UnsafeMutablePointer<VirtualMemoryArea>? {
        var current = vmaList.head

        while let nodePtr = current {
            let node = nodePtr.pointee

            if node.mappingFlags.contains(.growDown),
               address <  node.startAddress,
               address >= UserSpaceLayout.stackLimit
            { return nodePtr }

            current = node.next
        }

        return nil
    }


    private mutating func tryGrowStack(
        vmaPtr: UnsafeMutablePointer<VirtualMemoryArea>,
        downTo address: VirtualAddress
    ) -> Bool {
        let aligned = address & ~(UserSpaceLayout.pageSize - 1)

        guard aligned >= UserSpaceLayout.stackLimit else { return false }

        let oldStart = vmaPtr.pointee.startAddress
        guard aligned < oldStart else { return false }

        let extended = VirtualMemoryArea(
            startAddress: aligned,
            endAddress  : vmaPtr.pointee.endAddress,
            permissions : vmaPtr.pointee.permissions,
            prev        : vmaPtr.pointee.prev,
            next        : vmaPtr.pointee.next,
            backingType : vmaPtr.pointee.backingType,
            mappingFlags: vmaPtr.pointee.mappingFlags
        )
        vmaPtr.pointee = extended

        return materialize(
            vma    : vmaPtr.pointee,
            address: aligned
        )
    }


    private func materialize(
        vma    : VirtualMemoryArea,
        address: VirtualAddress
    ) -> Bool {
        let page: PhysicalPage
        do {
            page = try ppm.pointee.alloc(4096)

        } catch { return false }

        let aligned = address & ~(UserSpaceLayout.pageSize - 1)
        let flags   = vma.permissions.toPageFlags()

        let zeroDest: UnsafeMutablePointer<UInt8> = vmm.pointee.physToVirt(page.address)
        zeroDest.initialize(
            repeating: 0,
            count    : Int(UserSpaceLayout.pageSize)
        )

        do {
            try vmm.pointee.mapUserPage(
                rootTable: rootTablePhysical,
                virtual  : aligned,
                physical : page.address,
                flags    : flags
            )

        } catch {
            try? ppm.pointee.free(page)
            return false
        }

        return true
    }
    
    
    /// Reproduce the parent's address space into `self` (the child of a
    /// `split`/`fork`).
    ///
    /// For every parent VMA we register an equivalent region **carrying the
    /// parent's backing type**, not `.anonymous`, and then share or copy its
    /// resident pages according to that backing. Only `.anonymous` regions are
    /// this address space's to duplicate: a writable one is mapped read-only in
    /// both processes and marked `.copyOnWrite`, so the first write faults and
    /// takes a private frame. `.shared` and `.device` regions are mapped through
    /// as they are, because their frames belong to the `SharedRegion` behind the
    /// capability or to MMIO the PPM never owned, and neither is copyable.
    public mutating func cloneRegions(from parent: VMAManager) throws(VMAError) {
        var current = parent.vmaList.head

        while let nodePtr = current {
            let vma        = nodePtr.pointee
            let size       = vma.endAddress - vma.startAddress

            let isSharedBacking = (vma.backingType != .anonymous)
            let isWritable      = vma.permissions.contains(.write)


            var childMappingFlags = vma.mappingFlags
            if !isSharedBacking && isWritable {
                nodePtr.pointee.mappingFlags.insert(.copyOnWrite)
                childMappingFlags.insert(.copyOnWrite)
            }
            
            
            try registerRegion(
                start      : vma.startAddress,
                size       : size,
                permissions: vma.permissions,
                backing    : vma.backingType,
                flags      : childMappingFlags
            )

            
            if nodePtr == parent.brkVMA {
                self.brkVMA = self.vmaList.search(at: vma.startAddress)
            }


            var va = vma.startAddress
            while va < vma.endAddress {

                var spanEnd = (va & ~(Self.leafTableSpan - 1)) + Self.leafTableSpan
                if spanEnd > vma.endAddress { spanEnd = vma.endAddress }

                guard let parentLeaf = vmm.pointee.leafTable(
                    rootTable: parent.rootTablePhysical,
                    virtual  : va
                ) else {
                    va = spanEnd
                    continue
                }

                while va < spanEnd {
                    
                    let parentEntry = parentLeaf[va.l3]

                    guard parentEntry.isPresent else {
                        va += UserSpaceLayout.pageSize
                        continue
                    }

                    let parentPhys = parentEntry.physicalAddress

                    let pageFlags                 : VirtualPageFlags
                    let downgradeParentPermissions: Bool

                    if isSharedBacking {
                        pageFlags = vma.permissions.toPageFlags()
                        downgradeParentPermissions = false

                    } else if isWritable {
                        var permissionsNotWritable = vma.permissions
                        
                        permissionsNotWritable.remove(.write)
                        
                        pageFlags                  = permissionsNotWritable.toPageFlags()
                        downgradeParentPermissions = true
                        
                    } else {
                        pageFlags = vma.permissions.toPageFlags()
                        downgradeParentPermissions = false
                    }
                        
                    do {
                        try ppm.pointee.retain(parentPhys)
                    } catch {
                        throw .mappingFailed(error)
                    }

                    do {
                        try vmm.pointee.mapUserPage(
                            rootTable: rootTablePhysical,
                            virtual  : va,
                            physical : parentPhys,
                            flags    : pageFlags
                        )

                        if downgradeParentPermissions {
                            try vmm.pointee.mapUserPage(
                                rootTable: parent.rootTablePhysical,
                                virtual  : va,
                                physical : parentPhys,
                                flags    : pageFlags
                            )
                        }

                    } catch {
                        try? ppm.pointee.release(parentPhys)
                        throw .mappingFailed(error)
                    }

                    va += UserSpaceLayout.pageSize
                }
            }

            current = vma.next
        }

        Arch.MMU.flushTLB()
    }
}
