//
//  ProcessManagerError.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 10/05/2026.
//

public enum ProcessManagerError: KernelDiagnostic {
    case managerNotValid
    case programAddressNotValid
    case elfParsingFailed       (ElfError)
    case creationProcessFailed  (PPMError)
    case allocationPageFailed   (PPMError)
    case mappingFailed          (PPMError)
    case registerRegionError    (VMAError)

    /// The kernel heap could not hold one of the blocks a process is made of
    /// (trap frame, kernel stack, metadata, `Process`, `VMAManager`).
    ///
    /// Payload-free on purpose: the heap reports exhaustion as a plain `nil`,
    /// and wrapping it in a `PPMError` the PPM never raised would invent a
    /// diagnosis. Spawning is the caller's request, so it fails alone.
    case heapAllocationFailed

    public var description: StaticString {
        switch self {
            case .managerNotValid:
                "Process Manager Error: manager pointers are not wired."

            case .programAddressNotValid:
                "Process Manager Error: program address resolved to zero."

            case .elfParsingFailed(let inner):
                inner.description

            case .creationProcessFailed(let inner):
                switch inner.reportedCause {
                    case .outOfMemory    : "Process Manager Error: address space creation failed (no free physical memory)."
                    case .requestRejected: "Process Manager Error: address space creation failed (the allocator rejected the request)."
                    case .managerFault   : "Process Manager Error: address space creation failed (the physical page manager reported a fault)."
                }

            case .allocationPageFailed(let inner):
                switch inner.reportedCause {
                    case .outOfMemory    : "Process Manager Error: page allocation failed (no free physical memory)."
                    case .requestRejected: "Process Manager Error: page allocation failed (the allocator rejected the request)."
                    case .managerFault   : "Process Manager Error: page allocation failed (the physical page manager reported a fault)."
                }

            case .mappingFailed(let inner):
                switch inner.reportedCause {
                    case .outOfMemory    : "Process Manager Error: user page mapping failed (no free physical memory)."
                    case .requestRejected: "Process Manager Error: user page mapping failed (the allocator rejected the request)."
                    case .managerFault   : "Process Manager Error: user page mapping failed (the physical page manager reported a fault)."
                }

            case .registerRegionError(let inner):
                inner.description

            case .heapAllocationFailed:
                "Process Manager Error: kernel heap exhausted while building the process."

        }
    }
}
