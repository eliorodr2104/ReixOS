//
//  RegionClone.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 04/08/2026.
//

/// `VMAManager.cloneRegions`, cut into steps so the interrupt window has
/// somewhere to open inside it.
///
/// One run spans the whole clone, both the parent's VMA list and the pages of
/// each region, because a run per region measured 72 µs of work while masking
/// 20 ms of it.
///
/// The only fallible operation of the four, so `Failure` is `VMAError`. There is
/// no infallible phase to isolate the way `decommit` isolates its pass B: the
/// allocation that fails may be the one for the last region of the list.
///
/// ## What a step is
///
/// Either the prologue of a region, which registers the child's copy and marks
/// both sides copy on write, or one batch of up to `pagesPerCloneStep` pages of
/// it. The prologue is a step of its own so the fallible allocation and the page
/// work are never in the same one.
///
/// A batch never crosses a leaf-table boundary, see `spanEnd`, and the parent's
/// L3 table is resolved again at the start of every batch instead of being
/// carried across the checkpoint: caching it would be sound but would be an
/// invariant this type has to keep true, against a few reads per 32 pages.
///
/// ## What a step boundary leaves
///
/// A child that is fully destroyable, which is the whole requirement: every exit
/// from `SplitProcessSyscall` that is not success runs `discard`, and the child's
/// `teardown` has to undo exactly what has been done so far. Two invariants hold
/// at every boundary:
///
/// An anonymous page is retained and mapped into the child in the same step, and
/// never in different ones, so the child's descriptors and the references it
/// holds are in step. `teardown` then releases exactly one reference per
/// anonymous page it finds mapped. A non-anonymous page is mapped and never
/// retained, see `cloneBatch`.
///
/// A region is registered before any of its pages are mapped, never after. A
/// registered region whose pages are not there yet is retired by a walk that
/// probes each page, finds no descriptor and releases nothing.
///
/// The parent is left with some of its pages read-only and `.copyOnWrite` set on
/// the region, which is the state a throwing exit has always left it in: the
/// first write faults, `serviceFault` finds the frame's reference count back at
/// one and restores the write permission in place.
struct RegionClone: ResumableOperation {

    typealias Failure = VMAError

    /// Where the child's VMA list and brk cache are. See
    /// `VMAManager.managerPointer` for why an operation that has to register
    /// regions holds the manager.
    private let manager: UnsafeMutablePointer<VMAManager>

    /// The child's page tables and frame allocator.
    private let context: PagingContext

    /// The parent's root table. Read for every page and written for the
    /// copy-on-write ones, which is the whole of this operation's business with
    /// the parent's address space besides the list it walks.
    private let parentRoot: PhysicalAddress

    /// The parent's brk region, so the step that registers its copy can point the
    /// child's cache at it.
    private let parentBrk: UnsafeMutablePointer<VirtualMemoryArea>?

    /// The parent VMA being cloned, `nil` once the walk is over.
    private var node: UnsafeMutablePointer<VirtualMemoryArea>?

    /// First address of `node` whose page has not been cloned yet, valid only
    /// once `registered` is `true`.
    private var cursor: VirtualAddress

    /// Whether the child's copy of `node` is already on the child's list.
    private var registered: Bool

    /// Pages one step examines.
    ///
    /// Deliberately not `PageRetirement.pagesPerBatch` under a second name: that
    /// one is pinned to an `InlineArray` width and cannot move alone, while this
    /// answers to nothing but the budget in `CheckpointPolicy`.
    private static let pagesPerCloneStep: UInt64 = 32

    private static let leafTableSpan: UInt64 = 512 * UserSpaceLayout.pageSize


    /// - Parameter first: the head of the parent's VMA list. The walk goes
    ///   forward from it and covers all of it, so a `nil` head is a clone with
    ///   nothing to do.
    init(
        manager   : UnsafeMutablePointer<VMAManager>,
        context   : PagingContext,
        parentRoot: PhysicalAddress,
        parentBrk : UnsafeMutablePointer<VirtualMemoryArea>?,
        from first: UnsafeMutablePointer<VirtualMemoryArea>?
    ) {
        self.manager    = manager
        self.context    = context
        self.parentRoot = parentRoot
        self.parentBrk  = parentBrk
        self.node       = first
        self.cursor     = 0
        self.registered = false
    }


    mutating func step() throws(VMAError) -> Progress {
        guard let nodePtr = node else { return .done }

        guard registered else {
            try register(nodePtr)

            return .more
        }

        let vma = nodePtr.pointee

        cursor = try cloneBatch(of: vma)

        guard cursor >= vma.endAddress else { return .more }

        node       = vma.next
        registered = false

        return node == nil ? .done : .more
    }


    /// Give the child its own VMA over the same range, and put both sides of a
    /// writable anonymous region on the copy-on-write path.
    ///
    /// The parent's node is edited before the child's is registered, as it always
    /// was: `registerRegion` may merge the new node with a neighbour, so the
    /// flags have to be settled on the value that goes in.
    private mutating func register(
        _ nodePtr: UnsafeMutablePointer<VirtualMemoryArea>
    ) throws(VMAError) {

        let vma = nodePtr.pointee

        let isSharedBacking = (vma.backingType != .anonymous)
        let isWritable      = vma.permissions.contains(.write)

        var childMappingFlags = vma.mappingFlags
        if !isSharedBacking && isWritable {
            nodePtr.pointee.mappingFlags.insert(.copyOnWrite)
            childMappingFlags.insert(.copyOnWrite)
        }

        try manager.pointee.adoptClonedRegion(
            of         : vma,
            flags      : childMappingFlags,
            isBrkRegion: nodePtr == parentBrk
        )

        cursor     = vma.startAddress
        registered = true
    }


