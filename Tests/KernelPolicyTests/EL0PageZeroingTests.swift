//
//  EL0PageZeroingTests.swift
//  ReixOS
//

import Testing
@testable import Kernel
import ReixABI
import KernelTestSupport

/// Every anonymous frame is scrubbed before a user PTE can expose it.
///
/// The fixture allocates every available order-0 frame, fills it with a secret,
/// and returns it to the real buddy/PPM pair. The buddy overwrites a few bytes
/// with its intrusive free-list nodes; the rest of every frame stays poisoned.
/// Each assertion also proves that the observed mapping came from that recycled
/// set, so an allocator that happened to supply fresh host memory cannot make the
/// zero oracle pass accidentally.
extension KernelPolicyTestRoot {
@Suite("EL0 page zeroing", .serialized)
struct EL0PageZeroingTests {

    private static let poison: UInt8 = 0xA5
    private static let pageSize = Int(UserSpaceLayout.pageSize)


    @Test("the boot loader exposes a completely zeroed first stack page")
    func bootStackIsZeroed() {
        let image = makeELFImage([
            ELFSegmentFixture(
                flags     : 0x5,
                virtual   : UserSpaceLayout.elfBaseTypical,
                memorySize: UserSpaceLayout.pageSize,
                payload   : [0x00, 0x00, 0x20, 0xD4]
            )
        ])
        let archive = makeTarArchive(name: "ZeroProbe.elf", contents: image)

        let staged: Void? = withStagedTarArchive(archive) { _, _ in
            withProcessManager(pages: 192) { ram, _, manager in
                let poisoned = poisonAndRecycleAvailableFrames(in: ram)

                let process = "ZeroProbe.elf".withCString {
                    try? manager.pointee.spawnProcess(path: $0)
                }
                guard let process,
                      let physical = ram.vmm.pointee.physicalAddressOf(
                        rootTable: process.pointee.addressSpace.rootTablePhysical,
                        virtual  : UserSpaceLayout.stackTop - UserSpaceLayout.pageSize
                      )
                else {
                    Issue.record("the real boot loader path did not map its first stack page")
                    return
                }

                #expect(poisoned.contains(physical))
                expectZeroPage(physical, in: ram)
            }
        }

        #expect(staged != nil, "the ELF archive could not be staged")
    }


    @Test("task construction zeroes every eagerly mapped anonymous page")
    func taskMapIsZeroed() {
        withProcessManager(pages: 192) { ram, _, manager in
            TaskRegistry.resetForTesting()
            defer { TaskRegistry.resetForTesting() }

            let poisoned = poisonAndRecycleAvailableFrames(in: ram)

            guard let owner = try? manager.pointee.spawnProcess(),
                  let task  = manager.pointee.createSuspendedTask(ownedBy: owner)
            else {
                Issue.record("could not create the task-map fixture")
                return
            }

            let address = UserSpaceLayout.elfBaseTypical
            let mapped = manager.pointee.mapTaskAnonymous(
                task.control,
                at   : address,
                pages: 3
            )
            #expect(mapped == .ok)

            for page in 0..<3 {
                let virtual = address + UInt64(page) * UserSpaceLayout.pageSize
                guard let physical = ram.vmm.pointee.physicalAddressOf(
                    rootTable: task.process.pointee.addressSpace.rootTablePhysical,
                    virtual  : virtual
                ) else {
                    Issue.record("task-map reported success without publishing page \(page)")
                    return
                }

                #expect(poisoned.contains(physical))
                expectZeroPage(physical, in: ram)
            }
        }
    }


    @Test("lazy anonymous and grow-down faults zero recycled frames")
    func faultMaterializationIsZeroed() {
        withProcessManager(pages: 192) { ram, _, manager in
            let poisoned = poisonAndRecycleAvailableFrames(in: ram)

            guard let process = try? manager.pointee.spawnProcess(),
                  let vma = process.pointee.addressSpace.vmaManager,
                  let lazy = try? vma.pointee.mmapAnonymous(
                    size       : UserSpaceLayout.pageSize,
                    permissions: [.read, .write, .user]
                  )
            else {
                Issue.record("could not create the lazy-page fixture")
                return
            }

            let firstHandled = vma.pointee.handlePageFault(at: lazy, cause: .translation)
            #expect(firstHandled)
            guard let firstPhysical = expectMappedZeroPage(
                lazy,
                of       : process,
                recycled : poisoned,
                in       : ram
            ) else { return }

            let exposed: UnsafeMutablePointer<UInt8> = ram.vmm.pointee.physToVirt(
                firstPhysical
            )
            exposed.initialize(repeating: 0x3C, count: Self.pageSize)

            do {
                guard case .completed = try vma.pointee.decommit(
                    addr: lazy,
                    size: UserSpaceLayout.pageSize
                ) else {
                    Issue.record("one-page decommit unexpectedly suspended")
                    return
                }
            } catch {
                Issue.record("could not recycle the exposed anonymous page: \(error)")
                return
            }

            #expect(ram.vmm.pointee.physicalAddressOf(
                rootTable: process.pointee.addressSpace.rootTablePhysical,
                virtual  : lazy
            ) == nil)
            let recycledHandled = vma.pointee.handlePageFault(at: lazy, cause: .translation)
            #expect(recycledHandled)
            guard let recycledPhysical = expectMappedZeroPage(
                lazy,
                of       : process,
                recycled : poisoned,
                in       : ram
            ) else { return }
            #expect(recycledPhysical == firstPhysical)

