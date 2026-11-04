//
//  AddressSpace.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/04/2026.
//

import ReixABI


public typealias ASID = UInt16

/// Per-process virtual address space handle.
///
/// Carries the architectural root page table for the process and the
/// VMA manager that tracks every region allocated within it. The
/// `vmaManager` slot is populated by `ProcessManager.spawnProcess` right
/// after `VMM.createAddressSpace` returns, so any access between those
/// two points is a programming error and traps deterministically.
@frozen
public struct AddressSpace {

    public let rootTablePhysical: PhysicalAddress // 8 Byte

    public var vmaManager       : UnsafeMutablePointer<VMAManager>? // 8 Byte

    public let asid             : ASID // 2 Byte

    public init(
        rootTablePhysical: PhysicalAddress,
        asid             : ASID,
        vmaManager       : UnsafeMutablePointer<VMAManager>? = nil
    ) {
        self.rootTablePhysical = rootTablePhysical
        self.asid              = asid
        self.vmaManager        = vmaManager
    }


    /// Forwards a synchronous user-space memory abort to the owning VMA
    /// manager, which answers whether it backed the access, refused it, or
    /// found nothing to back it with.
    ///
    /// A process with no manager has no mapping to consult, so every fault it
    /// raises is a refusal.
    ///
    /// Marked `@inline(__always)` so the call site in the exception
    /// vector keeps the same cost as a direct pointer dispatch.
    @inline(__always)
    public func handlePageFault(
        at address: VirtualAddress,
        cause     : FaultCause,
        access    : FaultAccess
    ) -> FaultOutcome {
        guard let vmaManager = self.vmaManager else { return .refused }

        return vmaManager.pointee.handlePageFault(
            at    : address,
            cause : cause,
            access: access
        )
    }
}
