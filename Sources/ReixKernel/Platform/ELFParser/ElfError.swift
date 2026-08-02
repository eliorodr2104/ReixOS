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

    /// Every branch ends in a plain literal, and the wrapping cases spell the
    /// nested reason out instead of composing it.
    ///
    /// A literal `String` points straight at `.rodata` and never touches the
    /// heap; `+` builds a new buffer. `Kernel.internalPanic` reads this
    /// property exactly when a subsystem has just failed, often the allocator
    /// itself, so the concatenation that used to be here asked the exhausted
    /// allocator for one more buffer, `swift_allocObject` force-unwrapped the
    /// nil it got back, and the kernel died reporting the fault instead of
    /// reporting it.
    ///
    /// Both wrapping cases carry a `PPMError`, so neither may hand back
    /// `inner.description`: the step is the only thing that tells them apart.
    /// They enumerate `reportedCause` instead, which keeps the nested reason
    /// and lets the compiler force a new PPM case to be classified once, at
    /// its source, rather than here.
    public var description: String {
        switch self {
            case .invalidMagicNumber:
                "ELF Error: the file is not a valid ELF executable (bad magic)."

            case .noLoadableSegments:
                "ELF Error: the executable does not contain any PT_LOAD segment."

            case .malformedLayout:
                "ELF Error: the ELF segment layout is malformed or corrupted."

            case .allocationFailed(let inner):
                switch inner.reportedCause {
                    case .outOfMemory    : "ELF Error: image allocation failed (no free physical memory)."
                    case .requestRejected: "ELF Error: image allocation failed (the allocator rejected the request)."
                    case .managerFault   : "ELF Error: image allocation failed (the physical page manager reported a fault)."
                }

            case .mappingFailed(let inner):
                switch inner.reportedCause {
                    case .outOfMemory    : "ELF Error: segment mapping failed (no free physical memory)."
                    case .requestRejected: "ELF Error: segment mapping failed (the allocator rejected the request)."
                    case .managerFault   : "ELF Error: segment mapping failed (the physical page manager reported a fault)."
                }
        }
    }

    public var category: ErrorCategory { .elf }
}
