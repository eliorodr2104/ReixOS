//
//  DmaAlloc.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/08/2026.
//

import ReixABI

/// `dmaAlloc(pageCount, deviceHandle)` syscall provider.
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
/// - Which device is still not checked, and cannot be. Without an IOMMU nothing
///   scopes a transfer, so a buffer minted through one window can be read by any
///   device the holder can reach. Binding the two would be bookkeeping that
///   looks like a boundary, which is worse than the honest gate.
///
/// Real isolation is an SMMU: stream IDs, a translation table per device, and
/// invalidation. That is the answer and it is not this file. Until then the set
/// of processes holding `.dma` is a list worth being able to read off the boot,
/// and today it has one name on it.
///
/// The frames come from one buddy block, which is what makes them contiguous.
/// That is not new: `shmCreate` has always allocated the same way. What is new
/// is that the address may be asked for.
public struct DmaAlloc: SyscallProvider {

    public static let number: SyscallNumber = .dmaAlloc

    private static let maxPages: UInt64 = 256

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

        let pageCount = frame.pointee.x0
        guard pageCount > 0, pageCount <= Self.maxPages else {
            fail(frame)
            return
        }

        guard mayTransfer(handle: frame.pointee.x1, in: current) else {
            fail(frame)
            return
        }

        let physicalPage: PhysicalPage
        do {
            physicalPage = try context.ppm.pointee.alloc(
                Int(pageCount * UserSpaceLayout.pageSize)
            )

        } catch {
            fail(frame)
            return
        }

        // Zeroed through the kernel's own mapping, which is cacheable, and then
        // pushed out of the cache, because the mapping handed to userland below
        // is not. Two mappings that disagree about caching over the same bytes is
        // a mismatched alias: without this the device may read what was there
        // before instead of zeros, and a line left dirty may be written back
        // later, on top of whatever the driver has put there since.
        let bytes = pageCount * UserSpaceLayout.pageSize

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
            pageCount: UInt32(pageCount),
            forDevice: true
        ) {
            case .success(let created):
                handle = created.handle
                region = created.region

            case .failure:
                fail(frame)
                return
        }

        do {
            let regionAddress = try vmaManager.pointee.mapRegion(
                physicalBase: region.pointee.physicalPage.address,
                pageCount   : Int(pageCount),
                kind        : .dma,
                permissions : [.read, .write, .user],
                sharedRegion: region
            )

            frame.pointee.x0 = UInt64(handle)
            frame.pointee.x1 = regionAddress

        } catch {
            _ = context.ipc.pointee.releaseCapability(handle, of: current)
            fail(frame)
        }
    }


    /// Whether `handle` names a device window this process may transfer through.
    ///
    /// `.dma` and not merely `.write`. Writing a device's registers drives that
    /// device; a physical address is the whole of memory, and the two are only
    /// the same authority for a device that transfers. This used to accept any
    /// device window at all, with any rights on it, so a read-only diagnostic
    /// window over a UART opened the door as wide as a disk controller did.
    private static func mayTransfer(
        handle : UInt64,
        in process: UnsafeMutablePointer<Process>
    ) -> Bool {
        guard handle <= UInt64(UInt32.max),
              let metadata   = process.pointee.metadata,
              let capability = metadata.pointee.capsTable.resolve(UInt32(handle)),
              case .device = capability.target,
              capability.rights.contains(.dma)
        else { return false }

        return true
    }


    /// Both registers on every failure exit, for the reason `ShmCreate`
    /// documents: the userland wrapper stores `x1` unconditionally.
    private static func fail(_ frame: UnsafeMutablePointer<Arch.TrapFrame>) {
        frame.pointee.x0 = UInt64.max
        frame.pointee.x1 = 0
    }
}