            let stackStart = UserSpaceLayout.stackTop - UserSpaceLayout.pageSize
            do {
                try vma.pointee.registerRegion(
                    start      : stackStart,
                    size       : UserSpaceLayout.pageSize,
                    permissions: [.read, .write, .user],
                    backing    : .anonymous,
                    flags      : .growDown
                )
            } catch {
                Issue.record("could not register the grow-down fixture: \(error)")
                return
            }

            let grown = stackStart - UserSpaceLayout.pageSize
            let grownHandled = vma.pointee.handlePageFault(at: grown, cause: .translation)
            #expect(grownHandled)
            _ = expectMappedZeroPage(
                grown,
                of       : process,
                recycled : poisoned,
                in       : ram
            )
        }
    }


    @Test("anonymous OOM does not publish a page or raise resident accounting")
    func materializationOOMRollsBack() {
        withProcessManager(pages: 96) { ram, _, manager in
            guard let process = try? manager.pointee.spawnProcess(),
                  let vma = process.pointee.addressSpace.vmaManager,
                  let address = try? vma.pointee.mmapAnonymous(
                    size       : UserSpaceLayout.pageSize,
                    permissions: [.read, .write, .user]
                  )
            else {
                Issue.record("could not create the OOM fixture")
                return
            }

            let held = allocateAvailableFrames(in: ram)
            defer { release(held, in: ram) }
            let residentBefore = vma.pointee.residentPages

            let handled = vma.pointee.handlePageFault(at: address, cause: .translation)
            #expect(!handled)
            #expect(ram.vmm.pointee.physicalAddressOf(
                rootTable: process.pointee.addressSpace.rootTablePhysical,
                virtual  : address
            ) == nil)
            #expect(vma.pointee.residentPages == residentBefore)
        }
    }


    private func expectMappedZeroPage(
        _ virtual : VirtualAddress,
        of process: UnsafeMutablePointer<Process>,
        recycled  : Set<PhysicalAddress>,
        in ram    : HostRAM
    ) -> PhysicalAddress? {
        guard let physical = ram.vmm.pointee.physicalAddressOf(
            rootTable: process.pointee.addressSpace.rootTablePhysical,
            virtual  : virtual
        ) else {
            Issue.record("fault reported success without publishing its page")
            return nil
        }

        #expect(recycled.contains(physical))
        expectZeroPage(physical, in: ram)
        return physical
    }


    private func expectZeroPage(_ physical: PhysicalAddress, in ram: HostRAM) {
        let bytes: UnsafeMutablePointer<UInt8> = ram.vmm.pointee.physToVirt(physical)
        let page = UnsafeBufferPointer(start: bytes, count: Self.pageSize)

        #expect(page.first == 0)
        #expect(page.last  == 0)
        #expect(page.allSatisfy { $0 == 0 })
    }


    private func poisonAndRecycleAvailableFrames(
        in ram: HostRAM
    ) -> Set<PhysicalAddress> {
        let frames = allocateAvailableFrames(in: ram)

        for frame in frames {
            let bytes: UnsafeMutablePointer<UInt8> = ram.vmm.pointee.physToVirt(frame)
            bytes.initialize(repeating: Self.poison, count: Self.pageSize)
        }
        release(frames, in: ram)

        return Set(frames)
    }


    private func allocateAvailableFrames(in ram: HostRAM) -> [PhysicalAddress] {
        var frames: [PhysicalAddress] = []

        while let frame = try? ram.ppm.pointee.alloc(Self.pageSize) {
            frames.append(frame.address)
        }

        #expect(!frames.isEmpty)
        return frames
    }


    private func release(_ frames: [PhysicalAddress], in ram: HostRAM) {
        for frame in frames.reversed() {
            do { try ram.ppm.pointee.release(frame) }
            catch { Issue.record("could not recycle poisoned frame: \(error)") }
        }
    }
}
}
