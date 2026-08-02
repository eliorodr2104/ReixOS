//
//  UserMemory.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 10/05/2026.
//

import ReixABI

/// Helpers used by syscalls to validate and copy buffers exchanged
/// with user space.
public struct UserMemory {

    static func validateRegion(addr: UInt64, size: Int) -> Bool {
        guard size > 0 else { return false }
        
        return UserSpaceLayout.checkedUserRange(
            address: addr,
            size   : UInt64(size)
        ) != nil
    }
    
    static func validateRegion(
        addr       : UInt64,
        size       : Int,
        permissions: VMAPermissions
    ) -> Bool {
        guard size > 0,
              let range = UserSpaceLayout.checkedUserRange(
                address: addr,
                size   : UInt64(size)
              ) else { return false }
        
        guard let process    = Arch.CPU.getCurrentProcess(),
              let vmaManager = process.pointee.addressSpace.vmaManager
        else { return false }

        guard vmaManager.pointee.contains(
            start      : range.start,
            end        : range.end,
            permissions: permissions
        ) else { return false }

        return materializeRange(
            start     : range.start,
            end       : range.end,
            vmaManager: vmaManager
        )
    }


    /// Give every page of `[start, end)` a live translation before the
    /// kernel touches the range at EL1, or refuse the buffer.
    ///
    /// `VMAManager.contains` only proves the range is *registered* with the
    /// requested rights: `mmap`/`brk` regions are `.noReserve` and the user
    /// stack is `.growDown`, so their pages carry no PTE until user space
    /// faults on them. Dereferencing such a page from EL1 raises a data
    /// abort with EC 0x25, which the dispatcher can only turn into a panic
    /// ("Kernel Space Abort") because the kernel has no fault-fixup.
    ///
    /// `[start, end)` are the raw (unaligned) buffer bounds and the walk
    /// steps page by page from `start`, so the address handed to the fault
    /// handler always lies inside the range `contains` has just approved,
    /// rounding down to the page base could otherwise point outside the VMA
    /// when a region does not begin on a page boundary.
    private static func materializeRange(
        start     : VirtualAddress,
        end       : VirtualAddress,
        vmaManager: UnsafeMutablePointer<VMAManager>
    ) -> Bool {
        var cursor = start

        while cursor < end {
            if !vmaManager.pointee.isPageMapped(at: cursor) {
                guard vmaManager.pointee.handlePageFault(
                    at   : cursor,
                    cause: .translation
                ) else { return false }
            }

            cursor = (cursor & ~(UserSpaceLayout.pageSize - 1)) + UserSpaceLayout.pageSize
        }

        return true
    }


    /// Copy `count` bytes out of user space.
    ///
    /// Safe to dereference `userSrc` directly: `validateRegion` has both
    /// checked the rights and forced every page of the range into the page
    /// tables, so the load below cannot abort at EL1.
    static func copyFromUser(
        kernelDest: UnsafeMutableRawPointer,
        userSrc   : UInt64,
        count     : Int
    ) -> Bool {
        guard validateRegion(
            addr       : userSrc,
            size       : count,
            permissions: [.read, .user]
        ) else { return false }

        let srcPtr = UnsafeRawPointer(bitPattern: UInt(userSrc))!
        kernelDest.copyMemory(from: srcPtr, byteCount: count)
        return true
    }
}
