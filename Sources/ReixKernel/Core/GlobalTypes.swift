//
//  GlobalTypes.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/04/2026.
//

public typealias KernelPPM                = PhysicalPageManager<BuddyAllocator>
public typealias KernelHeap               = BucketsHeap
public typealias KernelScheduler          = RoundRobin
public typealias KernelIPC                = RendezvousIPC
public typealias KernelInternalFileSystem = TarFileSystem
public typealias Arch                     = AArch64

public enum ReixVersion {
    public static let major = 0
    public static let minor = 2
    public static let patch = 0

    @inline(__always)
    public static func withVersionBuffer<R>(
        _ body: (UnsafeBufferPointer<UInt8>) -> R
    ) -> R {
        var storage = InlineArray<16, UInt8>(repeating: 0)
        
        return withUnsafeMutableBytes(of: &storage) { rawBuffer in
            let ptr = rawBuffer.baseAddress!.assumingMemoryBound(to: UInt8.self)
            var offset = 0
            
            offset += writeInt(major, into: ptr + offset)
            ptr[offset] = 46 // '.'
            offset += 1
            
            offset += writeInt(minor, into: ptr + offset)
            ptr[offset] = 46 // '.'
            offset += 1
            
            offset += writeInt(patch, into: ptr + offset)
            ptr[offset] = 0  // null-terminator C-string
            
            return body(UnsafeBufferPointer(start: ptr, count: offset))
        }
    }

    @inline(__always)
    private static func writeInt(
        _    value: Int,
        into ptr  : UnsafeMutablePointer<UInt8>
    ) -> Int {
        if value == 0 {
            ptr[0] = 48 // '0'
            return 1
        }
        
        var v = value
        var digits = InlineArray<5, UInt8>(repeating: 0)
        var count = 0
        
        withUnsafeMutableBytes(of: &digits) { dPtr in
            let d = dPtr.baseAddress!.assumingMemoryBound(to: UInt8.self)
            
            while v > 0 {
                d[count] = UInt8(48 + (v % 10))
                v /= 10
                count += 1
            }
            
            for i in 0..<count {
                ptr[i] = d[count - 1 - i]
            }
        }
        
        return count
    }
}
