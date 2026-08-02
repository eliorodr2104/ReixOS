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

    public var description: String {
        switch self {
            case .managerNotValid:
                "Process Manager Error: manager pointers are not wired."

            case .programAddressNotValid:
                "Process Manager Error: program address resolved to zero."

            case .elfParsingFailed(let inner):
                "Process Manager Error: ELF parsing failed (" + inner.description + ")"

            case .creationProcessFailed(let inner):
                "Process Manager Error: address space creation failed (" + inner.description + ")"

            case .allocationPageFailed(let inner):
                "Process Manager Error: page allocation failed (" + inner.description + ")"

            case .mappingFailed(let inner):
                "Process Manager Error: user page mapping failed (" + inner.description + ")"
                
            case .registerRegionError(let inner):
                "Virtual Memory Area Error: register area failed (" + inner.description + ")"
                
            case .heapAllocationFailed:
                "Process Manager Error: kernel heap exhausted while building the process."

        }
    }

    public var category: ErrorCategory { .process }
}
