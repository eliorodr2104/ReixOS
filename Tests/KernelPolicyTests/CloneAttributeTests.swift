//
//  CloneAttributeTests.swift
//  ReixOS
//

import Testing
@testable import Kernel
import ReixABI
import KernelTestSupport

/// What a fork copies of a mapping besides its physical address.
///
/// The clone used to rebuild the child's descriptors with the mapping default,
/// normal cacheable and inner shareable, so a device window lost its MAIR index
/// and a DMA buffer became cacheable in the child. Nothing faults on that, which
/// is why the assertions below read the leaf descriptor itself.
///
/// `.serialized`, and the run needs `--no-parallel`, for the reason
/// `ForkSpawnTests` states: `PPMBackend.physicalOffset` and `ProcessStatsIndex`
/// are global.
extension KernelPolicyTestRoot {
@Suite("Clone attributes", .serialized)
struct CloneAttributeTests {

    /// A physical base outside the host arena, standing in for MMIO.
    ///
    /// Never read or written: a device mapping carries `.uxn`, so the mapping
    /// path does not touch the bytes, and the clone only copies the descriptor.
    private static let devicePhysical: PhysicalAddress = 0x0900_0000


    // MARK: - Reading back what the clone wrote

    private struct Descriptor: Equatable {
        let physical: PhysicalAddress
        let mair    : UInt64
        let share   : UInt64
        let flags   : UInt64
    }


    private func descriptor(
        _ ram : HostRAM,
        root  : PhysicalAddress,
        at  va: VirtualAddress
    ) -> Descriptor? {
        guard let leaf = ram.vmm.pointee.leafTable(
            rootTable: root,
            virtual  : va
        ) else { return nil }

        let entry = leaf[va.l3]
        guard entry.isPresent else { return nil }

        return Descriptor(
            physical: entry.physicalAddress,
            mair    : entry.mairIndex.rawValue,
            share   : entry.shareability.rawValue,
            flags   : entry.flags.rawValue
        )
    }


    /// One `SharedRegion` on the kernel heap over a freshly allocated frame, the
    /// way `IPC.createShared` builds one for SHM and DMA alike.
    private func makeSharedRegion(
        _ ram : HostRAM,
        heap  : UnsafeMutablePointer<KernelHeap>
    ) -> UnsafeMutablePointer<SharedRegion>? {
        guard let page = try? ram.ppm.pointee.alloc(4096),
              let region = heap.pointee.kmallocOrNil(SharedRegion.self)
        else { return nil }

        region.initialize(to: SharedRegion(
            physicalPage: page,
            references  : 0,
            pageCount   : 1
        ))

        return region
    }


    /// Map one page of `kind` into the parent, clone, and hand both descriptors
    /// plus the parent's post-clone one to `check`.
    private func cloned(
        kind        : RegionKind,
        physicalBase: PhysicalAddress?,
        withRegion  : Bool,
        permissions : VMAPermissions = [.read, .write, .user],
        _ check     : (Descriptor, Descriptor, Descriptor) -> Void
    ) {
        withProcessManager(pages: 160) { ram, heap, manager in
            let region = withRegion ? makeSharedRegion(ram, heap: heap) : nil
            if withRegion, region == nil {
                Issue.record("could not build the shared region")
                return
            }

            guard let parent = try? manager.pointee.spawnProcess(),
                  let child  = try? manager.pointee.spawnProcess(),
                  let parentVMA = parent.pointee.addressSpace.vmaManager,
                  let childVMA  = child.pointee.addressSpace.vmaManager
            else { Issue.record("could not spawn the pair"); return }

            let base = physicalBase ?? region!.pointee.physicalPage.address

            guard let address = try? parentVMA.pointee.mapRegion(
                physicalBase: base,
                pageCount   : 1,
                kind        : kind,
                permissions : permissions,
                sharedRegion: region
            ) else { Issue.record("could not map the \(kind) region"); return }

            guard let before = descriptor(
                ram,
                root: parent.pointee.addressSpace.rootTablePhysical,
                at  : address
            ) else { Issue.record("the parent has no descriptor to clone"); return }

            do { try childVMA.pointee.cloneRegions(from: parentVMA.pointee) }
            catch { Issue.record("clone failed: \(error)"); return }

            // The node too, not only the descriptor: a split or a fault of the
            // child's reads its type back out of here.
            #expect(
                childVMA.pointee.vmaList.search(at: address)?.pointee.memoryType
                    == kind.memoryType
            )

            guard let childSide = descriptor(
                ram,
                root: child.pointee.addressSpace.rootTablePhysical,
                at  : address
            ) else { Issue.record("the child has no descriptor"); return }

            guard let after = descriptor(
                ram,
                root: parent.pointee.addressSpace.rootTablePhysical,
                at  : address
            ) else { Issue.record("the parent lost its descriptor"); return }

            check(before, childSide, after)
        }
    }


