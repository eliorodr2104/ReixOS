//
//  ElfErrors.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 09/05/2026.
//

public enum ElfError: KernelDiagnostic {
    case invalidMagicNumber
    case noLoadableSegments
    case malformedLayout
    case allocationFailed (PPMError)
    case mappingFailed    (PPMError)

    public var description: String {
        switch self {
            case .invalidMagicNumber:
                "ELF Error: the file is not a valid ELF executable (bad magic)."

            case .noLoadableSegments:
                "ELF Error: the executable does not contain any PT_LOAD segment."

            case .malformedLayout:
                "ELF Error: the ELF segment layout is malformed or corrupted."

            case .allocationFailed(let inner):
                "ELF Error: image allocation failed (" + inner.description + ")"

            case .mappingFailed(let inner):
                "ELF Error: segment mapping failed (" + inner.description + ")"
        }
    }

    public var category: ErrorCategory { .elf }
}
