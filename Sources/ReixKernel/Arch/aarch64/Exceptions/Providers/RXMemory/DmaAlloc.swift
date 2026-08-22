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
/// **A device capability is the price of entry.** Not because this syscall does
/// anything with the device, but because of what the capability it mints is
/// allowed to reveal: a physical address. There is no IOMMU on this machine, so
/// a physical address plus a device that transfers is authority over all of
/// memory. Deriving it from a device capability keeps that authority where it
/// already was rather than opening a second door to it: a process that could
/// not program a device had no use for a physical address, and now cannot get
/// one either.
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

        guard holdsDevice(handle: frame.pointee.x1, in: current) else {
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

         let zeroDest: UnsafeMutablePointer<UInt8> = vmaManager.pointee.context.vmm.pointee.physToVirt(
            physicalPage.address
        )
        zeroDest.initialize(
            repeating: 0,
            count    : Int(pageCount * UserSpaceLayout.pageSize)
        )

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


    /// Whether `handle` names a device window this process holds.
    ///
    /// Which device is not checked and cannot be: without an IOMMU nothing
    /// scopes a transfer to the device that started it, so the honest gate is
    /// "this process already drives hardware" and not "this buffer belongs to
    /// that controller".
    private static func holdsDevice(
        handle : UInt64,
        in process: UnsafeMutablePointer<Process>
    ) -> Bool {
        guard handle <= UInt64(UInt32.max),
              let metadata   = process.pointee.metadata,
              let capability = metadata.pointee.capsTable.resolve(UInt32(handle)),
              case .device = capability.target
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
