//
//  DmaAlloc.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/08/2026.
//

import ReixABI

/// `dmaAlloc(pageCount, deviceHandle)` syscall provider.
///
/// Charged to the creator like an SHM region, for as long as the frames are out
/// of the PPM. A buffer `dmaPhysical` has published outlives its last holder on
/// `DmaQuarantine` until `dmaReclaim` declares its device reset, and its
/// creator keeps paying for it there: a driver that drops its buffer and lives
/// on is refunded only by the reclaim. A creator that dies first stops paying
/// with its budget, which dies with it, and the frames return to the machine
/// only when a successor resets the device and says so.
///
/// Hands back a physically contiguous, non-cacheable buffer mapped into the
/// caller, and a capability that names it. Two registers on the way out, like
/// `shmCreate`: `x0` the handle, `x1` the base virtual address.
///
/// **A device capability carrying `.dma` is the price of entry.** Not because
/// this syscall does anything with the device, but because of what the capability
/// it mints is allowed to reveal: a physical address.
///
/// ### What is inside the trusted base here, said plainly
///
/// There is nothing between a device and memory on this machine - no SMMU, no
/// IOMMU, nothing that scopes a transfer to the device that started it. So a
/// physical address handed to a process that can program a transferring device
/// **is authority over all of physical memory**, the kernel's own pages
/// included. Any such driver is inside the trusted base. It is not sandboxed, it
/// is trusted, and no check in this file changes that.
///
/// What the checks do is decide *who* gets to be in there:
///
/// - `.dma` is a right of its own, so holding a device window is no longer
///   enough. The console holds one and cannot mint a buffer; the disk driver's
///   window says `.dma` because the process that handed it over said so.
/// - Which device transfers into the buffer is still not checked, and cannot
///   be. Without an IOMMU nothing scopes a transfer, so a buffer minted through
///   one window can be read by any device the holder can reach.
/// - The buffer does record the window it was minted through, and that record
///   is not a boundary either. It answers one question: which device's reset
///   makes the buffer safe to free once nobody holds it (`dmaReclaim`). It does
///   not stop another device the holder drives from reaching the buffer, and it
///   does not stop a holder from declaring a reset that never happened. A
///   holder that hands a buffer to a device other than the one it was minted
///   through, and then declares the first one reset, frees memory the second
///   may still write, and nothing here can tell.
///
/// Real isolation is an SMMU: stream IDs, a translation table per device, and
/// invalidation. That is the answer and it is not this file. Until then the set
/// of processes holding `.dma` is a list worth being able to read off the boot,
/// and today it has one name on it.
///
/// The frames come from one buddy block, which is what makes them contiguous,
/// rounded up to a power of two as a single block has to be. The charge is the
/// whole block: a seven-page buffer holds eight frames and costs eight. It used
/// to cost seven, which let every buffer hold a frame its budget never saw.
/// `shmCreate` no longer allocates this way: its regions are exact and may be
/// scattered, and only a buffer made here is a region of one extent, whose
/// address may be asked for.
public struct DmaAlloc: SyscallProvider {

    public static let number: SyscallNumber = .dmaAlloc

    private static let maxPages: UInt32 = 256

    public static func handle(
        frame  : UnsafeMutablePointer<Arch.TrapFrame>,
        context: SyscallContext
    ) {
        guard let current    = Arch.CPU.getCurrentProcess(),
              let vmaManager = current.pointee.addressSpace.vmaManager
        else {
            fail(frame)
            return
        }

        guard let pageCount = SyscallABI.count(
                  frame.pointee.x0,
                  atMost: Self.maxPages
              ),
              pageCount > 0
        else {
            fail(frame)
            return
        }

        guard let window = transferWindow(handle: frame.pointee.x1, in: current) else {
            fail(frame)
            return
        }

        // Charged to the creator, like an SHM region: the frames have one owner.
        // The whole block and not the request, and before the allocator is asked.
        let budget = vmaManager.pointee.budget
        let frames = Self.blockFrames(pageCount)

        guard chargeFrames(budget, frames) else {
            fail(frame)
            return
        }

        let physicalPage: PhysicalPage
        do {
            physicalPage = try context.ppm.pointee.alloc(
                Int(UInt64(frames) * UserSpaceLayout.pageSize)
            )

        } catch {
            refundFrames(budget, frames)
            fail(frame)
            return
        }

        // Zeroed through the kernel's own mapping, which is cacheable, and then
        // pushed out of the cache, because the mapping handed to userland below
        // is not. Two mappings that disagree about caching over the same bytes is
        // a mismatched alias: without this the device may read what was there
        // before instead of zeros, and a line left dirty may be written back
        // later, on top of whatever the driver has put there since.
        let bytes = UInt64(pageCount) * UserSpaceLayout.pageSize

        let zeroDest: UnsafeMutablePointer<UInt8> = vmaManager.pointee.context.vmm.pointee.physToVirt(
            physicalPage.address
        )
        zeroDest.initialize(repeating: 0, count: Int(bytes))

        Arch.MMU.cleanDataCacheRange(UnsafeMutableRawPointer(zeroDest), size: bytes)

        let handle: UInt32
        let region: UnsafeMutablePointer<SharedRegion>
        switch context.ipc.pointee.createShared(
            for      : current,
            page     : physicalPage,
            pageCount: pageCount,
            device   : window.address
        ) {
            case .success(let created):
                handle = created.handle
                region = created.region

            case .failure:
                // `createShared` has already given the frames back.
                refundFrames(budget, frames)
                fail(frame)
                return
        }

        do {
            let regionAddress = try vmaManager.pointee.mapRegion(
                region,
                kind       : .dma,
                permissions: [.read, .write, .user]
            )

            frame.pointee.x0 = UInt64(handle)
            frame.pointee.x1 = regionAddress

        } catch {
            _ = context.ipc.pointee.releaseCapability(handle, of: current)
            fail(frame)
        }
    }


    /// The device window `handle` names, when this process may transfer
    /// through it. `dmaReclaim` asks the same question.
    ///
    /// `.dma` and not merely `.write`. Writing a device's registers drives that
    /// device; a physical address is the whole of memory, and the two are only
    /// the same authority for a device that transfers. This used to accept any
    /// device window at all, with any rights on it, so a read-only diagnostic
    /// window over a UART opened the door as wide as a disk controller did.
    static func transferWindow(
        handle : UInt64,
        in process: UnsafeMutablePointer<Process>
    ) -> DeviceRegion? {
        guard let handle   = SyscallABI.handle(handle),
              let metadata   = process.pointee.metadata,
              let capability = metadata.pointee.capsTable.resolve(handle),
              case .device(let window) = capability.target,
              capability.rights.contains(.dma)
        else { return nil }

        return window
    }


    /// The frames of the one buddy block `pageCount` pages are served from:
    /// the next power of two, as the allocator rounds. `pageCount` is at least
    /// one and at most `maxPages`, so the shift cannot overflow.
    @inline(__always)
    private static func blockFrames(_ pageCount: UInt32) -> UInt32 {
        UInt32(1) << UInt32(32 - (pageCount - 1).leadingZeroBitCount)
    }


    /// Both registers on every failure exit, for the reason `ShmCreate`
    /// documents: the userland wrapper stores `x1` unconditionally.
    private static func fail(_ frame: UnsafeMutablePointer<Arch.TrapFrame>) {
        frame.pointee.x0 = UInt64.max
        frame.pointee.x1 = 0
    }
}
