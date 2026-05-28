//
//  VMAError.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/05/2026.
//

/// Errors emitted by the VMA manager and its supporting data structure.
///
/// The cases that depend on a lower-level subsystem (PPM) carry the
/// original error so a higher-level reporter can walk the cause chain
/// inline through the embedded `description`.
public enum VMAError: KernelDiagnostic {

    case regionOverlap
    case noFreeGap
    case permissionMismatch
    case fixedAddressUnavailable
    case invalidLayout
    case notImplementedBacking

    case allocationFailed     (PPMError)
    case mappingFailed        (PPMError)
    case heapAllocationFailed (PPMError)

    public var description: String {
        switch self {
            case .regionOverlap:
                "VMA Error: requested region overlaps an existing VMA."

            case .noFreeGap:
                "VMA Error: no free aligned gap satisfies the request."

            case .permissionMismatch:
                "VMA Error: requested permissions exceed the VMA grants."

            case .fixedAddressUnavailable:
                "VMA Error: fixed address request collided with an existing VMA."

            case .invalidLayout:
                "VMA Error: range violates UserSpaceLayout invariants."

            case .notImplementedBacking:
                "VMA Error: backing type not implemented in this milestone."

            case .allocationFailed(let inner):
                "VMA Error: physical allocation failed (" + inner.description + ")"

            case .mappingFailed(let inner):
                "VMA Error: PTE mapping failed (" + inner.description + ")"

            case .heapAllocationFailed(let inner):
                "VMA Error: kernel heap allocation for a VMA node failed (" + inner.description + ")"
        }
    }

    public var category: ErrorCategory { .vma }
}
