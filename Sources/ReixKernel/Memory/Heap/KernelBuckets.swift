//
//  KernelBuckets.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/04/2026.
//

public struct KernelBuckets {
    private var storage: (
        UnsafeMutableRawPointer?, UnsafeMutableRawPointer?,
        UnsafeMutableRawPointer?, UnsafeMutableRawPointer?,
        UnsafeMutableRawPointer?, UnsafeMutableRawPointer?,
        UnsafeMutableRawPointer?, UnsafeMutableRawPointer?,
        UnsafeMutableRawPointer?, UnsafeMutableRawPointer?
    ) = (nil, nil, nil, nil, nil, nil, nil, nil, nil, nil)
    
    public subscript(index: Int) -> UnsafeMutableRawPointer? {
        
        get {
            precondition(index >= 0 && index < 10, "Index out of bounds")

            return withUnsafePointer(to: storage) { ptr in
                let rawPtr = UnsafeRawPointer(ptr)
                let elementPtr = rawPtr.assumingMemoryBound(to: (UnsafeMutableRawPointer?).self)
                return elementPtr[index]
            }
        }
        
        mutating set {
            precondition(index >= 0 && index < 10, "Index out of bounds")
            
            withUnsafeMutablePointer(to: &storage) { ptr in
                let rawPtr = UnsafeMutableRawPointer(ptr)
                let elementPtr = rawPtr.assumingMemoryBound(to: (UnsafeMutableRawPointer?).self)
                elementPtr[index] = newValue
            }
        }
    }
}
