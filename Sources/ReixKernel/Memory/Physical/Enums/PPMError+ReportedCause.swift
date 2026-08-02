//
//  PPMError+ReportedCause.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 02/08/2026.
//

extension PPMError {

    /// What a PPM failure reduces to once another subsystem has to report it
    /// as the cause of its own failure.
    ///
    /// A wrapping case cannot compose its own prefix with `inner.description`:
    /// `+` builds a buffer on the heap, and this whole path exists to survive
    /// an allocator that has just run out. The message has to be a literal, so
    /// every (outer step x inner reason) pair has to be written out by hand:
    /// twelve of them per wrapping case, and eight wrapping cases carry a
    /// `PPMError` across three enums.
    ///
    /// These three classes are the granularity at which the nested reason
    /// still changes what the reader does next: give the machine more RAM,
    /// fix the caller, or go read the page manager's bookkeeping. Collapsing
    /// to them keeps the reason and costs three literals per wrapping case
    /// instead of twelve.
    public enum ReportedCause {
        /// No frame left. A resource condition, not a bug.
        case outOfMemory

        /// The allocator refused the request: bad size, order or address.
        /// The caller is what is wrong.
        case requestRejected

        /// The page manager found its own bookkeeping wrong, or was asked to
        /// touch a protected frame. Neither is expected on the paths that
        /// wrap this error.
        case managerFault
    }

    /// Triages the failure once, here, so that the wrapping enums do not each
    /// repeat the nested `switch` over `PPMError` and `AllocatorError`.
    ///
    /// Neither `switch` has a `default`: a case added to either enum has to be
    /// classified, and the compiler is what asks for it.
    public var reportedCause: ReportedCause {
        switch self {
            case .allocationFailed(let reason):
                switch reason {
                    case .fullMemory         : .outOfMemory
                    case .bytesNotValid      : .requestRejected
                    case .addressInvalid     : .requestRejected
                    case .addressRangeInvalid: .requestRejected
                    case .pageOrderInvalid   : .requestRejected
                    case .doubleFreeInvalid  : .managerFault
                }

            case .metadataInconsistency   : .managerFault
            case .invalidFlags            : .managerFault
            case .protectedMemoryViolation: .managerFault
            case .initRamError            : .managerFault
            case .invalidRefCount         : .managerFault
            case .pageOrderMismatch       : .managerFault
        }
    }
}
