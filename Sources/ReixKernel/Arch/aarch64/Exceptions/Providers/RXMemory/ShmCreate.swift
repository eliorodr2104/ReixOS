//
//  ShmCreate.swift
//  ReixOS
//
//  Created by Eliomar on 28/06/2026.
//

import ReixABI

/// `shmCreate(pageCount)` syscall provider.
///
/// This is a two-register syscall: `x0` carries the capability handle and `x1`
/// the base virtual address the region was mapped at. The userland wrapper goes
/// through `_asm_spawn`, which stores `x1` into the result buffer
/// unconditionally, so a failure exit that leaves `x1` alone hands the caller
/// back its own `x1` at `svc` time as `SharedMemory.address`. Every exit below
/// therefore writes both registers: `UInt64.max` in `x0` (the memory family
/// failure sentinel, which truncates to the `UInt32.max` the wrapper checks)
/// and `0` in `x1`, a null address that no mapping can ever legitimately have
/// since the user mmap window starts at `UserSpaceLayout.mmapBase`.
public struct ShmCreate: SyscallProvider {

    public static let number: SyscallNumber = .shmCreate

    private static let maxPages: UInt64 = 256

    public static func handle(
        frame  : UnsafeMutablePointer<Arch.TrapFrame>,
        context: SyscallContext
    ) {
        
        guard let current   = Arch.CPU.getCurrentProcess(),
              let vmaManager = current.pointee.addressSpace.vmaManager
        else {
            frame.pointee.x0 = UInt64.max
            frame.pointee.x1 = 0
            return
        }

        let pageCount = frame.pointee.x0
        guard pageCount > 0, pageCount <= Self.maxPages else {
            frame.pointee.x0 = UInt64.max
            frame.pointee.x1 = 0
            return
        }

        // Allocate the contiguous physical block.
        let physicalPage: PhysicalPage
        do {
            physicalPage = try context.ppm.pointee.alloc(Int(pageCount * UserSpaceLayout.pageSize))
            
        } catch {
            frame.pointee.x0 = UInt64.max
            frame.pointee.x1 = 0
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
            pageCount: UInt32(pageCount)
        ) {
            case .success(let created):
                handle = created.handle
                region = created.region

            case .failure:
                frame.pointee.x0 = UInt64.max
                frame.pointee.x1 = 0
                return
        }

        do {
            let regionAddress = try vmaManager.pointee.mapRegion(
                physicalBase: region.pointee.physicalPage.address,
                pageCount   : Int(pageCount),
                kind        : .shared,
                permissions : [.read, .write, .user],
                sharedRegion: region
            )

            frame.pointee.x0 = UInt64(handle)
            frame.pointee.x1 = regionAddress

        } catch {
            _ = context.ipc.pointee.releaseCapability(handle, of: current)
            frame.pointee.x0 = UInt64.max
            frame.pointee.x1 = 0
        }
    }
}
