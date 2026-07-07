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
                
        }
    }

    public var category: ErrorCategory { .process }
}
