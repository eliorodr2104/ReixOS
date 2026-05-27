//
//  VMAError.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/05/2026.
//

/// Errors emitted by the VMA manager and its supporting data structure.
///
/// The cases that depend on a lower-level subsystem (PPM) carry the
/// original error so a higher-level reporter can walk the cause chain.
public enum VMAError: Error {

    /// A new region was requested but overlaps an existing VMA.
    case regionOverlap

    /// No free gap large enough satisfies the requested size and
    /// alignment within the searched range.
    case noFreeGap

    /// Requested operation needs permissions not granted by the VMA.
    case permissionMismatch

    /// A `.fixed` mapping request collided with an existing VMA and
    /// cannot be relocated.
    case fixedAddressUnavailable

    /// Range boundaries violate `UserSpaceLayout` invariants (e.g. zero
    /// size, unaligned start/end, address outside user space).
    case invalidLayout

    /// Backing kind not yet implemented in the current milestone (e.g.
    /// file-backed mappings before the filesystem stack is wired).
    case notImplementedBacking

    /// Physical page allocation failed while servicing the VMA.
    case allocationFailed(PPMError)

    /// PTE mapping/unmapping failed for the underlying virtual range.
    case mappingFailed(PPMError)

    /// Kernel heap allocation for a VMA node failed.
    case heapAllocationFailed(PPMError)
}
