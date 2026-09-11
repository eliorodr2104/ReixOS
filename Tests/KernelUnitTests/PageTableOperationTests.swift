//
//  PageTableOperationTests.swift
//  ReixOS
//

import Testing
@testable import Kernel
import KernelTestSupport
import KernelHostShims

/// The four leaf-descriptor operations, told apart by the order they emit and
/// by the state they refuse.
///
/// Ordering is the whole subject, and ordering has no return value: a kernel
/// that publishes a new frame before invalidating the old translation computes
/// the same descriptors as one that does it the other way round, and QEMU's
/// soft TLB never keeps the second translation that would show the difference.
/// So the shims are recorded rather than ignored, and every call also samples
/// the descriptor under test. `breakBeforeMake` is then observable off the
/// machine: the descriptor has to read invalid at the invalidation, and a
/// sequence that merely has the right calls in the right count fails here.
///
/// What this cannot see is inside a shim: `flush_tlb_page` is one host function
/// where the machine has four instructions. That half is checked on the linked
/// image by the `pte-bbm` post-check in `scripts/scenarios.sh`.
///
/// `.serialized`, and the run needs `--no-parallel`: the recorder is one global
/// in the shim object, as `TraceExportBatchTests`' barrier counter already was.
///
/// The refusals are named through `Refusals.swift`, the suite-wide helper, so a
/// new `PPMError` case has to be classified in one place.
@Suite("Page table operations", .serialized)
struct PageTableOperationTests {

    private static let va       : VirtualAddress   = UserSpaceLayout.elfBaseTypical
    private static let readWrite: VirtualPageFlags = [.present, .userAccess, .pxn, .uxn]
    private static let readOnly : VirtualPageFlags = [.present, .userAccess, .readOnly, .pxn, .uxn]
    private static let execute  : VirtualPageFlags = [.present, .userAccess, .pxn]


    // MARK: - Reading the recorder back

    /// The shims, in the op codes `KernelHostShims.h` assigns them.
    private enum Shim: UInt32 {
        case barrier       = 1
        case tlbPage       = 2
        case tlbPageNoSync = 3
        case tlbSync       = 4
        case tlbAll        = 5
        case isb           = 6
    }

    private static func ops() -> [Shim] {
        var result: [Shim] = []
        var index: UInt64 = 0

        while index < mmu_trace_length() {
            result.append(Shim(rawValue: mmu_trace_op(index)) ?? .tlbAll)
            index += 1
        }

        return result
    }

    // MARK: - Fixture

    /// The leaf slot for `va`, as the raw descriptor the recorder samples.
    private static func slot(
        _ ram: HostRAM,
        _ root: PhysicalAddress
    ) -> UnsafeMutablePointer<UInt64>? {
        guard let leaf = ram.vmm.pointee.leafTable(
            rootTable: root,
            virtual  : Self.va
        ) else { return nil }

        return UnsafeMutableRawPointer(leaf + Self.va.l3)
            .assumingMemoryBound(to: UInt64.self)
    }


    /// The flags the leaf descriptor for `va` carries.
    private static func flags(
        _ ram : HostRAM,
        _ root: PhysicalAddress
    ) -> VirtualPageFlags? {
        guard let leaf = ram.vmm.pointee.leafTable(
            rootTable: root,
            virtual  : Self.va
        ) else { return nil }

        return leaf[Self.va.l3].flags
    }


    /// One resident read-write page at `va`, every level above L3 already built.
    ///
    /// The levels matter: `mapTable` publishes each table it has to create, so a
    /// first install into an empty root emits barriers that belong to the walk
    /// and not to the operation. Building them here leaves each test's trace
    /// holding its own calls alone.
    private func withPage(
        _ body: (
            HostRAM,
            PhysicalAddress,
            PhysicalAddress,
            UnsafeMutablePointer<UInt64>
        ) -> Void
    ) {
        withProcessManager(pages: 160) { ram, _, _ in
            let root = ram.rootTablePhysical

            guard let frame = try? ram.ppm.pointee.alloc(4096) else {
                Issue.record("the arena gave no frame")
                return
            }

            let installed = refusal {
                try ram.vmm.pointee.installUserPage(
                    rootTable: root,
                    virtual  : Self.va,
                    physical : frame.address,
                    flags    : Self.readWrite,
                    type     : .normal
                )
            }

            guard installed == "none" else {
                Issue.record("the fixture install was refused: \(installed)")
                return
            }

            guard let slot = Self.slot(ram, root) else {
                Issue.record("no leaf table after the install")
                return
            }

            // The probe outlives nothing: the arena is freed when this returns.
            defer { mmu_trace_reset(nil) }

            body(ram, root, frame.address, slot)
        }
    }


    // MARK: - Install

