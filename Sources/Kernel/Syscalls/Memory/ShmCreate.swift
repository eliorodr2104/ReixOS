//
//  ShmCreate.swift
//  ReixOS
//
//  Created by Eliomar on 28/06/2026.
//

import ReixABI

/// `shmCreate(pageCount)` syscall provider.
///
/// The region's frames are charged to the creator's `FrameBudget` before the
/// allocator is asked, so a process cannot buy the machine's memory a window at
/// a time. A mapper of somebody else's region pays nothing: the frames have one
/// owner, and it is the one that minted them.
///
/// The region holds exactly `pageCount` frames, the charge, as blocks that may
/// lie anywhere in physical memory: see `SharedRegion.allocateFrames`.
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

    private static let maxPages: UInt32 = 256

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

        guard let pageCount = SyscallABI.count(
                  frame.pointee.x0,
                  atMost: Self.maxPages
              ),
              pageCount > 0
        else {
            frame.pointee.x0 = UInt64.max
            frame.pointee.x1 = 0
            return
        }

        // Charged to the creator for as long as it holds the region; see the
        // note above the type.
        let budget = vmaManager.pointee.budget

        guard chargeFrames(budget, pageCount) else {
            frame.pointee.x0 = UInt64.max
            frame.pointee.x1 = 0
            return
        }

        let handle: UInt32
        let region: UnsafeMutablePointer<SharedRegion>
        switch context.ipc.pointee.createShared(
            for      : current,
            pageCount: pageCount
        ) {
            case .success(let created):
                handle = created.handle
                region = created.region

            case .failure:
                // `createShared` has already given the frames back.
                refundFrames(budget, pageCount)
                frame.pointee.x0 = UInt64.max
                frame.pointee.x1 = 0
                return
        }

        for index in 0..<Int(region.pointee.extentCount) {
            let extent = region.pointee.extent(index)

            let zeroDest: UnsafeMutablePointer<UInt8> = vmaManager.pointee.context.vmm.pointee.physToVirt(
                extent.address
            )
            zeroDest.initialize(
                repeating: 0,
                count    : Int(UInt64(extent.pages) * UserSpaceLayout.pageSize)
            )
        }

        do {
            let regionAddress = try vmaManager.pointee.mapRegion(
                region,
                kind       : .shared,
                permissions: [.read, .write, .user]
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
