//
//  CopyOnWriteFaultTests.swift
//  ReixOS
//

import Testing
@testable import Kernel
import ReixABI
import KernelTestSupport

/// Copy-on-write on one core: what each fault kind is allowed to do to a cloned
/// region, and what the reference counts read afterwards.
///
/// Every permission fault used to reach the copy-on-write path, which then
/// refused the ones it could not serve. An instruction fetch on an NX page was
/// among them, and refusal by that route is indistinguishable from "not yet
/// resolved": the process was returned to the same unresolvable instruction for
/// as long as it was scheduled. The suite below pins the classification instead
/// of the refusal, so a fetch and a read never reach an allocator at all.
///
/// `.serialized`, and the run needs `--no-parallel`, for the reason
/// `ForkSpawnTests` states: `PPMBackend.physicalOffset` and `ProcessStatsIndex`
/// are global. `PPMFaultInjection` and `VMMFaultInjection` are global too, and
/// each test that arms one puts it back.
extension KernelPolicyTestRoot {
@Suite("Copy-on-write faults", .serialized)
struct CopyOnWriteFaultTests {

    /// A parent with one resident anonymous page, and a child cloned off it.
    ///
    /// The page is made resident through the translation fault itself, so the
    /// fixture starts from exactly the state a first touch leaves behind.
    private struct Fork {
        let parent  : UnsafeMutablePointer<Process>
        let child   : UnsafeMutablePointer<Process>
        let parentVMA: UnsafeMutablePointer<VMAManager>
        let childVMA : UnsafeMutablePointer<VMAManager>
        let address : VirtualAddress
        let shared  : PhysicalAddress
    }


    /// Builds the fixture, or records why it could not be built and answers
    /// `nil`.
    ///
    /// `permissions` is what the parent's region carries, so a caller can ask
    /// for the read-only region the clone declines to mark copy-on-write.
    private func fork(
        _ ram      : HostRAM,
        _ manager  : UnsafeMutablePointer<ProcessManager>,
        permissions: VMAPermissions = [.read, .write, .user],
        pattern    : UInt8 = 0x5A,
        clone      : Bool = true
    ) -> Fork? {

        guard let parent    = try? manager.pointee.spawnProcess(),
              let child     = try? manager.pointee.spawnProcess(),
              let parentVMA = parent.pointee.addressSpace.vmaManager,
              let childVMA  = child.pointee.addressSpace.vmaManager,
              let address   = try? parentVMA.pointee.mmapAnonymous(
                size       : UserSpaceLayout.pageSize,
                permissions: permissions
              )
        else {
            Issue.record("could not build the copy-on-write fixture")
            return nil
        }

        Arch.CPU.setCurrentProcess(UInt64(UInt(bitPattern: parent)))

        // The access the region grants, which a read-only fixture makes matter:
        // the first touch has to be one `serviceFault` will back.
        guard parentVMA.pointee.handlePageFault(
            at    : address,
            cause : .translation,
            access: permissions.contains(.write) ? .write : .read
        ) == .handled,
        let shared = ram.vmm.pointee.physicalAddressOf(
            rootTable: parent.pointee.addressSpace.rootTablePhysical,
            virtual  : address
        ) else {
            Issue.record("the parent's page was not materialised")
            return nil
        }

        let bytes: UnsafeMutablePointer<UInt8> = ram.vmm.pointee.physToVirt(shared)
        bytes.initialize(repeating: pattern, count: Int(UserSpaceLayout.pageSize))

        if clone {
            do { try childVMA.pointee.cloneRegions(from: parentVMA.pointee) }
            catch {
                Issue.record("clone failed: \(error)")
                return nil
            }
        }

        return Fork(
            parent   : parent,
            child    : child,
            parentVMA: parentVMA,
            childVMA : childVMA,
            address  : address,
            shared   : shared
        )
    }