    // MARK: - The clone preserves what the parent had

    @Test("a device window is cloned with its MAIR index and shareability")
    func deviceWindowKeepsItsAttributes() {
        cloned(kind: .device, physicalBase: Self.devicePhysical, withRegion: false) {
            parentBefore, child, parentAfter in

            #expect(parentBefore.mair  == MairIndex.deviceMemory.rawValue)
            #expect(parentBefore.share == Shareability.nonShareable.rawValue)

            #expect(child == parentBefore)
            #expect(parentAfter == parentBefore)
        }
    }


    @Test("a DMA buffer is cloned non-cacheable, not cacheable")
    func dmaBufferKeepsItsAttributes() {
        cloned(kind: .dma, physicalBase: nil, withRegion: true) {
            parentBefore, child, parentAfter in

            #expect(parentBefore.mair  == MairIndex.normalNonCacheable.rawValue)
            #expect(parentBefore.share == Shareability.innerShareable.rawValue)

            #expect(child == parentBefore)
            #expect(parentAfter == parentBefore)
        }
    }


    @Test("a normal shared window is cloned unchanged too")
    func sharedWindowKeepsItsAttributes() {
        cloned(kind: .shared, physicalBase: nil, withRegion: true) {
            parentBefore, child, parentAfter in

            #expect(parentBefore.mair  == MairIndex.normalCacheable.rawValue)
            #expect(parentBefore.share == Shareability.innerShareable.rawValue)

            #expect(child == parentBefore)
            #expect(parentAfter == parentBefore)
        }
    }


    @Test("writable anonymous loses only the write bit, on both sides")
    func anonymousDowngradesOnlyPermissions() {
        withProcessManager(pages: 160) { ram, _, manager in
            guard let parent = try? manager.pointee.spawnProcess(),
                  let child  = try? manager.pointee.spawnProcess(),
                  let parentVMA = parent.pointee.addressSpace.vmaManager,
                  let childVMA  = child.pointee.addressSpace.vmaManager,
                  let address = try? parentVMA.pointee.mmapAnonymous(
                    size: 4096, permissions: [.read, .write, .user]
                  )
            else { Issue.record("could not build the anonymous fixture"); return }

            Arch.CPU.setCurrentProcess(UInt64(UInt(bitPattern: parent)))
            defer { Arch.CPU.setCurrentProcess(0) }

            // The region is `.noReserve`, so the page exists only once touched.
            #expect(UserMemory.validateRegion(
                addr: address, size: 4096, permissions: [.read, .write, .user]
            ))

            guard let before = descriptor(
                ram,
                root: parent.pointee.addressSpace.rootTablePhysical,
                at  : address
            ) else { Issue.record("no parent page to clone"); return }

            #expect(!VirtualPageFlags(rawValue: before.flags).contains(.readOnly))

            do { try childVMA.pointee.cloneRegions(from: parentVMA.pointee) }
            catch { Issue.record("clone failed: \(error)"); return }

            guard let childSide = descriptor(
                      ram,
                      root: child.pointee.addressSpace.rootTablePhysical,
                      at  : address
                  ),
                  let after = descriptor(
                      ram,
                      root: parent.pointee.addressSpace.rootTablePhysical,
                      at  : address
                  )
            else { Issue.record("the clone left a side without a descriptor"); return }

            #expect(childSide.physical == before.physical)
            #expect(after.physical     == before.physical)

            #expect(childSide.mair  == before.mair)
            #expect(childSide.share == before.share)
            #expect(after.mair      == before.mair)
            #expect(after.share     == before.share)

