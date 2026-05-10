//
//  UserMemory.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 10/05/2026.
//

public struct UserMemory {
    
    static func validateRegion(
        addr: UInt64,
        size: Int
    ) -> Bool {
        let endAddr = addr + UInt64(size)
        return endAddr < 0x0001_0000_0000_0000 && addr != 0
    }
    
    static func copyFromUser(
        kernelDest: UnsafeMutableRawPointer,
        userSrc   : UInt64,
        count     : Int
    ) -> Bool {
        guard validateRegion(addr: userSrc, size: count) else { return false }
        
        let srcPtr = UnsafeRawPointer(bitPattern: UInt(userSrc))!
        kernelDest.copyMemory(from: srcPtr, byteCount: count)
        return true
    }
    
}