    /// A process with one registered, still unbacked `.noReserve` region, and
    /// the address of its first page.
    ///
    /// Installed as the current process, because the fault paths read it.
    private func lazyRegion(
        _ manager  : UnsafeMutablePointer<ProcessManager>,
        permissions: VMAPermissions
    ) -> (UnsafeMutablePointer<VMAManager>, VirtualAddress)? {

        guard let process = try? manager.pointee.spawnProcess(),
              let vma     = process.pointee.addressSpace.vmaManager,
              let address = try? vma.pointee.mmapAnonymous(
                size       : UserSpaceLayout.pageSize,
                permissions: permissions
              )
        else {
            Issue.record("could not build the lazy-region fixture")
            return nil
        }

        Arch.CPU.setCurrentProcess(UInt64(UInt(bitPattern: process)))

        return (vma, address)
    }


    private func byte(
        _ ram    : HostRAM,
        at   phys: PhysicalAddress
    ) -> UInt8 {
        let bytes: UnsafeMutablePointer<UInt8> = ram.vmm.pointee.physToVirt(phys)
        return bytes[0]
    }


    // MARK: - The write that is allowed

    @Test("a write fault on a shared frame takes a private copy")
    func writeFaultCopies() {
        withProcessManager(pages: 160) { ram, _, manager in
            guard let fixture = fork(ram, manager) else { return }
            defer { Arch.CPU.setCurrentProcess(0) }

            #expect(ram.ppm.pointee.refCount(of: fixture.shared) == 2)
            #expect(!fixture.childVMA.pointee.isPageMapped(at: fixture.address, writable: true))

            Arch.CPU.setCurrentProcess(UInt64(UInt(bitPattern: fixture.child)))

            let outcome = fixture.childVMA.pointee.handlePageFault(
                at    : fixture.address,
                cause : .permission,
                access: .write
            )

            #expect(outcome == .handled)

            guard let copy = ram.vmm.pointee.physicalAddressOf(
                rootTable: fixture.child.pointee.addressSpace.rootTablePhysical,
                virtual  : fixture.address
            ) else {
                Issue.record("the child lost its mapping")
                return
            }

            #expect(copy != fixture.shared)
            #expect(fixture.childVMA.pointee.isPageMapped(at: fixture.address, writable: true))

            // The pattern survives on both sides, and the reference the clone
            // took for the child goes back with the mapping it belonged to.
            #expect(byte(ram, at: copy) == 0x5A)
            #expect(byte(ram, at: fixture.shared) == 0x5A)
            #expect(ram.ppm.pointee.refCount(of: fixture.shared) == 1)
            #expect(ram.ppm.pointee.refCount(of: copy) == 1)

            // Divergence: what one writes is not what the other reads.
            let copied: UnsafeMutablePointer<UInt8> = ram.vmm.pointee.physToVirt(copy)
            copied[0] = 0xA5
            #expect(byte(ram, at: fixture.shared) == 0x5A)

            // The parent is alone on the frame now, so its own write promotes
            // in place rather than copying again.
            Arch.CPU.setCurrentProcess(UInt64(UInt(bitPattern: fixture.parent)))
            let allocated = ram.ppm.pointee.allocatedPages

            #expect(fixture.parentVMA.pointee.handlePageFault(
                at    : fixture.address,
                cause : .permission,
                access: .write
            ) == .handled)

