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
public struct VMAManager {

    private var vmaList: LinkedList<VirtualMemoryArea>

    private let heap: UnsafeMutablePointer<BucketsHeap>
    private let vmm : UnsafeMutablePointer<VirtualMemoryManager>
    private let ppm : UnsafeMutablePointer<KernelPPM>

    private let rootTablePhysical: PhysicalPage
    private let asid             : ASID

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

        let nodeSize = UInt(MemoryLayout<VirtualMemoryArea>.stride)
        let nodeRaw: UnsafeMutableRawPointer?
        do {
            nodeRaw = try heap.pointee.kmalloc(nodeSize)

        } catch { throw .heapAllocationFailed(error) }

        guard let storage = nodeRaw else {
            throw .heapAllocationFailed(.metadataInconsistency)
        }

        let nodePtr = storage.initializeMemory(
            as       : VirtualMemoryArea.self,
            repeating: VirtualMemoryArea(
                startAddress: start,
                endAddress  : end,
                permissions : permissions,
                backingType : backing,
                mappingFlags: flags
            ),
            
            count: 1
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
            backingType : vmaPtr.pointee.backingType,
            mappingFlags: vmaPtr.pointee.mappingFlags,
            prev        : vmaPtr.pointee.prev,
            next        : vmaPtr.pointee.next
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
}
