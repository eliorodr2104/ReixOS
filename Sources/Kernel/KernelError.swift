//
//  KernelError.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/04/2026.
//

public enum KernelError: Error {
    case allocatorError(response: AllocatorError)
    case physicalMemoryManager(response: PPMError)
    case unknown(Error)
    
    @inline(__always)
    public init(_ error: AllocatorError) {
        self = .allocatorError(response: error)
    }
    
    @inline(__always)
    public init(_ error: PPMError) {
        self = .physicalMemoryManager(response: error)
    }
}