            #expect(VirtualPageFlags(rawValue: childSide.flags).contains(.readOnly))
            #expect(VirtualPageFlags(rawValue: after.flags).contains(.readOnly))
        }
    }


    // MARK: - The registration gate

    @Test("a region whose attributes no kind can produce is refused")
    func invalidCombinationsAreRefused() {
        withProcessManager(pages: 160) { ram, heap, manager in
            guard let owner = try? manager.pointee.spawnProcess(),
                  let vma   = owner.pointee.addressSpace.vmaManager,
                  let region = makeSharedRegion(ram, heap: heap)
            else { Issue.record("could not build the refusal fixture"); return }

            let readWrite: VMAPermissions = [.read, .write, .user]
            let readExec : VMAPermissions = [.read, .execute, .user]

            // (label, backing, memory type, permissions, needs a region object)
            let refused: [(StaticString, BackingType, MemoryType, VMAPermissions, Bool)] = [
                ("anonymous device"   , .anonymous , .device, readWrite        , false),
                ("anonymous dma"      , .anonymous , .dma   , readWrite        , false),
                ("file-backed dma"    , .fileBacked, .dma   , [.read, .user]   , false),
                ("device normal"      , .device    , .normal, readWrite        , false),
                ("shared device"      , .shared    , .device, readWrite        , true ),
                ("executable device"  , .device    , .device, readExec         , false),
                ("executable dma"     , .shared    , .dma   , readExec         , true ),
                ("writable file page" , .fileBacked, .normal, readWrite        , false),
            ]

            var start = UserSpaceLayout.mmapMin + UserSpaceLayout.pageSize

            for (label, backing, memoryType, permissions, needsRegion) in refused {
                let listBefore = regionStarts(vma)
                let ramBefore  = ram.pmmStateSnapshot()

                var refusedForAttributes = false
                do {
                    try vma.pointee.registerRegion(
                        start      : start,
                        size       : UserSpaceLayout.pageSize,
                        permissions: permissions,
                        backing    : backing,
                        flags      : .none,
                        memoryType : memoryType,
                        sharedRegion: needsRegion ? region : nil
                    )
                } catch let error as VMAError {
                    if case .invalidAttributes = error { refusedForAttributes = true }

                } catch {}

                // Compared as a `Bool`: the snapshot is the whole arena, and a
                // failing `#expect` would print both copies of it.
                let memoryUntouched = ram.pmmStateSnapshot() == ramBefore

                #expect(refusedForAttributes, "\(label) was not refused")
                #expect(regionStarts(vma) == listBefore, "\(label) left a VMA behind")
                #expect(memoryUntouched, "\(label) touched memory")
                #expect(!vma.pointee.isPageMapped(at: start), "\(label) mapped a page")

                start += UserSpaceLayout.pageSize
            }

            // The same gate lets every pair a `RegionKind` can produce through.
            #expect(VMAManager.validAttributes(
                backing: .anonymous, memoryType: .normal, permissions: readWrite
            ))
            #expect(VMAManager.validAttributes(
                backing: .fileBacked, memoryType: .normal, permissions: readExec
            ))
            for kind in [RegionKind.shared, .device, .dma] {
                #expect(VMAManager.validAttributes(
                    backing    : kind.backing,
                    memoryType : kind.memoryType,
                    permissions: readWrite
                ))
            }
        }
    }


    @Test("the memory type rides along in the node's existing padding")
    func nodeStaysInItsBucket() {
        // 56 bytes before this ticket and 56 after: the type went into the
        // padding after `mappingFlags`, so the slab bucket is still 64.
        #expect(MemoryLayout<VirtualMemoryArea>.size   == 56)
        #expect(MemoryLayout<VirtualMemoryArea>.stride == 56)
        #expect(MemoryLayout<VirtualMemoryArea>.stride <= 64)
    }


    private func regionStarts(
        _ manager: UnsafeMutablePointer<VMAManager>
    ) -> [VirtualAddress] {
        var result : [VirtualAddress] = []
        var current = manager.pointee.vmaList.head

        while let node = current {
            result.append(node.pointee.startAddress)
            current = node.pointee.next
        }

        return result
    }
}
}
