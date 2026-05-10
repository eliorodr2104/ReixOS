//
//  PPMError.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/04/2026.
//

public enum PPMError: KernelFatal {
    case allocationFailed(reason: AllocatorError)
    case metadataInconsistency
    case invalidFlags
    case protectedMemoryViolation
    case initRamError
    case invalidRefCount(_ count: Int)
    case pageOrderMismatch(expected: UInt8, provided: UInt8)
        
    public var description: String {
        switch self {
            case .allocationFailed(let reason):
                "PPM Error: Allocation failed. Reason: \(reason.localizedDescription)"
                
            case .metadataInconsistency:
                "PPM Error: Frame metadata is inconsistent or corrupted."
                
            case .invalidFlags:
                "PPM Error: Invalid page flags detected in metadata."
                
            case .protectedMemoryViolation:
                "PPM Error: Memory protection violation. Attempted to free a reserved or kernel page."
                
            case .initRamError:
                "PPM Error: RAM initialization failed (Invalid DTB info)."
                
            case .invalidRefCount:
                "PPM Error: Invalid reference count. Attempted to free an already unreferenced page."
                
            case .pageOrderMismatch:
                "PPM Error: Page order mismatch"
        }
    }
}
