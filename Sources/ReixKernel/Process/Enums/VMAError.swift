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
    case unownedBacking

    case allocationFailed     (PPMError)
    case mappingFailed        (PPMError)
    case heapAllocationFailed (PPMError)

    public var description: StaticString {
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

            case .unownedBacking:
                "VMA Error: the frames behind this region are not owned by the caller."

            case .allocationFailed(let inner):
                switch inner.reportedCause {
                    case .outOfMemory    : "VMA Error: physical allocation failed (no free physical memory)."
                    case .requestRejected: "VMA Error: physical allocation failed (the allocator rejected the request)."
                    case .managerFault   : "VMA Error: physical allocation failed (the physical page manager reported a fault)."
                }

            case .mappingFailed(let inner):
                switch inner.reportedCause {
                    case .outOfMemory    : "VMA Error: PTE mapping failed (no free physical memory)."
                    case .requestRejected: "VMA Error: PTE mapping failed (the allocator rejected the request)."
                    case .managerFault   : "VMA Error: PTE mapping failed (the physical page manager reported a fault)."
                }

            case .heapAllocationFailed(let inner):
                switch inner.reportedCause {
                    case .outOfMemory    : "VMA Error: kernel heap allocation for a VMA node failed (heap is empty)."
                    case .requestRejected: "VMA Error: kernel heap allocation for a VMA node failed (the allocator rejected the request)."
                    case .managerFault   : "VMA Error: kernel heap allocation for a VMA node failed (the physical page manager reported a fault)."
                }
        }
    }
}