    /// Share or copy one batch of `vma`'s resident pages, and answer where the
    /// next step picks up.
    ///
    /// An anonymous writable region is mapped read-only into both processes and
    /// its frame retained, so the first write on either side faults and takes a
    /// private copy. `.shared` and `.device` regions are mapped through with
    /// their own permissions, because their frames belong to the `SharedRegion`
    /// behind the capability or to MMIO the PPM never owned.
    ///
    /// ## Only an anonymous frame is retained here
    ///
    /// Every reference taken here has to be given back by the child's `teardown`,
    /// and `PageRetirement.retire` releases nothing for a backing that is not
    /// `.anonymous`. `childOwnsFrameReference` is the exact complement of that
    /// guard, so retains and releases balance per mapping, and the compensating
    /// `release` on the failed-map path is under the same gate: releasing a frame
    /// this never retained would drop a reference somebody else holds.
    ///
    /// Retaining unconditionally cost one permanently leaked reference per shared
    /// page per fork, which pinned the console ring of every process forever, and
    /// made a process holding a device window unforkable outright: `retain`
    /// rejects an MMIO address, so the whole clone threw. Do not put it back.
    private func cloneBatch(of vma: VirtualMemoryArea) throws(VMAError) -> VirtualAddress {

        let vmm = context.vmm
        let ppm = context.ppm

        let spanEnd = Self.spanEnd(
            from : cursor,
            limit: vma.endAddress
        )

        // No leaf table means no resident page in the whole 2 MiB, so the span
        // is skipped for the cost of the descent that found it absent.
        guard let parentLeaf = vmm.pointee.leafTable(
            rootTable: parentRoot,
            virtual  : cursor
        ) else { return spanEnd }

        let batchEnd = Self.batchEnd(
            from : cursor,
            limit: spanEnd
        )

        let isSharedBacking = (vma.backingType != .anonymous)
        let isWritable      = vma.permissions.contains(.write)

        // Complement of `PageRetirement.retire`'s own guard, so every reference
        // taken below is one the child's teardown will give back.
        let childOwnsFrameReference = !isSharedBacking

        var va = cursor
        while va < batchEnd {

            let parentEntry = parentLeaf[va.l3]

            guard parentEntry.isPresent else {
                va += UserSpaceLayout.pageSize
                continue
            }

            let parentPhys = parentEntry.physicalAddress

            let pageFlags                 : VirtualPageFlags
            let downgradeParentPermissions: Bool

            if isSharedBacking {
                pageFlags                  = vma.permissions.toPageFlags()
                downgradeParentPermissions = false

            } else if isWritable {
                var permissionsNotWritable = vma.permissions

                permissionsNotWritable.remove(.write)

                pageFlags                  = permissionsNotWritable.toPageFlags()
                downgradeParentPermissions = true

            } else {
                pageFlags                  = vma.permissions.toPageFlags()
                downgradeParentPermissions = false
            }

            if childOwnsFrameReference {
                do {
                    try ppm.pointee.retain(parentPhys)
                } catch {
                    throw .mappingFailed(error)
                }
            }

            do {
                try vmm.pointee.mapUserPage(
                    rootTable: context.rootTablePhysical,
                    virtual  : va,
                    physical : parentPhys,
                    flags    : pageFlags
                )

                manager.pointee.noteMapped(1)

                // Writable in the parent's TLB until the deferred flush.
                // Safe only while the parent cannot run before we return.
                if downgradeParentPermissions {
                    try vmm.pointee.mapUserPage(
                        rootTable: parentRoot,
                        virtual  : va,
                        physical : parentPhys,
                        flags    : pageFlags
                    )
                }

            } catch {
                // Same gate as the retain above, and it has to stay the same
                // one: undo only a reference this batch actually took.
                if childOwnsFrameReference {
                    try? ppm.pointee.release(parentPhys)
                }

                throw .mappingFailed(error)
            }

            va += UserSpaceLayout.pageSize
        }

        return batchEnd
    }


    /// End of the 2 MiB leaf-table span `cursor` falls in, never past `limit`.
    ///
    /// A batch may not cross this boundary, because it resolves the parent's L3
    /// table once and then indexes it with `va.l3`: one page further and it would
    /// be writing the wrong span's descriptors. It is also how a span with no
    /// leaf table at all is skipped whole, 512 pages for one descent, the common
    /// case for the sparse `noReserve` and `growDown` regions.
    private static func spanEnd(
        from cursor: VirtualAddress,
        limit      : VirtualAddress
    ) -> VirtualAddress {
        let end = (cursor & ~(leafTableSpan - 1)) + leafTableSpan

        return end > limit ? limit : end
    }


    /// End of the batch a step starting at `cursor` covers, never past `limit`.
    private static func batchEnd(
        from cursor: VirtualAddress,
        limit      : VirtualAddress
    ) -> VirtualAddress {
        let end = cursor + pagesPerCloneStep * UserSpaceLayout.pageSize

        return end > limit ? limit : end
    }
}
