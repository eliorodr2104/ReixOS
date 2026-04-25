//
//  KernelError.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/04/2026.
//

protocol KernelFatal: Error {
    var description: String { get }
}

public enum KernelError: KernelFatal {
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
    
    public var description: String {
        switch self {
            case .allocatorError(let response):
                response.localizedDescription
                
            case .physicalMemoryManager(let response):
                response.description
                
            case .unknown(_):
                "Kernel Error: Unknown error founded."
        }
        
    }
}
