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
    
    public var localizedDescription: String {
        switch self {
            case .allocatorError(let response):
                response.localizedDescription
                
            case .physicalMemoryManager(let response):
                response.localizedDescription
                
            case .unknown(_):
                "Kernel Error: Unknown error founded."
        }
        
    }
}
