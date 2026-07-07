//
//  UserMemory.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 10/05/2026.
//

/// Helpers used by syscalls to validate and copy buffers exchanged
/// with user space.
///
/// The legacy `validateRegion(addr:size:)` only enforces the numeric
/// user-VA bounds. The VMA-aware overload added in step M7 additionally
/// consults the current process VMA list, refusing buffers that fall
/// on unmapped pages or that lack the requested permissions.
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
        
        return vmaManager.pointee.contains(
            start      : range.start,
            end        : range.end,
            permissions: permissions
        )
    }


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
