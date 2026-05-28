//
//  PPMError.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/04/2026.
//

public enum PPMError: KernelFatal {
    case allocationFailed       (reason  : AllocatorError)
    case metadataInconsistency
    case invalidFlags
    case protectedMemoryViolation
    case initRamError
    case invalidRefCount        (_ count : Int)
    case pageOrderMismatch      (expected: UInt8, provided: UInt8)

    public var description: String {
        switch self {
            case .allocationFailed(let reason):
                "PPM Error: allocation failed (" + reason.description + ")"

            case .metadataInconsistency:
                "PPM Error: frame metadata is inconsistent or corrupted."

            case .invalidFlags:
                "PPM Error: invalid page flags detected in metadata."

            case .protectedMemoryViolation:
                "PPM Error: memory protection violation, tried to free a reserved or kernel page."

            case .initRamError:
                "PPM Error: RAM initialization failed (invalid DTB info)."

            case .invalidRefCount:
                "PPM Error: invalid reference count, tried to free an already unreferenced page."

            case .pageOrderMismatch:
                "PPM Error: page order mismatch between metadata and provided page."
        }
    }

    public var category: ErrorCategory { .memory }
}
