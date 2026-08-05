//
//  VMAManager.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 10/05/2026.
//

/// Per-address-space owner of the Virtual Memory Areas.
///
/// One instance per process is allocated by `ProcessManager` right after the VMM
/// returns a fresh address space. The manager keeps the VMA list, services
/// page-fault decisions, grows the user stack on demand and walks the page tables
/// on teardown to release every frame the process touched.
///
/// All dependencies (kernel heap, VMM, PPM) and the root page table physical
/// reference are injected at construction time so the type is free of static
/// facades.
///
/// The state below is `internal` rather than `private` because the type is split
/// across the files of this folder, which is what keeps each of them readable.
/// Nothing outside `VMAManager` and the operations it drives touches it.
public struct VMAManager: RXAllocatable {

    public static var errorMessageAllocation: StaticString = "Failed to allocate VMAManager on the kernel heap"

    var vmaList: LinkedList<VirtualMemoryArea> // 40 Byte (All ptr 8 Bytes var)

    /// Current program break for the brk-style heap. Set once by
    /// `setInitialBreak` at spawn time, then bumped by `extendBreak`.
    public var currentBreak: VirtualAddress = 0 // 8 Byte

    /// Pages with a live translation in this address space.
    ///
    /// Resident means mapped here, not owned here: a shared or device page is
    /// counted by every address space it appears in, because the number answers
    /// what this process can touch without faulting and not how much of RAM it
    /// is responsible for. Summing it across processes therefore double counts
    /// on purpose, and `SystemStats` reports the physical side separately.
    ///
    /// `UInt32` covers 16 TiB of mappings, which the 39-bit user window cannot
    /// reach, and keeps the counter inside the word next to `currentBreak`.
    public private(set) var residentPages: UInt32 = 0 // 4 Byte

    let heap: UnsafeMutablePointer<BucketsHeap> // 8 Byte

    /// The page tables and the frame allocator of this address space, read once
    /// and handed to every operation the manager drives.
    let context: PagingContext // 24 Byte

    /// Cached pointer to the single VMA covering the brk heap, if any.
    /// `nil` until the first successful `extendBreak`.
    var brkVMA: UnsafeMutablePointer<VirtualMemoryArea>? = nil // 8 Byte

    /// A `decommit` that a checkpoint abandoned, waiting for the syscall to be
    /// re-entered and finished.
    ///
    /// Parked on the manager and not on `Process` because the state is entirely
    /// about this address space. See `AddressSpaceTeardown` in `PreemptionRegion`
    /// for why the dying address space is the one retirement region that may
    /// never park.
    var suspendedDecommit: SuspendedDecommit? = nil

    /// A `munmapRegion` that a checkpoint abandoned, waiting for the syscall to
    /// be re-entered and finished.
    ///
    /// A separate field from `suspendedDecommit` because the two carry different
    /// operations: the decommit's leaves every VMA registered and this one
    /// unlinks and frees them as it goes. Only `rollbackMapping` cannot leave one
    /// behind, structurally rather than by convention: see `RegionUnmapRollback`.
    var suspendedUnmap: SuspendedUnmap? = nil


    public init(
        heap             : UnsafeMutablePointer<BucketsHeap>,
        vmm              : UnsafeMutablePointer<VirtualMemoryManager>,
        ppm              : UnsafeMutablePointer<KernelPPM>,
        rootTablePhysical: PhysicalAddress
    ) {
        self.heap    = heap
        self.context = PagingContext(
            vmm              : vmm,
            ppm              : ppm,
            rootTablePhysical: rootTablePhysical
        )
        self.vmaList = LinkedList(
            head      : nil,
            tail      : nil,
            minAddress: UserSpaceLayout.userMin,
            maxAddress: UserSpaceLayout.userMax
        )
    }


    /// Seed the program break value used by `extendBreak`. Called by
    /// `ProcessManager.spawnProcess` once the ELF image is loaded, with the first
    /// page-aligned address above the ELF end.
    public mutating func setInitialBreak(_ value: VirtualAddress) {
        self.currentBreak = value
    }


    /// Query the current program break.
    public func programBreak() -> VirtualAddress {
        return currentBreak
    }