    @Test("install publishes the descriptor and asks for no invalidation")
    func installPublishesWithoutInvalidating() {
        withPage { ram, root, frame, slot in
            ram.vmm.pointee.removeUserPage(rootTable: root, virtual: Self.va)

            mmu_trace_reset(slot)

            let error = refusal {
                try ram.vmm.pointee.installUserPage(
                    rootTable: root,
                    virtual  : Self.va,
                    physical : frame,
                    flags    : Self.readWrite,
                    type     : .normal
                )
            }

            #expect(error == "none")

            // One `dsb ishst` and nothing else. The missing invalidation is the
            // contract `removeUserPage` keeps, not an omission.
            #expect(Self.ops() == [.barrier])
            #expect(mmu_trace_descriptor(0) == slot.pointee)
            #expect(ram.translate(Self.va) == frame)

            // A user leaf that is not `nG` survives an address-space switch and
            // translates for whoever runs next.
            #expect(Self.flags(ram, root)?.contains(.notGlobal) == true)
        }
    }


    @Test("install refuses a valid descriptor and leaves everything alone")
    func installRefusesAValidDescriptor() {
        withPage { ram, root, _, slot in
            guard let other = try? ram.ppm.pointee.alloc(4096) else {
                Issue.record("the arena gave no second frame")
                return
            }

            let descriptor = slot.pointee
            let snapshot   = ram.pmmStateSnapshot()

            mmu_trace_reset(slot)

            let error = refusal {
                try ram.vmm.pointee.installUserPage(
                    rootTable: root,
                    virtual  : Self.va,
                    physical : other.address,
                    flags    : Self.readWrite,
                    type     : .normal
                )
            }

            #expect(error == "pageAlreadyMapped")

            // The refusal is decided before the walk creates anything, so the
            // snapshot covers the page tables as well as the frame metadata.
            #expect(slot.pointee == descriptor)
            #expect(ram.pmmStateSnapshot() == snapshot)
            #expect(mmu_trace_length() == 0)
        }
    }


    // MARK: - Protect

    @Test("protect rewrites the permissions in place and invalidates the address")
    func protectInvalidatesAfterTheStore() {
        withPage { ram, root, frame, slot in
            mmu_trace_reset(slot)

            let error = refusal {
                try ram.vmm.pointee.protectUserPage(
                    rootTable: root,
                    virtual  : Self.va,
                    flags    : Self.readOnly,
                    type     : .normal
                )
            }

            #expect(error == "none")
            #expect(Self.ops() == [.tlbPage])
            #expect(mmu_trace_arg(0) == Self.va)

            // Not break-before-make: the new descriptor is already standing when
            // the invalidation runs, which is what a permission change may do.
            #expect(mmu_trace_descriptor(0) == slot.pointee)

            #expect(ram.translate(Self.va) == frame)
            #expect(Self.flags(ram, root)?.contains(.readOnly)  == true)
            #expect(Self.flags(ram, root)?.contains(.notGlobal) == true)
        }
    }


    @Test("protect defers the invalidation when the caller batches it")
    func protectCanDeferTheInvalidation() {
        withPage { ram, root, _, slot in
            mmu_trace_reset(slot)

            let error = refusal {
                try ram.vmm.pointee.protectUserPage(
                    rootTable : root,
                    virtual   : Self.va,
                    flags     : Self.readOnly,
                    type      : .normal,
                    invalidate: false
                )
            }

            #expect(error == "none")

            // The clone's path: the descriptor is published, the invalidation is
            // the one `cloneRegions` runs at the end of the whole walk.
            #expect(Self.ops() == [.barrier])
        }
    }


    @Test("protect refuses a memory-type change and an absent descriptor")
    func protectRefusesWhatNeedsBreakBeforeMake() {
        withPage { ram, root, _, slot in
            let descriptor = slot.pointee

            mmu_trace_reset(slot)

            let typeChange = refusal {
                try ram.vmm.pointee.protectUserPage(
                    rootTable: root,
                    virtual  : Self.va,
                    flags    : Self.readWrite,
                    type     : .device
                )
            }

            #expect(typeChange == "pageAttributesImmutable")
            #expect(slot.pointee == descriptor)
            #expect(mmu_trace_length() == 0)

            ram.vmm.pointee.removeUserPage(rootTable: root, virtual: Self.va)

            mmu_trace_reset(slot)

            let absent = refusal {
                try ram.vmm.pointee.protectUserPage(
                    rootTable: root,
                    virtual  : Self.va,
                    flags    : Self.readWrite,
                    type     : .normal
                )
            }

            #expect(absent == "pageNotMapped")
            #expect(mmu_trace_length() == 0)
        }
    }