            #expect(ram.vmm.pointee.physicalAddressOf(
                rootTable: fixture.parent.pointee.addressSpace.rootTablePhysical,
                virtual  : fixture.address
            ) == fixture.shared)
            #expect(ram.ppm.pointee.allocatedPages == allocated)
        }
    }


    @Test("a write fault on a frame nobody else holds promotes in place")
    func writeFaultPromotes() {
        withProcessManager(pages: 128) { ram, _, manager in
            guard let fixture = fork(ram, manager, clone: false) else { return }
            defer { Arch.CPU.setCurrentProcess(0) }

            // The state a clone leaves behind once the other side is gone: the
            // region marked, the descriptor read-only, one reference left.
            guard let vma = fixture.parentVMA.pointee.vmaList.search(at: fixture.address) else {
                Issue.record("the region went missing")
                return
            }
            vma.pointee.mappingFlags.insert(.copyOnWrite)

            var readOnly = vma.pointee.permissions
            readOnly.remove(.write)

            try? ram.vmm.pointee.protectUserPage(
                rootTable: fixture.parent.pointee.addressSpace.rootTablePhysical,
                virtual  : fixture.address,
                flags    : readOnly.toPageFlags(),
                type     : .normal
            )

            #expect(!fixture.parentVMA.pointee.isPageMapped(at: fixture.address, writable: true))
            #expect(ram.ppm.pointee.refCount(of: fixture.shared) == 1)

            let allocated = ram.ppm.pointee.allocatedPages

            #expect(fixture.parentVMA.pointee.handlePageFault(
                at    : fixture.address,
                cause : .permission,
                access: .write
            ) == .handled)

            // Same frame, write bit back, nothing allocated to get there.
            #expect(ram.vmm.pointee.physicalAddressOf(
                rootTable: fixture.parent.pointee.addressSpace.rootTablePhysical,
                virtual  : fixture.address
            ) == fixture.shared)
            #expect(fixture.parentVMA.pointee.isPageMapped(at: fixture.address, writable: true))
            #expect(ram.ppm.pointee.allocatedPages == allocated)
            #expect(ram.ppm.pointee.refCount(of: fixture.shared) == 1)
        }
    }


    // MARK: - The faults that are refused

    @Test("an instruction fetch on an NX copy-on-write page is refused without allocating")
    func instructionFetchRefused() {
        withProcessManager(pages: 160) { ram, _, manager in
            guard let fixture = fork(ram, manager) else { return }
            defer { Arch.CPU.setCurrentProcess(0) }

            Arch.CPU.setCurrentProcess(UInt64(UInt(bitPattern: fixture.child)))

            let before = ram.pmmStateSnapshot()

            #expect(fixture.childVMA.pointee.handlePageFault(
                at    : fixture.address,
                cause : .permission,
                access: .instructionFetch
            ) == .refused)

            #expect(ram.pmmStateSnapshot() == before)
            #expect(ram.ppm.pointee.refCount(of: fixture.shared) == 2)
            #expect(ram.vmm.pointee.physicalAddressOf(
                rootTable: fixture.child.pointee.addressSpace.rootTablePhysical,
                virtual  : fixture.address
            ) == fixture.shared)
        }
    }


    @Test("a read permission fault is refused without allocating")
    func readFaultRefused() {
        withProcessManager(pages: 160) { ram, _, manager in
            guard let fixture = fork(ram, manager) else { return }
            defer { Arch.CPU.setCurrentProcess(0) }

            Arch.CPU.setCurrentProcess(UInt64(UInt(bitPattern: fixture.child)))

            let before = ram.pmmStateSnapshot()

            #expect(fixture.childVMA.pointee.handlePageFault(
                at    : fixture.address,
                cause : .permission,
                access: .read
            ) == .refused)

            #expect(ram.pmmStateSnapshot() == before)
        }
    }


    @Test("a write fault on a region without write is refused without allocating")
    func writeFaultOnReadOnlyRegionRefused() {
        withProcessManager(pages: 160) { ram, _, manager in
            guard let fixture = fork(
                ram, manager,
                permissions: [.read, .user]
            ) else { return }
            defer { Arch.CPU.setCurrentProcess(0) }

            // The flag goes on by hand, so what refuses this write is the
            // region's own permissions and not the absence of the mark.
            guard let region = fixture.childVMA.pointee.vmaList.search(at: fixture.address) else {
                Issue.record("the region went missing")
                return
            }
            #expect(!region.pointee.mappingFlags.contains(.copyOnWrite))
            region.pointee.mappingFlags.insert(.copyOnWrite)

            #expect(ram.ppm.pointee.refCount(of: fixture.shared) == 2)

            Arch.CPU.setCurrentProcess(UInt64(UInt(bitPattern: fixture.child)))

            let before = ram.pmmStateSnapshot()

            #expect(fixture.childVMA.pointee.handlePageFault(
                at    : fixture.address,
                cause : .permission,
                access: .write
            ) == .refused)

            #expect(ram.pmmStateSnapshot() == before)
        }
    }


    @Test("a fetch into a lazily backed NX region is refused without allocating")
    func lazyInstructionFetchRefused() {
        withProcessManager(pages: 128) { ram, _, manager in
            guard let (vma, address) = lazyRegion(
                manager,
                permissions: [.read, .write, .user]
            ) else { return }
            defer { Arch.CPU.setCurrentProcess(0) }

            let before = ram.pmmStateSnapshot()

            // A translation fault, so nothing is mapped yet and only the
            // region's own rights can say this fetch will never be served.
            #expect(vma.pointee.handlePageFault(
                at    : address,
                cause : .translation,
                access: .instructionFetch
            ) == .refused)

            #expect(ram.pmmStateSnapshot() == before)
            #expect(!vma.pointee.isPageMapped(at: address))
        }
    }


    @Test("a store into a lazily backed read-only region is refused without allocating")
    func lazyWriteRefused() {
        withProcessManager(pages: 128) { ram, _, manager in
            guard let (vma, address) = lazyRegion(
                manager,
                permissions: [.read, .user]
            ) else { return }
            defer { Arch.CPU.setCurrentProcess(0) }

            let before = ram.pmmStateSnapshot()

            #expect(vma.pointee.handlePageFault(
                at    : address,
                cause : .translation,
                access: .write
            ) == .refused)

            #expect(ram.pmmStateSnapshot() == before)
            #expect(!vma.pointee.isPageMapped(at: address))

            // The read the region does grant is still served, so the refusal
            // above is about the access and not about the region.
            #expect(vma.pointee.handlePageFault(
                at    : address,
                cause : .translation,
                access: .read
            ) == .handled)
        }
    }


    @Test("a fetch below the stack is refused without growing it")
    func stackGrowthFetchRefused() {
        withProcessManager(pages: 128) { ram, _, manager in
            guard let process = try? manager.pointee.spawnProcess(),
                  let vma     = process.pointee.addressSpace.vmaManager
            else {
                Issue.record("could not build the stack fixture")
                return
            }

            Arch.CPU.setCurrentProcess(UInt64(UInt(bitPattern: process)))
            defer { Arch.CPU.setCurrentProcess(0) }

            let stackStart = UserSpaceLayout.stackTop - UserSpaceLayout.pageSize
            do {
                try vma.pointee.registerRegion(
                    start      : stackStart,
                    size       : UserSpaceLayout.pageSize,
                    permissions: [.read, .write, .user],
                    backing    : .anonymous,
                    flags      : .growDown,
                    memoryType : .normal
                )
            } catch {
                Issue.record("could not register the grow-down fixture: \(error)")
                return
            }

            let below  = stackStart - UserSpaceLayout.pageSize
            let before = ram.pmmStateSnapshot()

            // The other road to `materialize`. A stack is never executable, so
            // growing it for a fetch backs a page the retry cannot use.
            #expect(vma.pointee.handlePageFault(
                at    : below,
                cause : .translation,
                access: .instructionFetch
            ) == .refused)

            #expect(ram.pmmStateSnapshot() == before)
            #expect(!vma.pointee.isPageMapped(at: below))

            // The store the stack is there for still grows it.
            #expect(vma.pointee.handlePageFault(
                at    : below,
                cause : .translation,
                access: .write
            ) == .handled)
            #expect(vma.pointee.isPageMapped(at: below, writable: true))
        }
    }


    // MARK: - Memory pressure

    @Test("a copy with no frame to take leaves the mapping and the counts alone")
    func copyOutOfMemory() {
        withProcessManager(pages: 160) { ram, _, manager in
            guard let fixture = fork(ram, manager) else { return }
            defer { Arch.CPU.setCurrentProcess(0) }

            Arch.CPU.setCurrentProcess(UInt64(UInt(bitPattern: fixture.child)))

            let before = ram.pmmStateSnapshot()

            PPMFaultInjection.failAllocationsAfter = 0
            defer { PPMFaultInjection.failAllocationsAfter = nil }

            #expect(fixture.childVMA.pointee.handlePageFault(
                at    : fixture.address,
                cause : .permission,
                access: .write
            ) == .outOfMemory)

            #expect(ram.pmmStateSnapshot() == before)
            #expect(ram.ppm.pointee.refCount(of: fixture.shared) == 2)
            #expect(ram.vmm.pointee.physicalAddressOf(
                rootTable: fixture.child.pointee.addressSpace.rootTablePhysical,
                virtual  : fixture.address
            ) == fixture.shared)
            #expect(!fixture.childVMA.pointee.isPageMapped(at: fixture.address, writable: true))
        }
    }


    @Test("a map that throws after the copy gives the new frame back")
    func replaceFailureFreesTheCopy() {
        withProcessManager(pages: 160) { ram, _, manager in
            guard let fixture = fork(ram, manager) else { return }
            defer { Arch.CPU.setCurrentProcess(0) }

            Arch.CPU.setCurrentProcess(UInt64(UInt(bitPattern: fixture.child)))

            let allocated = ram.ppm.pointee.allocatedPages

            VMMFaultInjection.failReplaces = true

            let outcome = fixture.childVMA.pointee.handlePageFault(
                at    : fixture.address,
                cause : .permission,
                access: .write
            )

            VMMFaultInjection.failReplaces = false

            #expect(outcome == .outOfMemory)

            // The frame the copy took is back with the allocator, and the
            // shared one still carries both references.
            #expect(ram.ppm.pointee.allocatedPages == allocated)
            #expect(ram.ppm.pointee.refCount(of: fixture.shared) == 2)
            #expect(ram.vmm.pointee.physicalAddressOf(
                rootTable: fixture.child.pointee.addressSpace.rootTablePhysical,
                virtual  : fixture.address
            ) == fixture.shared)
        }
    }


    // MARK: - Both teardown orders

    @Test("the child dying first leaves the parent alone on its frame")
    func childFirstTeardown() {
        withProcessManager(pages: 160) { ram, _, manager in
            guard let fixture = fork(ram, manager) else { return }
            defer { Arch.CPU.setCurrentProcess(0) }

            Arch.CPU.setCurrentProcess(UInt64(UInt(bitPattern: fixture.child)))
            #expect(fixture.childVMA.pointee.handlePageFault(
                at    : fixture.address,
                cause : .permission,
                access: .write
            ) == .handled)

            guard let copy = ram.vmm.pointee.physicalAddressOf(
                rootTable: fixture.child.pointee.addressSpace.rootTablePhysical,
                virtual  : fixture.address
            ) else {
                Issue.record("the child lost its mapping")
                return
            }

            Arch.CPU.setCurrentProcess(UInt64(UInt(bitPattern: fixture.parent)))
            try? manager.pointee.releaseAddressSpace(fixture.child)

            #expect(ram.ppm.pointee.refCount(of: copy) == 0)
            #expect(ram.ppm.pointee.refCount(of: fixture.shared) == 1)

            // Alone on the frame, so the parent's next write is a promotion.
            let allocated = ram.ppm.pointee.allocatedPages
            #expect(fixture.parentVMA.pointee.handlePageFault(
                at    : fixture.address,
                cause : .permission,
                access: .write
            ) == .handled)
            #expect(ram.ppm.pointee.allocatedPages == allocated)

            try? manager.pointee.releaseAddressSpace(fixture.parent)
            #expect(ram.ppm.pointee.refCount(of: fixture.shared) == 0)
        }
    }


    @Test("the parent dying first leaves the child alone on its frame")
    func parentFirstTeardown() {
        withProcessManager(pages: 160) { ram, _, manager in
            guard let fixture = fork(ram, manager) else { return }
            defer { Arch.CPU.setCurrentProcess(0) }

            // The parent copies this time, so the child is the one left holding
            // the frame both of them started on.
            Arch.CPU.setCurrentProcess(UInt64(UInt(bitPattern: fixture.parent)))
            #expect(fixture.parentVMA.pointee.handlePageFault(
                at    : fixture.address,
                cause : .permission,
                access: .write
            ) == .handled)

            guard let copy = ram.vmm.pointee.physicalAddressOf(
                rootTable: fixture.parent.pointee.addressSpace.rootTablePhysical,
                virtual  : fixture.address
            ) else {
                Issue.record("the parent lost its mapping")
                return
            }
            #expect(copy != fixture.shared)

            Arch.CPU.setCurrentProcess(UInt64(UInt(bitPattern: fixture.child)))
            try? manager.pointee.releaseAddressSpace(fixture.parent)

            #expect(ram.ppm.pointee.refCount(of: copy) == 0)
            #expect(ram.ppm.pointee.refCount(of: fixture.shared) == 1)
            #expect(byte(ram, at: fixture.shared) == 0x5A)

            let allocated = ram.ppm.pointee.allocatedPages
            #expect(fixture.childVMA.pointee.handlePageFault(
                at    : fixture.address,
                cause : .permission,
                access: .write
            ) == .handled)
            #expect(ram.ppm.pointee.allocatedPages == allocated)
            #expect(ram.vmm.pointee.physicalAddressOf(
                rootTable: fixture.child.pointee.addressSpace.rootTablePhysical,
                virtual  : fixture.address
            ) == fixture.shared)

            try? manager.pointee.releaseAddressSpace(fixture.child)
            #expect(ram.ppm.pointee.refCount(of: fixture.shared) == 0)
        }
    }


    @Test("three generations count to three, and the middle one may die first")
    func threeGenerations() {
        withProcessManager(pages: 200) { ram, _, manager in
            guard let fixture = fork(ram, manager) else { return }
            defer { Arch.CPU.setCurrentProcess(0) }

            guard let grandchild = try? manager.pointee.spawnProcess(),
                  let grandVMA   = grandchild.pointee.addressSpace.vmaManager
            else {
                Issue.record("could not spawn the third generation")
                return
            }

            do { try grandVMA.pointee.cloneRegions(from: fixture.childVMA.pointee) }
            catch {
                Issue.record("the second clone failed: \(error)")
                return
            }

            #expect(ram.ppm.pointee.refCount(of: fixture.shared) == 3)

            // The middle generation goes, and the frame is back to the two
            // that still map it.
            Arch.CPU.setCurrentProcess(UInt64(UInt(bitPattern: fixture.parent)))
            try? manager.pointee.releaseAddressSpace(fixture.child)
            #expect(ram.ppm.pointee.refCount(of: fixture.shared) == 2)

            // Two holders left, so this write still copies.
            #expect(fixture.parentVMA.pointee.handlePageFault(
                at    : fixture.address,
                cause : .permission,
                access: .write
            ) == .handled)
            #expect(ram.ppm.pointee.refCount(of: fixture.shared) == 1)

            // And the last holder promotes.
            Arch.CPU.setCurrentProcess(UInt64(UInt(bitPattern: grandchild)))
            let allocated = ram.ppm.pointee.allocatedPages
            #expect(grandVMA.pointee.handlePageFault(
                at    : fixture.address,
                cause : .permission,
                access: .write
            ) == .handled)
            #expect(ram.ppm.pointee.allocatedPages == allocated)
            #expect(ram.vmm.pointee.physicalAddressOf(
                rootTable: grandchild.pointee.addressSpace.rootTablePhysical,
                virtual  : fixture.address
            ) == fixture.shared)

            try? manager.pointee.releaseAddressSpace(fixture.parent)
            try? manager.pointee.releaseAddressSpace(grandchild)
            #expect(ram.ppm.pointee.refCount(of: fixture.shared) == 0)
        }
    }
}
}
