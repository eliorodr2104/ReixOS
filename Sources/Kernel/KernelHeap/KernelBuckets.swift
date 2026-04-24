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
        mutating get {
            withUnsafeMutablePointer(to: &storage) { ptr in
                ptr.withMemoryRebound(to: Optional<UnsafeMutableRawPointer>.self, capacity: 10) { arrayPtr in
                    return arrayPtr[index]
                }
            }
        }
        mutating set {
            withUnsafeMutablePointer(to: &storage) { ptr in
                ptr.withMemoryRebound(to: Optional<UnsafeMutableRawPointer>.self, capacity: 10) { arrayPtr in
                    arrayPtr[index] = newValue
                }
            }
        }
    }
}
