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

    public let rootTablePhysical: PhysicalPage // 1 + 8 Byte
    
    public var vmaManager       : UnsafeMutablePointer<VMAManager>? // 8 Byte
    
    public let asid             : ASID // 2 Byte

    public init(
        rootTablePhysical: consuming PhysicalPage,
        asid             : ASID,
        vmaManager       : UnsafeMutablePointer<VMAManager>? = nil
    ) {
        self.rootTablePhysical = rootTablePhysical
        self.asid              = asid
        self.vmaManager        = vmaManager
    }


    /// Forwards a synchronous user-space memory abort to the owning VMA
    /// manager. Returns `true` if the manager handled the fault (lazy
    /// allocation, stack growth, COW), `false` if the fault is a real
    /// segfault that the exception handler must propagate.
    ///
    /// Marked `@inline(__always)` so the call site in the exception
    /// vector keeps the same cost as a direct pointer dispatch.
    @inline(__always)
    public func handlePageFault(
        at address: VirtualAddress,
        cause     : FaultCause
    ) -> Bool {
        guard let vmaManager = self.vmaManager else { return false }

        return vmaManager.pointee.handlePageFault(
            at   : address,
            cause: cause
        )
    }
}