    /// Decide whether the half-open range `[start, end)` is fully covered by VMAs
    /// that grant `permissions`. Used by the syscall validation layer
    /// (`UserMemory.validateRegion`) to refuse buffers that fall on unmapped
    /// pages or violate access rights.
    public func contains(
        start      : VirtualAddress,
        end        : VirtualAddress,
        permissions: VMAPermissions
    ) -> Bool {

        guard end > start else { return false }
        guard start >= UserSpaceLayout.userMin,
              end   <= UserSpaceLayout.userMax
        else { return false }

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


    /// `true` when `virtual` already has a live leaf entry in this address space's
    /// page tables.
    ///
    /// The syscall validation layer needs this probe but holds no
    /// `VirtualMemoryManager` handle, the instance is private to `Kernel` and only
    /// ever injected into `ProcessManager` and here, so it is reached through the
    /// VMA manager, which already owns both the handle and the root table the
    /// probe must be relative to.
    public func isPageMapped(at virtual: VirtualAddress) -> Bool {
        guard let leafTable = context.vmm.pointee.leafTable(
            rootTable: context.rootTablePhysical,
            virtual  : virtual
        ) else { return false }

        return leafTable[virtual.l3].isPresent
    }


    /// The page range `[addr, addr + size)` describes, `nil` when the request is
    /// not one this address space can act on: empty, unaligned, or outside the
    /// user window.
    ///
    /// Shared by `decommit` and `unmapRange`, whose first move is the same
    /// refusal, and taken before either looks at the VMA list.
    static func validatedRange(
        addr: VirtualAddress,
        size: UInt64
    ) -> (start: VirtualAddress, end: VirtualAddress)? {

        guard size > 0 else { return nil }

        guard addr & (UserSpaceLayout.pageSize - 1) == 0 else { return nil }

        return UserSpaceLayout.checkedPageRange(
            address: addr,
            size   : size
        )
    }


    // MARK: - The surface the resumable operations reach the manager through

    /// This manager's own address, for the operations that mutate its state.
    ///
    /// A `VMAManager` is `kmalloc`ed once by `ProcessManager` and reached only
    /// ever as `addressSpace.vmaManager!.pointee`, so it never moves and this is
    /// that same heap cell rather than a temporary: the `inout self` of a mutating
    /// method called through `UnsafeMutablePointer.pointee` is the cell itself.
    /// Every run rebinds the operation to a freshly taken pointer all the same, so
    /// a parked continuation never depends on one an earlier entry took.
    mutating func managerPointer() -> UnsafeMutablePointer<VMAManager> {
        withUnsafeMutablePointer(to: &self) { $0 }
    }


    /// Record `count` pages this address space has just had mapped into it.
    ///
    /// A funnel rather than a settable property, so the two directions are named
    /// at every site and the clamp below has one place to live.
    mutating func noteMapped(_ count: UInt32) {
        residentPages &+= count
    }


    /// Record `count` pages whose translation has just been dropped.
    ///
    /// Clamped at zero rather than wrapping: the count is a report, and an
    /// underflow would show a process holding four billion pages for the rest of
    /// its life. A miscount is a bug worth finding, and 0 is where it shows.
    mutating func noteRetired(_ count: UInt32) {
        residentPages = count >= residentPages ? 0 : residentPages &- count
    }


    /// Declare nothing resident any more, for the teardown that is taking the
    /// whole address space down rather than a range of it.
    mutating func resetResidentPages() {
        residentPages = 0
    }


    /// Recount from the page tables what the manager did not map itself.
    ///
    /// The spawn path maps the ELF image and the first stack page through the
    /// VMM directly, so the only honest count after it is an observed one. Every
    /// mapped page lies inside a registered region by construction, which is
    /// what bounds this walk to the image and not to the address space.
    public mutating func recountResidentPages() {
        var total  : UInt32 = 0
        var current = vmaList.head

        while let nodePtr = current {
            let node = nodePtr.pointee

            var va = node.startAddress
            while va < node.endAddress {
                if isPageMapped(at: va) { total &+= 1 }

                va += UserSpaceLayout.pageSize
            }

            current = node.next
        }

        residentPages = total
    }


    /// Unlink `node` and free it, once the pages it covered are gone.
    ///
    /// The caller must read `node.pointee.next` *before* this: `kfree` threads the
    /// heap's free list through the block's first word, which is `startAddress`,
    /// so every link of a freed node is unreadable afterwards.
    mutating func unregister(_ node: UnsafeMutablePointer<VirtualMemoryArea>) {
        if brkVMA == node { brkVMA = nil }

        vmaList.remove(element: node)
        heap.pointee.kfree(node)
    }


    /// Register the child's copy of a parent region during a clone, pointing the
    /// brk cache at it when it is the parent's brk region.
    ///
    /// The cache is re-read from the list and not kept from the value that went
    /// in, because `registerRegion` may merge the new node with a neighbour.
    mutating func adoptClonedRegion(
        of          vma: VirtualMemoryArea,
        flags          : MappingFlags,
        isBrkRegion    : Bool
    ) throws(VMAError) {

        try registerRegion(
            start      : vma.startAddress,
            size       : vma.endAddress - vma.startAddress,
            permissions: vma.permissions,
            backing    : vma.backingType,
            flags      : flags
        )

        if isBrkRegion { brkVMA = vmaList.search(at: vma.startAddress) }
    }
}