    @Test("protect that makes a page executable publishes the instruction stream")
    func protectPublishesNewlyExecutableCode() {
        withPage { ram, root, frame, _ in
            reset_instruction_cache_sync_record()

            let error = refusal {
                try ram.vmm.pointee.protectUserPage(
                    rootTable: root,
                    virtual  : Self.va,
                    flags    : Self.execute,
                    type     : .normal
                )
            }

            #expect(error == "none")

            // The bytes were written through the kernel's cached alias while the
            // page was writable and never executable, which is this path alone.
            #expect(instruction_cache_sync_calls() == 1)
            #expect(instruction_cache_synced_base() == frame)
            #expect(instruction_cache_synced_size() == UserSpaceLayout.pageSize)
        }
    }


    // MARK: - Replace

    @Test("replace breaks the translation before it makes the new one")
    func replaceBreaksBeforeMaking() {
        withPage { ram, root, _, slot in
            guard let fresh = try? ram.ppm.pointee.alloc(4096) else {
                Issue.record("the arena gave no second frame")
                return
            }

            mmu_trace_reset(slot)

            let error = refusal {
                try ram.vmm.pointee.replaceUserPage(
                    rootTable: root,
                    virtual  : Self.va,
                    physical : fresh.address,
                    flags    : Self.readWrite,
                    type     : .normal
                )
            }

            #expect(error == "none")
            #expect(Self.ops() == [.barrier, .tlbPageNoSync, .tlbSync, .barrier])
            #expect(mmu_trace_arg(1) == Self.va)

            // The window. The descriptor is invalid from the publication of the
            // break through the completion of the invalidation, and only then
            // carries the new frame: the whole ordering, in four samples.
            #expect(mmu_trace_descriptor(0) == 0)
            #expect(mmu_trace_descriptor(1) == 0)
            #expect(mmu_trace_descriptor(2) == 0)
            #expect(mmu_trace_descriptor(3) == slot.pointee)

            #expect(ram.translate(Self.va) == fresh.address)
            #expect(Self.flags(ram, root)?.contains(.notGlobal) == true)
        }
    }


    @Test("replace of a page that may be executed ends with an instruction barrier")
    func replaceOfExecutableCodeSynchronizesTheStream() {
        withPage { ram, root, _, slot in
            guard let fresh = try? ram.ppm.pointee.alloc(4096) else {
                Issue.record("the arena gave no second frame")
                return
            }

            mmu_trace_reset(slot)

            let error = refusal {
                try ram.vmm.pointee.replaceUserPage(
                    rootTable: root,
                    virtual  : Self.va,
                    physical : fresh.address,
                    flags    : Self.execute,
                    type     : .normal
                )
            }

            #expect(error == "none")
            #expect(Self.ops() == [.barrier, .tlbPageNoSync, .tlbSync, .barrier, .isb])
        }
    }


    @Test("replace refuses the frame already mapped and an absent descriptor")
    func replaceRefusesWhatIsNotAFrameChange() {
        withPage { ram, root, frame, slot in
            let descriptor = slot.pointee

            mmu_trace_reset(slot)

            let sameFrame = refusal {
                try ram.vmm.pointee.replaceUserPage(
                    rootTable: root,
                    virtual  : Self.va,
                    physical : frame,
                    flags    : Self.readOnly,
                    type     : .normal
                )
            }

            #expect(sameFrame == "pageReplaceWithoutChange")
            #expect(slot.pointee == descriptor)
            #expect(mmu_trace_length() == 0)

            ram.vmm.pointee.removeUserPage(rootTable: root, virtual: Self.va)

            mmu_trace_reset(slot)

            let absent = refusal {
                try ram.vmm.pointee.replaceUserPage(
                    rootTable: root,
                    virtual  : Self.va,
                    physical : frame,
                    flags    : Self.readWrite,
                    type     : .normal
                )
            }

            #expect(absent == "pageNotMapped")
            #expect(mmu_trace_length() == 0)
        }
    }


    // MARK: - Remove

    @Test("remove clears the descriptor and leaves the invalidation to the batch")
    func removeDefersTheInvalidation() {
        withPage { ram, root, _, slot in
            mmu_trace_reset(slot)

            #expect(ram.vmm.pointee.removeUserPage(rootTable: root, virtual: Self.va))

            // One `dsb ishst`. The invalidation belongs to `PageRetirement`'s
            // batch, which is also what has to run before the frame is released.
            #expect(Self.ops() == [.barrier])
            #expect(mmu_trace_descriptor(0) == 0)
            #expect(slot.pointee == 0)
            #expect(ram.translate(Self.va) == nil)

            mmu_trace_reset(slot)

            #expect(!ram.vmm.pointee.removeUserPage(rootTable: root, virtual: Self.va))
            #expect(mmu_trace_length() == 0)
        }
    }
}
