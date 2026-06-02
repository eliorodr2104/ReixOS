//
//  VMAManager.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 10/05/2026.
//

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
public struct VMAManager: RXObject {
    
    public static var errorMessageAllocation = "Failed to allocate VMAManager on the kernel heap"
    
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
    
    
    private let rootTablePhysical: PhysicalPage // 9 Byte
    
    
    private let asid: ASID // 2 Byte
    

    public init(
        heap             : UnsafeMutablePointer<BucketsHeap>,
        vmm              : UnsafeMutablePointer<VirtualMemoryManager>,
        ppm              : UnsafeMutablePointer<KernelPPM>,
        rootTablePhysical: PhysicalPage,
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

        let nodePtr = heap.pointee.kmalloc(VirtualMemoryArea.self)
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
        // TODO: Remove when resolve this bug
        // This is a test for a bug
        // let dbg = vmaList.search(at: address)
        // kprintf("[PF] addr=0x%x found=%d\n", address, dbg != nil ? 1 : 0)
        
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

        var cursor = start
        while cursor < end {
            guard let vmaPtr = vmaList.search(at: cursor) else {
                return false
            }
            let vma = vmaPtr.pointee

            guard vma.permissions.contains(permissions) else {
                return false
            }

            cursor = vma.endAddress
        }

        return true
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
    /// forward in place. The pages are not allocated here — the page
    /// fault handler materialises them lazily.
    public mutating func extendBreak(
        to newBreak: VirtualAddress
    ) throws(VMAError) -> VirtualAddress {

        let aligned = (newBreak + UserSpaceLayout.pageSize - 1) & ~(UserSpaceLayout.pageSize - 1)

        guard aligned >= UserSpaceLayout.userMin,
              aligned <= UserSpaceLayout.mmapBase
        else { throw .invalidLayout }

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


    /// Reserve an anonymous read/write region in the mmap area.
    ///
    /// The region is registered as `.noReserve`: physical pages are
    /// allocated only when the user actually touches them. The hint is
    /// ignored in this milestone — placement is always automatic, in
    /// the topmost free gap of `[stackLimit, mmapBase)`.
    public mutating func mmapAnonymous(
        size       : UInt64,
        permissions: VMAPermissions
    ) throws(VMAError) -> VirtualAddress {

        guard size > 0 else { throw .invalidLayout }

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


    /// Release a previously reserved region.
    ///
    /// Only full-region unmap is supported in this milestone: `addr`
    /// must match the VMA start and `size` must match the VMA size.
    /// Partial unmap (split) is left for the next milestone.
    public mutating func munmapRegion(
        addr: VirtualAddress,
        size: UInt64
    ) throws(VMAError) {

        guard size > 0 else { throw .invalidLayout }

        let alignedSize = (size + UserSpaceLayout.pageSize - 1) & ~(UserSpaceLayout.pageSize - 1)
        let end         = addr + alignedSize

        guard let vmaPtr = vmaList.search(at: addr) else {
            throw .invalidLayout
        }

        guard vmaPtr.pointee.startAddress == addr,
              vmaPtr.pointee.endAddress   == end
        else { throw .invalidLayout }

        if brkVMA == vmaPtr {
            brkVMA = nil
        }

        var va = vmaPtr.pointee.startAddress
        while va < vmaPtr.pointee.endAddress {
            switch vmaPtr.pointee.backingType {
                case .anonymous:
                    try? vmm.pointee.unmapAndFreeUserPage(
                        rootTable: rootTablePhysical,
                        virtual  : va
                    )

                case .fileBacked, .shared:
                    try? vmm.pointee.unmapUserPage(
                        rootTable: rootTablePhysical,
                        virtual  : va
                    )
            }
            va += UserSpaceLayout.pageSize
        }

        vmaList.remove(element: vmaPtr)
        heap.pointee.kfree(UnsafeMutableRawPointer(vmaPtr))
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

                    case .fileBacked, .shared:
                        try? vmm.pointee.unmapUserPage(
                            rootTable: rootTablePhysical,
                            virtual  : va
                        )
                }
                va += UserSpaceLayout.pageSize
            }

            let nextPtr = node.next
            heap.pointee.kfree(UnsafeMutableRawPointer(nodePtr))
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

            case .permission        : return false
            case .alignment, .access: return false
        }
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
    /// For every parent VMA we register an equivalent region and then make
    /// a *private* copy of each page the parent has actually mapped:
    /// allocate a fresh frame, copy the bytes and map it into the child's
    /// root table. The child therefore owns every page it sees, so each
    /// region is registered as `.anonymous` — its frames are released
    /// per-page on teardown — while the parent's permissions and mapping
    /// flags (`growDown` / `noReserve`) are preserved so lazy growth keeps
    /// working. Pages the parent has not faulted in yet are left unmapped
    /// in the child too: they fault in on demand exactly as they would
    /// have in the parent.
    public mutating func cloneRegions(from parent: VMAManager) throws(VMAError) {
        var current = parent.vmaList.head

        while let nodePtr = current {
            let vma  = nodePtr.pointee
            let size = vma.endAddress - vma.startAddress

            try registerRegion(
                start      : vma.startAddress,
                size       : size,
                permissions: vma.permissions,
                backing    : .anonymous,
                flags      : vma.mappingFlags
            )

            if nodePtr == parent.brkVMA {
                self.brkVMA = self.vmaList.search(at: vma.startAddress)
            }

            let flags = vma.permissions.toPageFlags()
            var va    = vma.startAddress
            while va < vma.endAddress {
                if let parentPhys = vmm.pointee.physicalAddressOf(
                    rootTable: parent.rootTablePhysical,
                    virtual  : va
                ) {
                    let page: PhysicalPage
                    do {
                        page = try ppm.pointee.alloc(4096)
                    } catch { throw .allocationFailed(error) }

                    let src: UnsafeMutablePointer<UInt8> = vmm.pointee.physToVirt(parentPhys)
                    let dst: UnsafeMutablePointer<UInt8> = vmm.pointee.physToVirt(page.address)
                    dst.update(from: src, count: Int(UserSpaceLayout.pageSize))

                    do {
                        try vmm.pointee.mapUserPage(
                            rootTable: rootTablePhysical,
                            virtual  : va,
                            physical : page.address,
                            flags    : flags,
                            flushTLB : false
                        )
                    } catch {
                        try? ppm.pointee.free(page)
                        throw .mappingFailed(error)
                    }
                }

                va += UserSpaceLayout.pageSize
            }

            current = vma.next
        }
    }
}
